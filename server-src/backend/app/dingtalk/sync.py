from __future__ import annotations

import argparse
import contextlib
import logging
import os
import sqlite3
import time
from pathlib import Path
from typing import Any, Dict, List, Optional

from app.dingtalk.dingtalk_service import get_max_message_timestamp, get_new_messages
from app.dingtalk import filters
from app.dingtalk.schema import ensure_schema

logger = logging.getLogger("dingtalk")

STATE_KEY_LAST_SEEN = "last_seen_created_at"
DEFAULT_LOCK_PATH = "/tmp/dingtalk_sync.lock"


def default_chatbot_db_path() -> str:
    env_path = os.getenv("CHATBOT_DB_PATH")
    if env_path:
        return env_path

    candidates = [
        "/data/chatbot.db",
        "/var/lib/docker/volumes/chatbot_chatbot_data/_data/chatbot.db",
        "/var/lib/docker/volumes/chatbot_data/_data/chatbot.db",
    ]
    for candidate in candidates:
        if Path(candidate).exists():
            return candidate

    try:
        from app.config import settings

        return settings.database_path
    except Exception:
        return candidates[0]


@contextlib.contextmanager
def sync_lock(lock_path: str = DEFAULT_LOCK_PATH):
    import fcntl

    Path(lock_path).parent.mkdir(parents=True, exist_ok=True)
    with open(lock_path, "w") as lock_file:
        fcntl.flock(lock_file.fileno(), fcntl.LOCK_EX)
        try:
            yield
        finally:
            fcntl.flock(lock_file.fileno(), fcntl.LOCK_UN)


def _get_state(conn: sqlite3.Connection, key: str, default: str = "") -> str:
    row = conn.execute("SELECT value FROM dingtalk_sync_state WHERE key=?", (key,)).fetchone()
    return str(row[0]) if row and row[0] is not None else default


def _set_state(conn: sqlite3.Connection, key: str, value: str) -> None:
    conn.execute(
        "INSERT OR REPLACE INTO dingtalk_sync_state (key, value) VALUES (?, ?)",
        (key, value),
    )


def _stored_max_created_at(conn: sqlite3.Connection) -> int:
    row = conn.execute("SELECT MAX(created_at) FROM dingtalk_messages").fetchone()
    return int(row[0] or 0)


def _insert_messages(conn: sqlite3.Connection, messages: List[Dict[str, Any]]) -> int:
    before = conn.total_changes
    conn.executemany(
        """
        INSERT OR IGNORE INTO dingtalk_messages
            (mid, cid, conversation_title, sender_id, sender_name, content_type,
             media_type, text, raw_content, attachments, is_system, needs_ocr,
             ocr_status, created_at)
        VALUES
            (:mid, :cid, :conversation_title, :sender_id, :sender_name, :content_type,
             :media_type, :text, :raw_content, :attachments, :is_system, :needs_ocr,
             :ocr_status, :created_at)
        """,
        messages,
    )
    return conn.total_changes - before


def sync_once(
        db_path: Optional[str] = None,
        since_timestamp: Optional[int] = None,
) -> Dict[str, Any]:
    db_path = db_path or default_chatbot_db_path()
    ensure_schema(db_path)

    with sync_lock(), sqlite3.connect(db_path) as conn:
        conn.row_factory = sqlite3.Row
        state_value = _get_state(conn, STATE_KEY_LAST_SEEN)
        stored_max = _stored_max_created_at(conn)
        last_seen = since_timestamp if since_timestamp is not None else int(state_value or stored_max or 0)

        raw_messages = get_new_messages(last_seen)
        evaluated = [filters.evaluate(m) for m in raw_messages]
        messages = [
            m for m in evaluated
            if m.get("_keep")
            and m.get("mid") is not None and m.get("cid") and m.get("created_at")
        ]
        for m in messages:
            m.pop("_keep", None)
        skipped = len(raw_messages) - len(messages)
        inserted = _insert_messages(conn, messages) if messages else 0
        timestamps = [int(m["created_at"]) for m in raw_messages if m.get("created_at")]
        next_last_seen = max([last_seen] + timestamps) if timestamps else last_seen
        _set_state(conn, STATE_KEY_LAST_SEEN, str(next_last_seen))
        conn.commit()

    return {
        "ok": True,
        "db_path": db_path,
        "since": last_seen,
        "fetched": len(raw_messages),
        "skipped": skipped,
        "inserted": inserted,
        "last_seen": next_last_seen,
    }


def bootstrap_to_current(db_path: Optional[str] = None) -> Dict[str, Any]:
    db_path = db_path or default_chatbot_db_path()
    ensure_schema(db_path)
    latest = get_max_message_timestamp()
    with sync_lock(), sqlite3.connect(db_path) as conn:
        _set_state(conn, STATE_KEY_LAST_SEEN, str(latest))
        conn.commit()
    return {"ok": True, "db_path": db_path, "last_seen": latest}


async def run_dingtalk_sync(app_state=None) -> Dict[str, Any]:
    db_path = getattr(getattr(app_state, "settings", None), "database_path", None)
    return sync_once(db_path=db_path)


def _poll_job(db_path: Optional[str] = None) -> None:
    try:
        result = sync_once(db_path=db_path)
        logger.info(
            "DingTalk sync ok: fetched=%s inserted=%s last_seen=%s",
            result["fetched"],
            result["inserted"],
            result["last_seen"],
        )
    except Exception:
        logger.exception("DingTalk sync failed")


def run_poll(interval_seconds: int = 30, db_path: Optional[str] = None) -> None:
    try:
        from apscheduler.schedulers.blocking import BlockingScheduler
        from apscheduler.triggers.interval import IntervalTrigger
    except Exception:
        logger.warning("APScheduler not available, using sleep loop")
        while True:
            _poll_job(db_path)
            time.sleep(interval_seconds)

    scheduler = BlockingScheduler(timezone="Asia/Shanghai")
    scheduler.add_job(
        _poll_job,
        IntervalTrigger(seconds=interval_seconds),
        args=[db_path],
        id="dingtalk_sync",
        max_instances=1,
        coalesce=True,
        misfire_grace_time=interval_seconds,
        replace_existing=True,
    )
    _poll_job(db_path)
    scheduler.start()


def list_stored_messages(
        db_path: Optional[str] = None,
        since_timestamp: int = 0,
        limit: int = 50,
) -> List[Dict[str, Any]]:
    db_path = db_path or default_chatbot_db_path()
    ensure_schema(db_path)
    limit = max(1, min(int(limit), 500))
    with sqlite3.connect(db_path) as conn:
        conn.row_factory = sqlite3.Row
        rows = conn.execute(
            """
            SELECT mid, cid, conversation_title, sender_id, sender_name, content_type,
                   media_type, text, raw_content, attachments, is_system,
                   needs_ocr, ocr_status, ocr_text, created_at, synced_at
            FROM dingtalk_messages
            WHERE created_at > ?
            ORDER BY created_at DESC, mid DESC
            LIMIT ?
            """,
            (since_timestamp, limit),
        ).fetchall()
        return [dict(row) for row in rows]


def _build_parser() -> argparse.ArgumentParser:
    parser = argparse.ArgumentParser(description="DingTalk message sync")
    mode = parser.add_mutually_exclusive_group(required=True)
    mode.add_argument("--once", action="store_true", help="Run one sync pass")
    mode.add_argument("--poll", action="store_true", help="Poll forever")
    mode.add_argument("--bootstrap-now", action="store_true", help="Set last_seen to current DingTalk max timestamp")
    parser.add_argument("--db-path", default=None, help="Chatbot SQLite path")
    parser.add_argument("--since", type=int, default=None, help="Override last_seen for one sync pass")
    parser.add_argument("--interval", type=int, default=30, help="Polling interval in seconds")
    parser.add_argument("--log-level", default="INFO", help="Python logging level")
    return parser


def main() -> None:
    args = _build_parser().parse_args()
    logging.basicConfig(
        level=getattr(logging, str(args.log_level).upper(), logging.INFO),
        format="%(asctime)s %(levelname)s %(name)s: %(message)s",
    )

    if args.once:
        print(sync_once(db_path=args.db_path, since_timestamp=args.since))
    elif args.bootstrap_now:
        print(bootstrap_to_current(db_path=args.db_path))
    else:
        run_poll(interval_seconds=args.interval, db_path=args.db_path)


if __name__ == "__main__":
    main()
