"""app/memory/dispatch.py — Unified, dedup-aware notification dispatch.

Every push the memory layer emits goes through here so that:
  * it is deduplicated (``has_notified``) instead of firing twice when a
    message is reprocessed,
  * it is recorded in ``notification_log`` so it shows up in history and in the
    delivery-confirmation flow (received/clicked/dismissed),
  * scheduled pushes get a *deterministic* id so re-inserting the same
    reminder is an idempotent no-op (the old code used a random uuid, so
    ``INSERT OR IGNORE`` never actually deduped).

Callers: the automation engine's PUSH_NOW / SCHEDULE_PUSH effects today; any
future source can reuse these instead of touching push_service directly.
"""
from __future__ import annotations

import hashlib
import logging
from datetime import datetime, timezone

import aiosqlite

logger = logging.getLogger("memory.dispatch")


def _stable_id(*parts: str) -> str:
    return hashlib.sha1("|".join(p or "" for p in parts).encode("utf-8")).hexdigest()


async def notify_now(
    db_path: str,
    title: str,
    body: str,
    *,
    item_id: str | None = None,
    notif_type: str = "automation",
    data: dict | None = None,
) -> dict:
    """Send an immediate push, deduped + gated + logged.

    ``item_id`` identifies the underlying thing being notified about; if omitted
    it is derived from the content so identical pushes collapse.

    Safety net (push_gate): daily budget + cooldown, independent of content —
    a hallucinating LLM cannot exceed N pushes/day no matter what it emits.
    Gate-rejected pushes are parked for the evening digest instead of dropped.
    """
    from app.services.push_service import (
        send_push_to_all_subscribers,
        has_notified,
        log_notification_sent,
    )
    from datetime import datetime, timezone as _tz

    item_id = item_id or "auto-" + _stable_id(notif_type, title, body)[:16]

    if await has_notified(db_path, item_id, notif_type):
        logger.debug("notify_now deduped item_id=%s type=%s", item_id, notif_type)
        return {"skipped": True, "item_id": item_id}

    # Content-independent gate — LAST line of defense before the phone buzzes.
    gate = {"allowed": True, "reason": "gate_disabled"}
    try:
        from app.services.push_gate import check_push_budget, record_gate_overflow

        gate = await check_push_budget(db_path, notif_type=notif_type)
    except Exception:
        logger.exception("push_gate check failed; failing open")
    if not gate.get("allowed"):
        try:
            await record_gate_overflow(db_path, title, body)
        except Exception:
            logger.exception("push_gate overflow parking failed")
        return {"skipped": True, "gated": True, "reason": gate.get("reason"),
                "queued_for_digest": True, "item_id": item_id}

    tag = f"{notif_type}-{item_id}"
    payload = {**(data or {}), "tag": tag, "item_id": item_id}
    result = await send_push_to_all_subscribers(
        db_path, title=title, body=body, tag=tag, data=payload,
    )
    # Log as sent whenever we had subscribers to attempt (delivered or transient
    # error) so dedup + history work; has_notified's 24h window covers retries.
    if result.get("attempted", 0) > 0:
        await log_notification_sent(db_path, item_id, notif_type, title=title, body=body)
    return {"skipped": False, "item_id": item_id, **result}


async def schedule_push(
    db_path: str,
    title: str,
    body: str,
    trigger_iso: str,
    *,
    source_type: str = "automation_engine",
    source_id: str | None = None,
    reason: str | None = None,
    now: datetime | None = None,
) -> dict:
    """Insert a time-deferred push with a deterministic id (idempotent).

    Dedup basis: an explicit ``source_id`` if given, plus ``trigger_iso``.
    Re-scheduling the same reminder for the same time is a no-op;
    re-scheduling at a different time creates a new row after callers remove
    stale unsent rows.
    """
    if not trigger_iso:
        return {"skipped": True, "reason": "no_trigger"}
    if now is None:
        now = datetime.now(timezone.utc)

    dedupe_basis = source_id or title
    sid = _stable_id("sched", dedupe_basis, trigger_iso)[:32]

    async with aiosqlite.connect(db_path) as db:
        cur = await db.execute(
            """INSERT OR IGNORE INTO scheduled_notifications
               (id, title, body, scheduled_at, source_id, source_type, reason, created_at)
               VALUES (?,?,?,?,?,?,?,?)""",
            (
                sid, title or "提醒", body or "", trigger_iso,
                source_id, source_type,
                reason or "memory automation", now.isoformat(),
            ),
        )
        await db.commit()
        inserted = cur.rowcount > 0
    return {"skipped": not inserted, "id": sid, "inserted": inserted}
