from __future__ import annotations
import aiosqlite
from contextlib import asynccontextmanager
from app.config import settings


@asynccontextmanager
async def db_conn():
    """
    Open a fresh aiosqlite connection for one operation, then close it.
    Each request / background job gets its own connection — no shared state.
    SQLite WAL mode makes concurrent reads fast and concurrent writes safe.
    """
    async with aiosqlite.connect(settings.database_path) as db:
        db.row_factory = aiosqlite.Row
        yield db


async def run_migrations(db_path: str):
    """Run at startup inside FastAPI lifespan. Idempotent — safe to re-run."""
    async with aiosqlite.connect(db_path) as db:
        await db.execute("PRAGMA journal_mode=WAL")
        await db.execute("PRAGMA synchronous=NORMAL")  # WAL + NORMAL = safe + fast
        await db.executescript(_SCHEMA)
        # Column-level migrations: each runs in its own try/except so that
        # "duplicate column name" errors (column already added) are silently ignored.
        for stmt in _COLUMN_MIGRATIONS:
            try:
                await db.execute(stmt)
            except Exception:
                pass  # column already exists or index already created
        # Ensure default schedule session exists for old messages with session_id='default'
        await db.execute("""
            INSERT OR IGNORE INTO schedule_sessions (id, title, created_at, updated_at)
            VALUES ('default', '默认对话', datetime('now'), datetime('now'))
        """)
        # MiMo provider as custom (editable from UI)
        await db.execute("""
            INSERT OR IGNORE INTO custom_providers (id, data_json)
            VALUES ('xiaomimimo', '{"id":"xiaomimimo","name":"小米 MiMo","base_url":"https://token-plan-sgp.xiaomimimo.com/v1","api_type":"xiaomiMimo","models":["mimo-v2.5-pro"],"api_key":"","icon_name":"m-circle","color_hex":"FF6900"}')
        """)
        await db.commit()


_SCHEMA = """
    CREATE TABLE IF NOT EXISTS settings (
        key   TEXT PRIMARY KEY,
        value TEXT
    );

    CREATE TABLE IF NOT EXISTS conversations (
        id                              TEXT PRIMARY KEY,
        title                           TEXT NOT NULL DEFAULT 'New Chat',
        provider_id                     TEXT NOT NULL DEFAULT 'openai',
        model                           TEXT NOT NULL DEFAULT 'gpt-4o',
        agent_mode                      TEXT NOT NULL DEFAULT 'normal',
        system_prompt                   TEXT NOT NULL DEFAULT '',
        context_summary                 TEXT,
        context_summary_message_count   INTEGER,
        context_summary_updated_at      TEXT,
        created_at                      TEXT NOT NULL,
        updated_at                      TEXT NOT NULL
    );

    CREATE TABLE IF NOT EXISTS messages (
        id                   TEXT PRIMARY KEY,
        conversation_id      TEXT NOT NULL REFERENCES conversations(id) ON DELETE CASCADE,
        role                 TEXT NOT NULL,
        content              TEXT NOT NULL DEFAULT '',
        reasoning_content    TEXT,
        usage_json           TEXT,
        schedule_payload_json TEXT,
        chat_list_payload_json TEXT,
        timestamp            TEXT NOT NULL,
        position             INTEGER NOT NULL
    );
    CREATE INDEX IF NOT EXISTS idx_messages_conv ON messages(conversation_id, position);

    CREATE TABLE IF NOT EXISTS schedule_sessions (
        id          TEXT PRIMARY KEY,
        title       TEXT NOT NULL DEFAULT '新对话',
        created_at  TEXT NOT NULL,
        updated_at  TEXT NOT NULL
    );

    CREATE TABLE IF NOT EXISTS schedule_messages (
        id                    TEXT PRIMARY KEY,
        session_id            TEXT NOT NULL DEFAULT 'default',
        role                  TEXT NOT NULL,
        content               TEXT NOT NULL DEFAULT '',
        reasoning_content     TEXT,
        usage_json            TEXT,
        schedule_payload_json TEXT,
        timestamp             TEXT NOT NULL,
        position              INTEGER NOT NULL
    );
    -- NOTE: idx_schedule_messages_session is created in _COLUMN_MIGRATIONS
    -- (session_id may not exist yet on an older DB at the time _SCHEMA runs)

    CREATE TABLE IF NOT EXISTS server_reminders (
        id           TEXT PRIMARY KEY,
        title        TEXT NOT NULL,
        list_name    TEXT NOT NULL DEFAULT '默认',
        due_at       TEXT,
        notes        TEXT,
        is_completed INTEGER NOT NULL DEFAULT 0,
        is_important INTEGER NOT NULL DEFAULT 0,
        created_at   TEXT NOT NULL,
        updated_at   TEXT NOT NULL
    );

    CREATE TABLE IF NOT EXISTS server_events (
        id            TEXT PRIMARY KEY,
        title         TEXT NOT NULL,
        calendar_name TEXT NOT NULL DEFAULT 'Web 日程',
        start_at      TEXT NOT NULL,
        end_at        TEXT NOT NULL,
        location      TEXT,
        notes         TEXT,
        is_all_day    INTEGER NOT NULL DEFAULT 0,
        kind          TEXT NOT NULL DEFAULT 'event',
        created_at    TEXT NOT NULL,
        updated_at    TEXT NOT NULL
    );

    CREATE TABLE IF NOT EXISTS server_courses (
        id            TEXT PRIMARY KEY,
        title         TEXT NOT NULL,
        calendar_name TEXT NOT NULL DEFAULT '本地课程表',
        start_at      TEXT NOT NULL,
        end_at        TEXT NOT NULL,
        location      TEXT,
        notes         TEXT,
        created_at    TEXT NOT NULL,
        updated_at    TEXT NOT NULL
    );

    CREATE TABLE IF NOT EXISTS chaoxing_session (
        id          INTEGER PRIMARY KEY CHECK (id = 1),
        cookies_json TEXT,
        uid         TEXT,
        username    TEXT,
        phone       TEXT,
        logged_in_at TEXT
    );

    CREATE TABLE IF NOT EXISTS chaoxing_courses (
        id           TEXT PRIMARY KEY,
        class_id     TEXT NOT NULL,
        cpi          TEXT NOT NULL DEFAULT '',
        name         TEXT NOT NULL,
        teacher      TEXT NOT NULL DEFAULT '',
        image        TEXT NOT NULL DEFAULT '',
        synced_at    TEXT NOT NULL
    );

    CREATE TABLE IF NOT EXISTS chaoxing_assignments (
        id           TEXT PRIMARY KEY,
        course_id    TEXT NOT NULL,
        course_name  TEXT NOT NULL DEFAULT '',
        title        TEXT NOT NULL,
        description  TEXT NOT NULL DEFAULT '',
        due_date     TEXT,
        status       TEXT NOT NULL DEFAULT '未交',
        synced_at    TEXT NOT NULL
    );

    CREATE TABLE IF NOT EXISTS chaoxing_memory_entries (
        id              TEXT PRIMARY KEY,
        source_message_id TEXT,
        conversation_id TEXT,
        conversation_name TEXT,
        sender_id       TEXT,
        sender_name     TEXT,
        title           TEXT NOT NULL,
        summary         TEXT NOT NULL,
        reason          TEXT NOT NULL,
        action_hint     TEXT,
        importance      TEXT NOT NULL DEFAULT 'medium',
        sent_at         TEXT NOT NULL,
        extracted_at    TEXT NOT NULL,
        expires_at      TEXT,
        archived_at     TEXT,
        source_text_preview TEXT
    );

    CREATE TABLE IF NOT EXISTS chaoxing_probe_signatures (
        conversation_id TEXT PRIMARY KEY,
        signature       TEXT NOT NULL,
        updated_at      TEXT NOT NULL
    );

    CREATE TABLE IF NOT EXISTS chaoxing_sync_state (
        key   TEXT PRIMARY KEY,
        value TEXT NOT NULL
    );

    CREATE TABLE IF NOT EXISTS chaoxing_processed_ids (
        message_id  TEXT PRIMARY KEY,
        processed_at TEXT NOT NULL
    );

    -- Fingerprint-level dedup (complements chaoxing_processed_ids, which is id-level)
    CREATE TABLE IF NOT EXISTS chaoxing_processed_fingerprints (
        fingerprint  TEXT PRIMARY KEY,
        processed_at TEXT NOT NULL
    );

    -- Per-conversation sync state: tracks the newest message we have seen per chat
    CREATE TABLE IF NOT EXISTS chaoxing_conversation_sync (
        conversation_id      TEXT PRIMARY KEY,
        last_seen_sent_at    TEXT,
        last_seen_message_id TEXT,
        seen_count           INTEGER NOT NULL DEFAULT 0,
        created_at           TEXT NOT NULL,
        updated_at           TEXT NOT NULL
    );

    CREATE TABLE IF NOT EXISTS custom_providers (
        id          TEXT PRIMARY KEY,
        data_json   TEXT NOT NULL
    );

    CREATE TABLE IF NOT EXISTS push_subscriptions (
        id          INTEGER PRIMARY KEY AUTOINCREMENT,
        endpoint    TEXT UNIQUE NOT NULL,
        p256dh      TEXT NOT NULL,
        auth        TEXT NOT NULL,
        user_agent  TEXT,
        created_at  TEXT NOT NULL
    );

    CREATE TABLE IF NOT EXISTS notification_log (
        id          INTEGER PRIMARY KEY AUTOINCREMENT,
        item_id     TEXT NOT NULL,
        notif_type  TEXT NOT NULL,
        sent_at     TEXT NOT NULL,
        UNIQUE(item_id, notif_type)
    );

    CREATE TABLE IF NOT EXISTS scheduled_notifications (
        id           TEXT PRIMARY KEY,
        title        TEXT NOT NULL,
        body         TEXT NOT NULL,
        scheduled_at TEXT NOT NULL,   -- ISO-8601，到了这个时间就推
        source_id    TEXT,            -- 关联的 reminder/event id（可选）
        source_type  TEXT NOT NULL DEFAULT 'agent',  -- "reminder"|"event"|"agent"
        reason       TEXT,
        created_at   TEXT NOT NULL,
        sent_at      TEXT,            -- 推出后填写，NULL 表示未推
        cancelled_at TEXT             -- 取消后填写
    );
    CREATE INDEX IF NOT EXISTS idx_sched_notif_fire
        ON scheduled_notifications(scheduled_at)
        WHERE sent_at IS NULL AND cancelled_at IS NULL;

    CREATE TABLE IF NOT EXISTS standby_agent_log (
        id          INTEGER PRIMARY KEY AUTOINCREMENT,
        ran_at      TEXT NOT NULL,
        decision    TEXT NOT NULL,
        push_title  TEXT,
        push_body   TEXT,
        model       TEXT,
        input_tokens  INTEGER,
        output_tokens INTEGER,
        duration_ms   INTEGER
    );

    CREATE TABLE IF NOT EXISTS user_memory (
        id         INTEGER PRIMARY KEY AUTOINCREMENT,
        category   TEXT NOT NULL DEFAULT 'preference',
        key        TEXT NOT NULL,
        value      TEXT NOT NULL,
        source     TEXT NOT NULL DEFAULT 'user_told',
        created_at TEXT NOT NULL DEFAULT (datetime('now')),
        updated_at TEXT NOT NULL DEFAULT (datetime('now')),
        UNIQUE(key)
    );

    CREATE TABLE IF NOT EXISTS model_pricing (
        model       TEXT PRIMARY KEY,
        input_rate  REAL NOT NULL,
        output_rate REAL NOT NULL,
        updated_at  TEXT NOT NULL DEFAULT (datetime('now'))
    );
"""

# ---------------------------------------------------------------------------
# Column-level migrations
# Each statement is attempted individually; failures (duplicate column name,
# duplicate index name) are silently ignored so re-runs are always safe.
# ---------------------------------------------------------------------------
_COLUMN_MIGRATIONS: list[str] = [
    # ── chaoxing_session: timestamps ────────────────────────────────────────
    "ALTER TABLE chaoxing_session ADD COLUMN last_active_at TEXT",
    "ALTER TABLE chaoxing_session ADD COLUMN updated_at TEXT",

    # ── chaoxing_memory_entries: full schema extension ─────────────────────
    # Identification & dedup
    "ALTER TABLE chaoxing_memory_entries ADD COLUMN dedupe_key TEXT NOT NULL DEFAULT ''",
    "ALTER TABLE chaoxing_memory_entries ADD COLUMN category TEXT NOT NULL DEFAULT 'notice'",
    "ALTER TABLE chaoxing_memory_entries ADD COLUMN confidence REAL NOT NULL DEFAULT 0.75",
    # Temporal
    "ALTER TABLE chaoxing_memory_entries ADD COLUMN content_time TEXT",
    "ALTER TABLE chaoxing_memory_entries ADD COLUMN created_at TEXT",
    "ALTER TABLE chaoxing_memory_entries ADD COLUMN updated_at TEXT",
    # Source provenance (JSON arrays)
    "ALTER TABLE chaoxing_memory_entries ADD COLUMN source_ids_json TEXT NOT NULL DEFAULT '[]'",
    "ALTER TABLE chaoxing_memory_entries ADD COLUMN source_fingerprints_json TEXT NOT NULL DEFAULT '[]'",
    "ALTER TABLE chaoxing_memory_entries ADD COLUMN conversation_ids_json TEXT NOT NULL DEFAULT '[]'",
    "ALTER TABLE chaoxing_memory_entries ADD COLUMN conversation_names_json TEXT NOT NULL DEFAULT '[]'",
    "ALTER TABLE chaoxing_memory_entries ADD COLUMN sender_names_json TEXT NOT NULL DEFAULT '[]'",
    # Linkage
    "ALTER TABLE chaoxing_memory_entries ADD COLUMN linked_assignment_key TEXT",
    "ALTER TABLE chaoxing_memory_entries ADD COLUMN linked_course_key TEXT",
    # Unique index on dedupe_key (partial: excludes the empty-string default)
    "CREATE UNIQUE INDEX IF NOT EXISTS idx_memory_dedupe "
    "ON chaoxing_memory_entries(dedupe_key) WHERE dedupe_key != ''",
    # Unified memory: kind + cross-references
    "ALTER TABLE chaoxing_memory_entries ADD COLUMN kind TEXT NOT NULL DEFAULT 'message'",
    "ALTER TABLE chaoxing_memory_entries ADD COLUMN related_ids_json TEXT NOT NULL DEFAULT '[]'",

    # ── Modular memory: multi-source + hierarchy ──────────────────────────
    # source_type: which provider wrote this entry
    #   'chaoxing' | 'dingtalk' | 'idea' | 'shopping' | 'user' | 'system'
    "ALTER TABLE chaoxing_memory_entries ADD COLUMN source_type TEXT NOT NULL DEFAULT 'chaoxing'",
    # hierarchy_tier: importance for context injection
    #   0=CRITICAL(today/urgent)  1=ACTIONABLE(this week, has action)
    #   2=CONTEXT(background info) 3=REFERENCE(ideas,notes) 4=HISTORICAL(archived summaries)
    "ALTER TABLE chaoxing_memory_entries ADD COLUMN hierarchy_tier INTEGER NOT NULL DEFAULT 2",
    # for_automation: 1 = automation tasks can act on this (has action_hint + clear deadline)
    "ALTER TABLE chaoxing_memory_entries ADD COLUMN for_automation INTEGER NOT NULL DEFAULT 0",
    # memory_synced_at: last time this source's data was scanned for memory extraction
    "CREATE TABLE IF NOT EXISTS memory_sync_state ("
    "  source_type TEXT PRIMARY KEY,"
    "  last_synced_ts INTEGER NOT NULL DEFAULT 0,"  # ms timestamp, matches dingtalk created_at
    "  last_run_at    TEXT,"
    "  entry_count    INTEGER NOT NULL DEFAULT 0"
    ")",
    # index for tier-based retrieval
    "CREATE INDEX IF NOT EXISTS idx_memory_tier "
    "ON chaoxing_memory_entries(hierarchy_tier, archived_at, expires_at)",
    # index for source-type retrieval
    "CREATE INDEX IF NOT EXISTS idx_memory_source "
    "ON chaoxing_memory_entries(source_type, archived_at)",

    # ── memory_topic_index: O(1) entity lookup for automation engine ─────────
    # Written when memory entries are upserted; supports fast entity resolution
    # without full-table scans.  Multiple keys per entry (full name + substrings).
    """CREATE TABLE IF NOT EXISTS memory_topic_index (
        entity_key   TEXT NOT NULL,
        entity_type  TEXT NOT NULL DEFAULT 'general',
        memory_id    TEXT NOT NULL,
        source_type  TEXT NOT NULL DEFAULT 'unknown',
        expires_at   TEXT,
        PRIMARY KEY (entity_key, memory_id)
    )""",
    "CREATE INDEX IF NOT EXISTS idx_topic_key "
    "ON memory_topic_index(entity_key)",

    # ── scheduled_notifications: rule explanation ─────────────────────────
    "ALTER TABLE scheduled_notifications ADD COLUMN reason TEXT",

    # ── notification delivery state ───────────────────────────────────────
    "ALTER TABLE notification_log ADD COLUMN device_received_at TEXT",
    "ALTER TABLE notification_log ADD COLUMN clicked_at TEXT",
    "ALTER TABLE notification_log ADD COLUMN dismissed_at TEXT",

    # ── notification title/body snapshot ──────────────────────────────────
    "ALTER TABLE notification_log ADD COLUMN push_title TEXT",
    "ALTER TABLE notification_log ADD COLUMN push_body TEXT",

    # ── schedule_messages: session support ────────────────────────────────
    "ALTER TABLE schedule_messages ADD COLUMN session_id TEXT NOT NULL DEFAULT 'default'",
    "CREATE INDEX IF NOT EXISTS idx_schedule_messages_session ON schedule_messages(session_id, position)",

    # ── standby_agent_log: reason column ─────────────────────────────────
    "ALTER TABLE standby_agent_log ADD COLUMN reason TEXT",

    # ── dingtalk_filter_config: user-configurable filter rules ───────────
    # Single-row config table (id=1). conv_mode controls conversation filtering:
    #   'all'       — process all conversations (default)
    #   'whitelist' — only process conversations in conv_list_json
    #   'blacklist' — skip conversations in conv_list_json
    """CREATE TABLE IF NOT EXISTS dingtalk_filter_config (
        id                          INTEGER PRIMARY KEY DEFAULT 1,
        conv_mode                   TEXT NOT NULL DEFAULT 'all',
        conv_list_json              TEXT NOT NULL DEFAULT '[]',
        custom_include_kw_json      TEXT NOT NULL DEFAULT '[]',
        custom_exclude_kw_json      TEXT NOT NULL DEFAULT '[]',
        min_text_length             INTEGER NOT NULL DEFAULT 5,
        updated_at                  TEXT
    )""",
    "INSERT OR IGNORE INTO dingtalk_filter_config (id) VALUES (1)",
]
