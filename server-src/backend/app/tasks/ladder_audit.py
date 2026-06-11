"""Queue audit for memory reminder ladders."""
from __future__ import annotations

import logging
from datetime import datetime, timezone

import aiosqlite

from app.services.ladder import schedule_ladder_for_item

logger = logging.getLogger("ladder_audit")


async def run_ladder_audit(app_state) -> None:
    db_path = app_state.settings.database_path
    now = datetime.now(timezone.utc)
    async with aiosqlite.connect(db_path) as db:
        db.row_factory = aiosqlite.Row
        rows = await (await db.execute(
            """SELECT id, title, summary, action_hint, importance, kind, category, expires_at
               FROM chaoxing_memory_entries
               WHERE archived_at IS NULL
                 AND COALESCE(status, 'active')='active'
                 AND for_automation=1
                 AND expires_at IS NOT NULL
                 AND expires_at > ?
               ORDER BY expires_at ASC
               LIMIT 200""",
            (now.isoformat(),),
        )).fetchall()

        missing = []
        for row in rows:
            queued = await (await db.execute(
                """SELECT 1 FROM scheduled_notifications
                   WHERE source_id LIKE ?
                     AND sent_at IS NULL
                     AND cancelled_at IS NULL
                   LIMIT 1""",
                (f"{row['id']}:%",),
            )).fetchone()
            if not queued:
                missing.append(row)

    repaired = 0
    for row in missing:
        due = _parse_dt(row["expires_at"])
        if not due:
            continue
        body = row["action_hint"] or row["summary"] or row["title"]
        repaired += await schedule_ladder_for_item(
            db_path,
            item_id=row["id"],
            kind=row["category"] or row["kind"],
            due=due,
            importance=row["importance"] or "medium",
            title=row["title"] or "提醒",
            body=body or row["title"] or "提醒",
            now=now,
            replace=False,
        )

    if missing:
        logger.warning("Ladder audit repaired %d queued steps for %d items", repaired, len(missing))


def _parse_dt(value: str | None):
    if not value:
        return None
    try:
        dt = datetime.fromisoformat(value.replace("Z", "+00:00"))
    except ValueError:
        return None
    if dt.tzinfo is None:
        dt = dt.replace(tzinfo=timezone.utc)
    return dt.astimezone(timezone.utc)
