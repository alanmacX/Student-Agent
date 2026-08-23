"""app/dingtalk/memory_provider.py

DingTalk → Memory integration.

Converts dingtalk_messages (verdict=notify/interest) into the normalized shape
and feeds them through the context-bounded Reconciler — batched per
conversation, so a burst of related messages ("周三停课" + "补课另定") is
reconciled in ONE LLM call with full intra-conversation context instead of N
independent calls that can contradict each other.

Cost discipline: a content hash over the pending batch skips the run entirely
when nothing changed since the last successful pass (same trick as the old
standby agent).
"""
from __future__ import annotations

import hashlib
import logging
from datetime import datetime, timezone
from typing import Any

import aiosqlite

from app.services.reconciler import reconcile_message

NormalisedMessage = dict

logger = logging.getLogger("dingtalk.memory")

SOURCE_TYPE = "dingtalk"

BATCH_WINDOW_MS = 10 * 60 * 1000  # messages within 10 min of each other batch together


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


def _batch_key(msg: NormalisedMessage) -> str:
    """Group by conversation; split when messages are far apart in time."""
    slot = msg["created_at"] // BATCH_WINDOW_MS
    return f"{msg.get('conversation_title') or msg.get('cid') or 'dm'}::{slot}"


async def _get_last_synced_ts(db_path: str) -> int:
    async with aiosqlite.connect(db_path) as db:
        row = await (await db.execute(
            "SELECT last_synced_ts FROM memory_sync_state WHERE source_type=?",
            (SOURCE_TYPE,),
        )).fetchone()
    return int(row[0]) if row else 0


async def _load_last_batch_hash(db_path: str) -> str:
    async with aiosqlite.connect(db_path) as db:
        row = await (await db.execute(
            "SELECT value FROM settings WHERE key='dingtalk_memory_last_hash'"
        )).fetchone()
    return str(row[0]) if row else ""


async def _save_batch_state(db_path: str, ts: int, processed: int,
                            batch_hash: str, now: datetime) -> None:
    async with aiosqlite.connect(db_path) as db:
        await db.execute(
            """INSERT OR REPLACE INTO memory_sync_state
               (source_type, last_synced_ts, last_run_at, entry_count)
               VALUES (?,?,?,?)""",
            (SOURCE_TYPE, ts, now.isoformat(), processed),
        )
        await db.execute(
            "INSERT OR REPLACE INTO settings (key, value) VALUES ('dingtalk_memory_last_hash', ?)",
            (batch_hash,),
        )
        await db.commit()


def _batch_hash(messages: list[NormalisedMessage]) -> str:
    raw = "|".join(f"{m['mid']}:{m['created_at']}:{hashlib.sha1(m['text'].encode()).hexdigest()[:8]}"
                   for m in sorted(messages, key=lambda x: x["mid"]))
    return hashlib.sha1(raw.encode()).hexdigest()[:16]


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
    through the context-bounded reconciler.
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
    messages = [_normalise(dict(r)) for r in rows]

    if not messages:
        return {"source": SOURCE_TYPE, "processed": 0, "effects": 0}

    bh = _batch_hash(messages)
    last_hash = await _load_last_batch_hash(db_path)
    if bh == last_hash:
        logger.info("DingTalk memory: skipped (batch hash unchanged)")
        # Advance cursor anyway so the same batch isn't re-fetched forever.
        max_ts = max(m["created_at"] for m in messages)
        await _save_batch_state(db_path, max_ts, 0, bh, now)
        return {"source": SOURCE_TYPE, "processed": 0, "effects": 0,
                "skipped": "hash_match", "max_ts": max_ts}

    # Group into per-conversation batches → one LLM call each.
    batches: dict[str, list[NormalisedMessage]] = {}
    for m in messages:
        batches.setdefault(_batch_key(m), []).append(m)

    logger.info("DingTalk memory: %d new messages in %d conversation batches",
                len(messages), len(batches))

    total_effects = 0
    processed = 0
    for key, group in sorted(batches.items(), key=lambda kv: kv[1][0]["created_at"]):
        primary = group[-1]           # newest message carries the trigger text
        context_siblings = [
            {"mid": m["mid"], "sender_name": m["sender_name"],
             "text": m["text"], "created_at": m["created_at"]}
            for m in group[:-1]
        ]
        result = await reconcile_message(
            primary, db_path, provider, model, api_key, now,
            sibling_messages=context_siblings,
        )
        if result.ok:
            total_effects += result.effects_applied
            processed += len(group)
        else:
            # Do NOT advance past a failed group — retry on next run.
            break

    if processed == len(messages):
        max_ts = max(m["created_at"] for m in messages)
        await _save_batch_state(db_path, max_ts, processed, bh, now)
    else:
        # Partial success: advance only past the groups that succeeded
        done = [m for g in list(batches.values())[:processed] for m in g]
        if done:
            await _save_batch_state(db_path, max(m["created_at"] for m in done),
                                    processed, "", now)

    logger.info("DingTalk memory: processed=%d effects=%d", processed, total_effects)
    return {
        "source": SOURCE_TYPE,
        "processed": processed,
        "effects": total_effects,
    }
