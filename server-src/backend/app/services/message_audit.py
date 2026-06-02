"""app/services/message_audit.py — drop audit trail.

Persists messages that the filters discarded, so false drops are auditable and
the keyword/LLM rules can be tuned against real data. Both the DingTalk and
Chaoxing pipelines write here.

Mechanical drops (already-seen, ack/recall noise, empty) are intentionally NOT
logged — only content-judgement drops, which are the ones worth reviewing.
"""
from __future__ import annotations

import logging
import sqlite3

logger = logging.getLogger("message_audit")

_CAP = 2000          # hard cap on retained rows
_TRIM_TO = 1500      # rows kept after a trim

# Reasons that are pure plumbing, not a content judgement — skip these.
_SKIP_REASONS = {
    "already_processed", "noise_type", "empty_message",
    "empty group message", "empty direct message",
}

_CREATE_SQL = """
CREATE TABLE IF NOT EXISTS message_drop_log (
    id           INTEGER PRIMARY KEY AUTOINCREMENT,
    source       TEXT NOT NULL,
    stage        TEXT,
    conversation TEXT,
    sender       TEXT,
    text_preview TEXT,
    reason       TEXT,
    dropped_at   TEXT NOT NULL
)
"""


def _ensure(conn: sqlite3.Connection) -> None:
    conn.execute(_CREATE_SQL)


def log_drops(db_path: str, source: str, items: list[dict], now_iso: str) -> int:
    """Persist a batch of dropped messages.

    items: list of {conversation, sender, text, reason, stage}. Returns count
    actually written (after skipping mechanical reasons).
    """
    rows = []
    for it in items:
        reason = (it.get("reason") or "").strip()
        if not reason or reason in _SKIP_REASONS:
            continue
        text = (it.get("text") or "").replace("\n", " ").strip()
        rows.append((
            source,
            it.get("stage") or "filter",
            (it.get("conversation") or "")[:120],
            (it.get("sender") or "")[:60],
            text[:200],
            reason[:120],
            now_iso,
        ))
    if not rows:
        return 0
    try:
        with sqlite3.connect(db_path) as conn:
            _ensure(conn)
            conn.executemany(
                """INSERT INTO message_drop_log
                   (source, stage, conversation, sender, text_preview, reason, dropped_at)
                   VALUES (?,?,?,?,?,?,?)""",
                rows,
            )
            count = conn.execute("SELECT COUNT(*) FROM message_drop_log").fetchone()[0]
            if count > _CAP:
                conn.execute(
                    """DELETE FROM message_drop_log WHERE id IN (
                           SELECT id FROM message_drop_log
                           ORDER BY id ASC LIMIT ?)""",
                    (count - _TRIM_TO,),
                )
            conn.commit()
    except Exception:
        logger.exception("Failed to write message_drop_log (%s)", source)
        return 0
    return len(rows)
