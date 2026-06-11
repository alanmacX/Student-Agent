"""Compatibility wrapper for memory notification scheduling.

New code should use app.services.ladder directly. This module remains because a
few call sites still import its historical function names.
"""
from __future__ import annotations
import aiosqlite
from datetime import datetime, timezone


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

    ids = [e.get("id") for e in new_entries if e.get("id")]
    if not ids:
        return 0

    from app.services.ladder import schedule_ladder_for_items

    return await schedule_ladder_for_items(db_path, ids, now, replace=True)


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
