"""app/dingtalk/memory_provider.py

DingTalk → Memory integration.

Converts dingtalk_messages (verdict=notify/interest) into NormalisedMessage
format and feeds them through the universal AutomationEngine.

Adding a new source is this simple — just normalise + call process_message().
"""
from __future__ import annotations

import logging
from datetime import datetime, timezone
from typing import Any

import aiosqlite

from app.memory.engine import process_message, NormalisedMessage

logger = logging.getLogger("dingtalk.memory")

SOURCE_TYPE = "dingtalk"


def _normalise(row: dict) -> NormalisedMessage:
    """Convert a dingtalk_messages row into the engine's standard format."""
    return {
        "mid": str(row.get("mid") or ""),
        "text": row.get("text") or "",
        "sender_name": row.get("sender_name") or "",
        "conversation_title": row.get("conversation_title") or "",
        "is_group": bool(row.get("is_group")),
        "source_type": SOURCE_TYPE,
        "created_at": int(row.get("created_at") or 0),
        "category": row.get("category") or "",
        "verdict": row.get("verdict") or "notify",
    }


async def _get_last_synced_ts(db_path: str) -> int:
    async with aiosqlite.connect(db_path) as db:
        row = await (await db.execute(
            "SELECT last_synced_ts FROM memory_sync_state WHERE source_type=?",
            (SOURCE_TYPE,),
        )).fetchone()
    return int(row[0]) if row else 0


async def _save_synced_ts(db_path: str, ts: int, count: int, now: datetime) -> None:
    async with aiosqlite.connect(db_path) as db:
        await db.execute(
            """INSERT OR REPLACE INTO memory_sync_state
               (source_type, last_synced_ts, last_run_at, entry_count)
               VALUES (?,?,?,?)""",
            (SOURCE_TYPE, ts, now.isoformat(), count),
        )
        await db.commit()


async def run_dingtalk_memory_sync(
    db_path: str,
    provider: dict,
    model: str,
    api_key: str,
    now: datetime | None = None,
) -> dict[str, Any]:
    """
    Fetch new DingTalk notify messages since last sync and run them
    through the universal AutomationEngine.
    """
    if now is None:
        now = datetime.now(timezone.utc)

    last_ts = await _get_last_synced_ts(db_path)

    async with aiosqlite.connect(db_path) as db:
        db.row_factory = aiosqlite.Row
        rows = await (await db.execute(
            """SELECT mid, cid, conversation_title, sender_name,
                      content_type, text, category, verdict,
                      is_group, created_at
               FROM dingtalk_messages
               WHERE verdict IN ('notify', 'interest')
                 AND created_at > ?
                 AND text IS NOT NULL AND text != ''
               ORDER BY created_at ASC
               LIMIT 30""",
            (last_ts,),
        )).fetchall()
    messages = [dict(r) for r in rows]

    if not messages:
        return {"source": SOURCE_TYPE, "processed": 0, "effects": 0}

    logger.info("DingTalk memory: %d new messages to process", len(messages))

    total_effects = 0
    processed = 0
    for raw in messages:
        msg = _normalise(raw)
        result = await process_message(msg, db_path, provider, model, api_key, now)
        if result.ok:
            total_effects += result.effects_applied
            processed += 1

    max_ts = max(m["created_at"] for m in messages)
    await _save_synced_ts(db_path, max_ts, processed, now)

    logger.info("DingTalk memory: processed=%d effects=%d", processed, total_effects)
    return {
        "source": SOURCE_TYPE,
        "processed": processed,
        "effects": total_effects,
        "max_ts": max_ts,
    }
