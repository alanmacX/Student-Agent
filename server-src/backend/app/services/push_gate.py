"""app/services/push_gate.py — Semantic-independent push safety net.

Regex guards enumerate known patterns; human language is open-ended, so any
pattern list eventually leaks (the 2026-07 incident leaked five past-tense
titles the ACK regex can't match). This module adds guarantees that do NOT
depend on understanding the content at all:

  1. Daily budget   — at most N pushes/day through the automation path
                      (default 6). Hard cap: even a fully hallucinating LLM
                      cannot exceed it.
  2. Cooldown       — minimum minutes between consecutive automation pushes
                      (default 20), so a burst degrades to a slow trickle and
                      the user keeps agency.
  3. Overflow queue — pushes rejected by budget/cooldown are demoted into the
      (existing) evening digest source data instead of being dropped, so
      "没推送 ≠ 没看到" holds.

Everything is a plain SQL counter against notification_log — no NLP, no model,
nothing to disagree with.
"""
from __future__ import annotations

import logging
from datetime import datetime, timedelta, timezone
from zoneinfo import ZoneInfo

import aiosqlite

logger = logging.getLogger("push.gate")

LOCAL_TZ = ZoneInfo("Asia/Shanghai")

_DEFAULT_DAILY_LIMIT = 6
_DEFAULT_COOLDOWN_MIN = 20


def _local_day(now: datetime) -> str:
    return now.astimezone(LOCAL_TZ).strftime("%Y-%m-%d")


async def _load_limits(db_path: str) -> tuple[int, int]:
    async with aiosqlite.connect(db_path) as db:
        rows = await (await db.execute(
            "SELECT key, value FROM settings WHERE key IN ('push_daily_limit','push_cooldown_minutes')"
        )).fetchall()
    cfg = {k: v for k, v in rows}
    try:
        limit = max(1, int(cfg.get("push_daily_limit", _DEFAULT_DAILY_LIMIT)))
    except (TypeError, ValueError):
        limit = _DEFAULT_DAILY_LIMIT
    try:
        cooldown = max(0, int(cfg.get("push_cooldown_minutes", _DEFAULT_COOLDOWN_MIN)))
    except (TypeError, ValueError):
        cooldown = _DEFAULT_COOLDOWN_MIN
    return limit, cooldown


async def check_push_budget(
    db_path: str,
    *,
    notif_type: str,
    now: datetime | None = None,
) -> dict:
    """Decide whether an immediate push may go out right now.

    Returns {"allowed": bool, "reason": str, "queued_for_digest": bool}.
    Digest/daily-summary/system channels bypass the gate — the gate exists to
    protect the user from *automation* bursts, not from the app's own digest.
    """
    if now is None:
        now = datetime.now(timezone.utc)
    if notif_type.startswith(("daily_", "digest")):
        return {"allowed": True, "reason": "digest_channel", "queued_for_digest": False}

    limit, cooldown_min = await _load_limits(db_path)
    day = _local_day(now)

    async with aiosqlite.connect(db_path) as db:
        row = await (await db.execute(
            """SELECT COUNT(*) FROM notification_log
               WHERE notif_type NOT LIKE 'daily_%'
                 AND substr(sent_at, 1, 10) = ?""",
            (day,),
        )).fetchone()
        sent_today = row[0] if row else 0

        if sent_today >= limit:
            logger.info("Push gate: daily budget %d/%d exhausted", sent_today, limit)
            return {"allowed": False, "reason": f"daily_budget_{sent_today}/{limit}",
                    "queued_for_digest": True}

        if cooldown_min > 0:
            last = await (await db.execute(
                """SELECT MAX(sent_at) FROM notification_log
                   WHERE notif_type NOT LIKE 'daily_%'"""
            )).fetchone()
            last_iso = last[0] if last and last[0] else None
            if last_iso:
                try:
                    last_dt = datetime.fromisoformat(last_iso)
                    if last_dt.tzinfo is None:
                        last_dt = last_dt.replace(tzinfo=timezone.utc)
                    elapsed = (now - last_dt).total_seconds() / 60.0
                    if elapsed < cooldown_min:
                        logger.info("Push gate: cooldown %.0f/%d min", elapsed, cooldown_min)
                        return {"allowed": False,
                                "reason": f"cooldown_{elapsed:.0f}<{cooldown_min}min",
                                "queued_for_digest": True}
                except ValueError:
                    pass

    return {"allowed": True, "reason": f"budget {sent_today}/{limit}", "queued_for_digest": False}


async def record_gate_overflow(db_path: str, title: str, body: str, *, now: datetime | None = None) -> None:
    """Park a gate-rejected item so tonight's digest can still surface it.

    Uses the ideas table (kind='gate_overflow') — it already exists, is
    user-visible in the Hub capture panel if anything slips through, and gets
    swept by existing hygiene. Rows are prefixed so the digest builder can
    filter them out of user notes.
    """
    if now is None:
        now = datetime.now(timezone.utc)

    import uuid

    async with aiosqlite.connect(db_path) as db:
        await db.execute(
            """INSERT INTO ideas (id, text, created_at, updated_at)
               VALUES (?,?,?,?)""",
            (str(uuid.uuid4()),
             f"[push-overflow] {title} — {body}"[:300],
             now.isoformat(), now.isoformat()),
        )
        await db.commit()
    logger.info("Push gate: overflow parked for digest: %s", title[:40])
