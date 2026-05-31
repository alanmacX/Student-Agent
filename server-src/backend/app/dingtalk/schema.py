from __future__ import annotations

import sqlite3

DINGTALK_SCHEMA = """
CREATE TABLE IF NOT EXISTS dingtalk_messages (
    id INTEGER PRIMARY KEY AUTOINCREMENT,
    mid INTEGER UNIQUE NOT NULL,
    cid TEXT NOT NULL,
    conversation_title TEXT,
    sender_id INTEGER,
    sender_name TEXT,
    content_type INTEGER,
    media_type TEXT,
    category TEXT,
    text TEXT,
    raw_content TEXT,
    attachments TEXT,
    is_system INTEGER DEFAULT 0,
    is_group INTEGER DEFAULT 0,
    has_link INTEGER DEFAULT 0,
    needs_ocr INTEGER DEFAULT 0,
    ocr_status TEXT DEFAULT 'none',
    ocr_text TEXT,
    verdict TEXT DEFAULT 'notify',
    verdict_reason TEXT,
    created_at INTEGER NOT NULL,
    synced_at INTEGER DEFAULT (strftime('%s','now'))
);

CREATE TABLE IF NOT EXISTS dingtalk_sync_state (
    key TEXT PRIMARY KEY,
    value TEXT
);

CREATE INDEX IF NOT EXISTS idx_dingtalk_messages_created_at
    ON dingtalk_messages(created_at DESC);
CREATE INDEX IF NOT EXISTS idx_dingtalk_messages_verdict
    ON dingtalk_messages(verdict, created_at DESC);
CREATE INDEX IF NOT EXISTS idx_dingtalk_messages_cid_created_at
    ON dingtalk_messages(cid, created_at DESC);
CREATE INDEX IF NOT EXISTS idx_dingtalk_messages_ocr
    ON dingtalk_messages(ocr_status) WHERE ocr_status='pending';
"""

# Column-level migrations for upgrading an existing table. Each runs in its own
# try/except so 'duplicate column' on re-run is harmless.
COLUMN_MIGRATIONS = [
    "ALTER TABLE dingtalk_messages ADD COLUMN media_type TEXT",
    "ALTER TABLE dingtalk_messages ADD COLUMN category TEXT",
    "ALTER TABLE dingtalk_messages ADD COLUMN attachments TEXT",
    "ALTER TABLE dingtalk_messages ADD COLUMN is_system INTEGER DEFAULT 0",
    "ALTER TABLE dingtalk_messages ADD COLUMN is_group INTEGER DEFAULT 0",
    "ALTER TABLE dingtalk_messages ADD COLUMN has_link INTEGER DEFAULT 0",
    "ALTER TABLE dingtalk_messages ADD COLUMN needs_ocr INTEGER DEFAULT 0",
    "ALTER TABLE dingtalk_messages ADD COLUMN ocr_status TEXT DEFAULT 'none'",
    "ALTER TABLE dingtalk_messages ADD COLUMN ocr_text TEXT",
    "ALTER TABLE dingtalk_messages ADD COLUMN verdict TEXT DEFAULT 'notify'",
    "ALTER TABLE dingtalk_messages ADD COLUMN verdict_reason TEXT",
]


def ensure_schema(db_path: str) -> None:
    with sqlite3.connect(db_path) as conn:
        conn.executescript(DINGTALK_SCHEMA)
        for stmt in COLUMN_MIGRATIONS:
            try:
                conn.execute(stmt)
            except sqlite3.OperationalError:
                pass
        conn.commit()
