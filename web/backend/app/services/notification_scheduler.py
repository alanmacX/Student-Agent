"""
Rule-based notification scheduler.

Decides whether and when to send a push for each new memory entry,
using only the fields already on the entry — no LLM call.

Rules (applied in order, first match wins):
  1. importance == 'high'                → schedule now + 5 min
  2. importance == 'medium' AND
     category in exam/meeting/course_change → schedule now + 8 min
  3. importance == 'medium' AND action_hint is set → schedule now + 10 min
  4. everything else                     → skip

Night-time guard (23:00–07:00 CST): any scheduled_at that falls in the
quiet window is pushed forward to 07:30 the next morning.
The actual send is handled by check_scheduled_notifications (1-min poll).
"""
from __future__ import annotations
import uuid
from datetime import datetime, timedelta, timezone

import aiosqlite

_CST = timezone(timedelta(hours=8))

# Categories that deserve a push even at medium importance
_PUSH_CATEGORIES = {"exam", "meeting", "course_change", "assignment"}


def _now_cst(now: datetime) -> datetime:
    return now.astimezone(_CST)


def _next_morning(now_cst: datetime) -> datetime:
    """Next 07:30 CST as UTC."""
    candidate = now_cst.replace(hour=7, minute=30, second=0, microsecond=0)
    if candidate <= now_cst:
        candidate += timedelta(days=1)
    return candidate.astimezone(timezone.utc)


def _apply_quiet_hours(scheduled_at: datetime, now: datetime) -> datetime:
    """If scheduled_at falls in 23:00–07:00 CST, push it to 07:30 next morning."""
    cst = scheduled_at.astimezone(_CST)
    if cst.hour >= 23 or cst.hour < 7:
        return _next_morning(_now_cst(now))
    return scheduled_at


def _rule_decision(entry: dict, now: datetime) -> datetime | None:
    """
    Return the scheduled_at datetime to use, or None to skip.
    """
    importance = entry.get("importance", "low")
    category = entry.get("category", "")
    action_hint = (entry.get("action_hint") or "").strip()

    if importance == "high":
        return now + timedelta(minutes=5)

    if importance == "medium":
        if category in _PUSH_CATEGORIES:
            return now + timedelta(minutes=8)
        if action_hint:
            return now + timedelta(minutes=10)

    return None


async def auto_schedule_from_memory(
    new_entries: list[dict],
    db_path: str,
    # provider / model / api_key kept in signature for call-site compat, ignored
    provider: dict = None,
    model: str = None,
    api_key: str = None,
    now: datetime = None,
) -> int:
    if now is None:
        now = datetime.now(timezone.utc)

    existing_source_ids = await _get_existing_source_ids(db_path)
    to_evaluate = [e for e in new_entries if e.get("id") not in existing_source_ids]
    if not to_evaluate:
        return 0

    count = 0
    async with aiosqlite.connect(db_path) as db:
        for entry in to_evaluate:
            source_id = entry.get("id")
            if not source_id or source_id in existing_source_ids:
                continue

            fire_at = _rule_decision(entry, now)
            if fire_at is None:
                continue

            fire_at = _apply_quiet_hours(fire_at, now)

            title = (entry.get("title") or "").strip()
            summary = (entry.get("summary") or "").strip()
            action_hint = (entry.get("action_hint") or "").strip()
            body = action_hint or summary or title
            if not title or not body:
                continue

            reason = f"importance={entry.get('importance')} category={entry.get('category')}"

            await db.execute("""
                INSERT OR IGNORE INTO scheduled_notifications
                (id, title, body, scheduled_at, source_id, source_type, reason, created_at)
                VALUES (?,?,?,?,?,?,?,?)
            """, (
                str(uuid.uuid4()),
                title,
                body,
                fire_at.isoformat(),
                source_id,
                "memory",
                reason,
                now.isoformat(),
            ))
            existing_source_ids.add(source_id)
            count += 1

        await db.commit()

    return count


async def fetch_memory_entries_by_ids(db_path: str, ids: list[str]) -> list[dict]:
    if not ids:
        return []
    async with aiosqlite.connect(db_path) as db:
        db.row_factory = aiosqlite.Row
        rows = await (await db.execute(
            f"""
            SELECT id, title, summary, action_hint, importance, category,
                   expires_at, content_time
            FROM chaoxing_memory_entries
            WHERE id IN ({','.join('?' for _ in ids)})
            """,
            ids,
        )).fetchall()
    return [dict(r) for r in rows]


async def _get_existing_source_ids(db_path: str) -> set[str]:
    async with aiosqlite.connect(db_path) as db:
        rows = await (await db.execute("""
            SELECT source_id FROM scheduled_notifications
            WHERE source_id IS NOT NULL AND cancelled_at IS NULL
        """)).fetchall()
    return {r[0] for r in rows if r[0]}
