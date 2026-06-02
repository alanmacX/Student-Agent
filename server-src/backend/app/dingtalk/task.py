"""Async orchestration for the in-container APScheduler.

Pipeline per run:
  1. decrypt DingTalk DB + query new messages   (sync, fast; runs in executor)
  2. coarse keyword filter                        (sync)
  3. LLM fine classification for the uncertain    (async, MiMo)
  4. store into chatbot.db with the final bucket   (sync, in executor)

Only messages whose final verdict is notify/interest are stored. 'drop' is
discarded. The OCR queue (needs_ocr/ocr_status='pending') is populated for a
separate worker.
"""
from __future__ import annotations

import asyncio
import logging
import sqlite3
from typing import Any, Dict, List, Optional

from app.dingtalk.dingtalk_service import decrypt_db_to_tmp, query_new_messages
from app.dingtalk import filters, classifier
from app.dingtalk.schema import ensure_schema

logger = logging.getLogger("dingtalk.task")

STATE_KEY_LAST_SEEN = "last_seen_created_at"

_INSERT_SQL = """
INSERT OR IGNORE INTO dingtalk_messages
    (mid, cid, conversation_title, sender_id, sender_name, content_type,
     media_type, category, text, raw_content, attachments, is_system,
     is_group, has_link, needs_ocr, ocr_status, verdict, verdict_reason,
     created_at)
VALUES
    (:mid, :cid, :conversation_title, :sender_id, :sender_name, :content_type,
     :media_type, :category, :text, :raw_content, :attachments, :is_system,
     :is_group, :has_link, :needs_ocr, :ocr_status, :verdict, :verdict_reason,
     :created_at)
"""

_INSERT_COLS = (
    "mid", "cid", "conversation_title", "sender_id", "sender_name", "content_type",
    "media_type", "category", "text", "raw_content", "attachments", "is_system",
    "is_group", "has_link", "needs_ocr", "ocr_status", "verdict", "verdict_reason",
    "created_at",
)


def _get_state(conn: sqlite3.Connection, key: str, default: str = "") -> str:
    row = conn.execute("SELECT value FROM dingtalk_sync_state WHERE key=?", (key,)).fetchone()
    return str(row[0]) if row and row[0] is not None else default


def _set_state(conn: sqlite3.Connection, key: str, value: str) -> None:
    conn.execute(
        "INSERT OR REPLACE INTO dingtalk_sync_state (key, value) VALUES (?, ?)",
        (key, value),
    )


def _is_dingtalk_enabled(db_path: str) -> bool:
    """Check the settings KV table for dingtalk_enabled switch."""
    try:
        with sqlite3.connect(db_path) as conn:
            row = conn.execute(
                "SELECT value FROM settings WHERE key='dingtalk_enabled'"
            ).fetchone()
            if row and str(row[0]).lower() in ("false", "0", "no"):
                return False
    except Exception:
        pass  # table might not exist yet, default to enabled
    return True


def _fetch_and_coarse_filter(db_path: str) -> Dict[str, Any]:
    """Sync step: decrypt, read last_seen, query new msgs, coarse-filter."""
    ensure_schema(db_path)
    with sqlite3.connect(db_path) as conn:
        last_seen = int(_get_state(conn, STATE_KEY_LAST_SEEN) or 0)
        if last_seen == 0:
            row = conn.execute("SELECT MAX(created_at) FROM dingtalk_messages").fetchone()
            last_seen = int(row[0] or 0)

    decrypted = decrypt_db_to_tmp()
    with sqlite3.connect(f"file:{decrypted}?mode=ro", uri=True) as src:
        src.row_factory = sqlite3.Row
        raw = query_new_messages(src, last_seen)

    evaluated = [filters.evaluate(m) for m in raw]
    return {"last_seen": last_seen, "raw": raw, "evaluated": evaluated}


def _store(db_path: str, evaluated: List[Dict[str, Any]], last_seen: int) -> Dict[str, Any]:
    """Sync step: persist notify/interest messages and advance last_seen."""
    to_store = [
        m for m in evaluated
        if m.get("verdict") in ("notify", "interest")
        and m.get("mid") is not None and m.get("cid") and m.get("created_at")
    ]
    rows = [{c: m.get(c) for c in _INSERT_COLS} for m in to_store]

    with sqlite3.connect(db_path) as conn:
        before = conn.total_changes
        if rows:
            conn.executemany(_INSERT_SQL, rows)
        inserted = conn.total_changes - before

        all_ts = [int(m["created_at"]) for m in evaluated if m.get("created_at")]
        next_last_seen = max([last_seen] + all_ts) if all_ts else last_seen
        _set_state(conn, STATE_KEY_LAST_SEEN, str(next_last_seen))
        conn.commit()

    # Audit trail: persist dropped messages so false drops are reviewable.
    try:
        from datetime import datetime, timezone
        from app.services.message_audit import log_drops
        drops = [
            {
                "conversation": m.get("conversation_title") or m.get("cid"),
                "sender": m.get("sender_name") or m.get("sender_id"),
                "text": m.get("text"),
                "reason": m.get("verdict_reason"),
                "stage": "llm" if str(m.get("verdict_reason", "")).startswith("llm") else "coarse",
            }
            for m in evaluated if m.get("verdict") == "drop"
        ]
        if drops:
            log_drops(db_path, "dingtalk", drops, datetime.now(timezone.utc).isoformat())
    except Exception:
        logger.exception("DingTalk drop-audit logging failed")

    buckets = {"notify": 0, "interest": 0, "drop": 0, "needs_llm": 0}
    for m in evaluated:
        buckets[m.get("verdict", "drop")] = buckets.get(m.get("verdict", "drop"), 0) + 1
    return {
        "fetched": len(evaluated),
        "stored": len(to_store),
        "inserted": inserted,
        "buckets": buckets,
        "last_seen": next_last_seen,
    }


async def run_dingtalk_sync(app_state=None) -> Dict[str, Any]:
    """Entry point for the AsyncIOScheduler job."""
    db_path = getattr(getattr(app_state, "settings", None), "database_path", "/data/chatbot.db")

    # Check the dingtalk_enabled switch
    if not _is_dingtalk_enabled(db_path):
        return {"ok": True, "skipped": "disabled"}

    # Load user-configured filter rules before coarse filtering
    await filters.load_filter_config(db_path)

    loop = asyncio.get_event_loop()

    try:
        stage1 = await loop.run_in_executor(None, _fetch_and_coarse_filter, db_path)
    except FileNotFoundError as exc:
        logger.warning("DingTalk DB not available, skipping sync: %s", exc)
        return {"ok": False, "error": "db_not_found"}
    except Exception:
        logger.exception("DingTalk fetch/coarse-filter failed")
        return {"ok": False, "error": "fetch_failed"}

    evaluated = stage1["evaluated"]

    # Stage 2 — LLM fine classification for the uncertain bucket.
    try:
        await classifier.classify_messages(evaluated, app_state)
    except Exception:
        logger.exception("DingTalk LLM classify failed; needs_llm -> interest fallback")
        for m in evaluated:
            if m.get("verdict") == "needs_llm":
                m["verdict"] = "interest"
                m["verdict_reason"] = "classify exception -> interest"

    try:
        result = await loop.run_in_executor(None, _store, db_path, evaluated, stage1["last_seen"])
    except Exception:
        logger.exception("DingTalk store failed")
        return {"ok": False, "error": "store_failed"}

    result["ok"] = True
    # Record successful sync time — used by /status to confirm client is reachable
    try:
        with sqlite3.connect(db_path) as _conn:
            _set_state(_conn, "last_sync_ok_at", str(int(__import__("time").time())))
            _conn.commit()
    except Exception:
        pass
    logger.info(
        "DingTalk sync: fetched=%s stored=%s inserted=%s buckets=%s",
        result["fetched"], result["stored"], result["inserted"], result["buckets"],
    )

    # Memory extraction runs as a separate scheduled task (run_dingtalk_memory_task)
    # with its own cursor — decoupled from the raw-message sync above.
    return result


async def run_dingtalk_memory_task(app_state=None) -> Dict[str, Any]:
    """Scheduler entry point — run the memory automation engine.

    Independent of the main dingtalk_sync; has its own cursor so it processes
    any notify/interest messages not yet turned into memory, regardless of
    whether the last decrypt-sync found new raw messages.
    """
    db_path = getattr(getattr(app_state, "settings", None), "database_path", "/data/chatbot.db")
    try:
        from app.dingtalk.memory_provider import run_dingtalk_memory_sync
        from app.services.provider_registry import resolve_provider
        provider_id = getattr(getattr(app_state, "settings", None), "standby_agent_provider", "openai") or "openai"
        model = getattr(getattr(app_state, "settings", None), "standby_agent_model", "gpt-4o-mini") or "gpt-4o-mini"
        provider, api_key = await resolve_provider(provider_id)
        return await run_dingtalk_memory_sync(db_path, provider, model, api_key)
    except Exception:
        logger.exception("DingTalk memory task failed")
        return {"ok": False, "error": "memory_task_failed"}


def bootstrap_to_current(db_path: str = "/data/chatbot.db") -> Dict[str, Any]:
    """Set last_seen to the current max DingTalk timestamp (skip historical backlog)."""
    from app.dingtalk.dingtalk_service import get_max_message_timestamp
    ensure_schema(db_path)
    latest = get_max_message_timestamp()
    with sqlite3.connect(db_path) as conn:
        _set_state(conn, STATE_KEY_LAST_SEEN, str(latest))
        conn.commit()
    return {"ok": True, "last_seen": latest}
