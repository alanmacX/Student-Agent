"""app/chaoxing/memory_provider.py

Chaoxing → Memory integration.

Converts Chaoxing messages (after filter_messages dedup) into NormalisedMessage
format and feeds them through the universal engine.process_message().

Replaces app/services/memory_agent.run_memory_agent() for the LLM extraction step.
The non-LLM structured sync (assignments, courses, reminders) stays in memory_sync.
"""
from __future__ import annotations

import logging
from datetime import datetime, timezone
from typing import Any

from app.memory.engine import process_message, NormalisedMessage
from app.memory.base import MemoryRepository

logger = logging.getLogger("chaoxing.memory")

SOURCE_TYPE = "chaoxing"


def _normalise(candidate: dict) -> NormalisedMessage:
    """Convert a chaoxing_message_filter candidate into the engine's standard format."""
    return {
        "mid": str(candidate.get("id") or candidate.get("msgId") or ""),
        "text": candidate.get("content") or candidate.get("text") or "",
        "sender_name": candidate.get("senderName") or candidate.get("sender_name") or "",
        "conversation_title": candidate.get("courseName") or candidate.get("conversation_title") or "",
        "is_group": True,  # Chaoxing messages are course group messages
        "source_type": SOURCE_TYPE,
        "created_at": int(candidate.get("sendTime") or candidate.get("created_at") or 0),
        "category": candidate.get("category") or "notice",
    }


async def run_chaoxing_memory_sync(
    chaoxing_svc,
    db_path: str,
    provider: dict,
    model: str,
    api_key: str,
    assignments: list[dict] | None = None,
    now: datetime | None = None,
) -> dict[str, Any]:
    """
    Fetch new Chaoxing messages, run them through the universal AutomationEngine.
    Replaces run_memory_agent() in the chaoxing probe loop.
    """
    if now is None:
        now = datetime.now(timezone.utc)

    from app.services.chaoxing_message_filter import (
        load_sync_state,
        run as filter_messages,
        save_sync_state,
    )

    messages = await chaoxing_svc.fetch_recent_messages(max_conversations=12, per_conversation=20)
    if not messages:
        await _touch_chaoxing_session(db_path, now)
        return {"candidate_count": 0, "processed_count": 0, "new_entry_ids": []}

    if assignments is None:
        try:
            assignments = await chaoxing_svc.fetch_all_pending_assignments()
        except Exception:
            assignments = []

    sync_state = await load_sync_state(db_path)
    filter_result = filter_messages(messages, sync_state, assignments, now=now)
    candidates = filter_result.get("candidates") or []

    if not candidates:
        await save_sync_state(db_path, filter_result, [], now)
        await _touch_chaoxing_session(db_path, now)
        return {
            "candidate_count": 0,
            "processed_count": 0,
            "new_entry_ids": [],
            "dropped_reasons": filter_result.get("dropped_reasons", {}),
        }

    logger.info("Chaoxing memory: %d candidates to process", len(candidates))

    repo = MemoryRepository(db_path)
    new_entry_ids: list[str] = []
    processed_ids: list[str] = []
    errors: list[str] = []

    for candidate in candidates:
        msg = _normalise(candidate)
        if not msg["text"].strip():
            continue
        try:
            result = await process_message(msg, db_path, provider, model, api_key, now)
            new_entry_ids.extend(result.memory_upserted)
            processed_ids.append(msg["mid"])
        except Exception as e:
            logger.warning("process_message failed for %s: %s", msg["mid"], e)
            errors.append(str(e))

    # Only advance the sync cursor if processing succeeded (so failures can retry)
    if processed_ids:
        await save_sync_state(db_path, filter_result, candidates, now)

    await _touch_chaoxing_session(db_path, now)

    return {
        "candidate_count": len(candidates),
        "processed_count": len(processed_ids),
        "new_entry_ids": new_entry_ids,
        "errors": errors,
    }


async def _touch_chaoxing_session(db_path: str, now: datetime) -> None:
    import aiosqlite
    async with aiosqlite.connect(db_path) as db:
        await db.execute(
            "UPDATE chaoxing_session SET last_active_at=? WHERE id=(SELECT id FROM chaoxing_session LIMIT 1)",
            (now.isoformat(),),
        )
        await db.commit()
