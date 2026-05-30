# ChatBot Web — Phase 2 Implementation Spec

> **Audience**: A coding agent picking up from Phase 1.
> **Prerequisite**: Phase 1 is running (`docker compose up` passes `/health`).
> **Source**: `/Users/macalan/Documents/chatbot/web/`
> **Goal**: Fix a critical DB concurrency bug, add a push notification skill for the agent,
> build an always-on standby agent that makes LLM-driven push decisions, and wire up a
> complete debug pipeline so every subsystem can be verified independently.

---

## 0. Context — What Phase 1 Built

```
backend/app/
  services/
    api_service.py       # OpenAI / Anthropic / Gemini streaming (complete)
    agent_service.py     # Agentic loop with parallel tools, Bug 1–4 fixed (complete)
    chaoxing_service.py  # Chaoxing HTTP client (complete, HTTP stubs need real endpoints)
    schedule_agent.py    # Schedule agent with tools (complete)
    push_service.py      # pywebpush sender (complete)
  routers/
    chat.py              # SSE streaming chat (complete)
    conversations.py     # CRUD (complete)
    push.py              # subscribe / unsubscribe / test (complete)
    schedule.py          # schedule agent endpoint (complete)
    ...
  tasks/
    scheduler.py         # APScheduler with adaptive Chaoxing probe (complete)
    chaoxing_sync.py     # Adaptive probe job (complete)
    notification_sender.py # Rule-based deadline push (complete)
  database.py            # ⚠️ BROKEN — global singleton, fix first
  main.py                # FastAPI lifespan (complete)
```

Phase 1 left **one critical bug** and **three missing features**:

| # | Issue | Severity |
|---|---|---|
| B1 | `get_db()` global singleton causes SQLite concurrency crashes | 🔴 Critical |
| F1 | No `send_push_notification` tool — agent cannot push | Missing |
| F2 | No Standby Agent — backend never makes LLM-driven push decisions | Missing |
| F3 | No debug endpoints — failures are invisible | Missing |

---

## 1. Fix B1 — `database.py` Concurrency

### Problem

`database.py` holds a single global `aiosqlite.Connection` (`_db`). When multiple SSE
streams run concurrently with APScheduler background jobs, they all share one connection.
SQLite in WAL mode allows concurrent reads, but concurrent writes on a single connection
object cause `ProgrammingError: cannot operate on a closed database` or silent corruption.

### Fix — Replace global singleton with a context manager

Rewrite `database.py` completely:

```python
# backend/app/database.py
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

    CREATE TABLE IF NOT EXISTS schedule_messages (
        id                    TEXT PRIMARY KEY,
        role                  TEXT NOT NULL,
        content               TEXT NOT NULL DEFAULT '',
        reasoning_content     TEXT,
        usage_json            TEXT,
        schedule_payload_json TEXT,
        timestamp             TEXT NOT NULL,
        position              INTEGER NOT NULL
    );

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

    CREATE TABLE IF NOT EXISTS standby_agent_log (
        id          INTEGER PRIMARY KEY AUTOINCREMENT,
        ran_at      TEXT NOT NULL,
        decision    TEXT NOT NULL,   -- "push" | "no_action" | "error"
        push_title  TEXT,
        push_body   TEXT,
        model       TEXT,
        input_tokens  INTEGER,
        output_tokens INTEGER,
        duration_ms   INTEGER
    );
"""
```

### Migration for callers

Every place that previously called `get_db()` must switch to:

```python
from app.database import db_conn

async with db_conn() as db:
    row = await (await db.execute("SELECT ...")).fetchone()
    await db.commit()
```

**Files to update** (grep for `get_db`):
- `routers/chat.py`
- `routers/conversations.py`
- `routers/schedule.py`
- `routers/chaoxing.py`
- `routers/settings.py`
- `routers/push.py`
- `routers/reminders.py`
- `services/schedule_agent.py`
- `services/memory_agent.py`
- `services/chaoxing_service.py`
- `tasks/chaoxing_sync.py`
- `tasks/notification_sender.py`

Run `grep -rn "get_db" backend/` to find all callers.

---

## 2. Feature F1 — `send_push_notification` Agent Tool

### Where to add it

Add to both:
1. `CHAT_TOOLS` list in `routers/chat.py`
2. `_build_schedule_tools()` in `services/schedule_agent.py`

### Tool definition

```python
ToolDefinition(
    name="send_push_notification",
    description=(
        "向用户手机发送推送通知。"
        "仅当以下情况使用：用户明确要求提醒、有重要截止日期、"
        "或需要在用户不看屏幕时告知重要信息。"
        "不要滥用——只在真正需要打扰用户时调用。"
        "每次调用发送一条通知。"
    ),
    input_schema={
        "type": "object",
        "properties": {
            "title": {
                "type": "string",
                "description": "通知标题，简短（15字以内）",
            },
            "body": {
                "type": "string",
                "description": "通知正文，具体说明事项（50字以内）",
            },
            "urgency": {
                "type": "string",
                "enum": ["low", "normal", "high"],
                "description": "high=截止/紧急，normal=一般提醒，low=仅供参考",
            },
        },
        "required": ["title", "body"],
        "additionalProperties": False,
    },
)
```

### Tool executor

Add this branch to `_execute_chat_tool()` in `chat.py` and `_execute_schedule_tool()` in
`schedule_agent.py`:

```python
elif tc.name == "send_push_notification":
    from app.services.push_service import send_push_to_all_subscribers
    import uuid

    title   = tc.arguments.get("title", "").strip()
    body    = tc.arguments.get("body", "").strip()
    urgency = tc.arguments.get("urgency", "normal")

    if not title or not body:
        return "错误: title 和 body 不能为空"

    result = await send_push_to_all_subscribers(
        settings.database_path,
        title=title,
        body=body,
        tag=f"agent-{uuid.uuid4().hex[:8]}",
        data={"type": "agent_push", "urgency": urgency},
    )
    attempted = result.get("attempted", 0)
    if attempted == 0:
        return "推送未发出：没有已注册的订阅设备（用户未开启推送）"
    return f"推送已发送到 {attempted} 台设备：{title}"
```

### `filter_relevant_tools` update

Add keywords so the tool gets included when relevant:

```python
def _tool_keywords(tool_name: str) -> list[str]:
    return {
        "fetch_url":               ["http", "url", "网页", "链接", "网站"],
        "search_web":              ["搜索", "查找", "找", "search"],
        "read_pdf":                ["pdf", "文件", "文档"],
        "get_schedule_context":    ["课", "作业", "日程", "提醒"],
        "send_push_notification":  ["提醒", "通知", "推送", "notify", "remind",
                                    "截止", "deadline", "别忘了", "记得"],
    }.get(tool_name, [tool_name])
```

---

## 3. Feature F2 — Standby Agent

### Concept

The standby agent runs on a background schedule. Unlike rule-based notification logic
(which checks `delta < 1h`), the standby agent passes the full context to an LLM and
lets it decide what — if anything — to push. It has two tools:

- `send_push_notification` — push something
- `no_action` — explicitly do nothing (forces the model to make a decision rather than just
  generating text)

The model MUST call one of these tools. If it generates text without a tool call, treat it
as `no_action`.

### New file: `tasks/standby_agent.py`

```python
"""
Standby Agent — LLM-driven push decision maker.

Runs on a schedule (default: every 15 minutes).
Reads current context from DB, calls LLM, executes its tool call.

The agent has two tools:
  - send_push_notification: push a notification to all subscribers
  - no_action: do nothing (model must always call one of the two)

Design goals:
  - Low cost: use the cheapest available model (economical_model())
  - Low latency: context is pre-built from DB, no Chaoxing network calls
  - Auditable: every run is logged to standby_agent_log table
  - Safe: no_action is always valid; never push the same item twice
"""

import asyncio
import json
import uuid
from datetime import datetime, timezone, timedelta
import aiosqlite

from app.database import db_conn
from app.config import settings
from app.services.agent_service import AgentMsg, ToolDefinition, ToolCall, agent_complete
from app.services.push_service import send_push_to_all_subscribers, has_notified, log_notification_sent


# ── Tool definitions ──────────────────────────────────────────────────────────

STANDBY_TOOLS = [
    ToolDefinition(
        name="send_push_notification",
        description=(
            "向用户手机发送一条推送通知。"
            "仅当有真正需要用户立即知道的事情时调用。"
        ),
        input_schema={
            "type": "object",
            "properties": {
                "title":   {"type": "string", "description": "通知标题（15字以内）"},
                "body":    {"type": "string", "description": "通知正文（50字以内）"},
                "item_id": {"type": "string", "description": "关联条目的唯一ID，用于去重"},
                "urgency": {
                    "type": "string",
                    "enum": ["low", "normal", "high"],
                },
            },
            "required": ["title", "body", "item_id"],
            "additionalProperties": False,
        },
    ),
    ToolDefinition(
        name="no_action",
        description=(
            "不发送任何通知。"
            "当没有需要提醒用户的事项、或该事项已经通知过时，调用此工具。"
        ),
        input_schema={
            "type": "object",
            "properties": {
                "reason": {"type": "string", "description": "简要说明不推送的原因"},
            },
            "required": ["reason"],
            "additionalProperties": False,
        },
    ),
]


# ── System prompt ─────────────────────────────────────────────────────────────

def _build_system_prompt(now: datetime) -> str:
    return f"""你是一个后台日程助理，每隔一段时间被唤醒，检查用户的日程和消息，决定是否需要主动推送通知提醒用户。

当前时间：{now.strftime('%Y-%m-%d %H:%M')} (CST, UTC+8)，{_weekday_cn(now)}

你必须调用以下两个工具之一：
- send_push_notification：向用户手机推送通知（只在真正需要时使用）
- no_action：不做任何操作

决策标准：
1. 作业/任务截止时间在 3 小时内 → 推送（高优先级）
2. 截止时间在 24 小时内且尚未推送过 → 推送（普通优先级）
3. 有未处理的高重要度学习通消息（action_hint 非空）→ 考虑推送
4. 以上都没有 → 调用 no_action
5. 已经推送过的条目（已在通知记录中）→ no_action，不要重复打扰

你只能发送一条通知，选最重要的一件事。绝对不要发送多条。
不要向用户解释你在做什么——直接调用工具。""".strip()


def _weekday_cn(dt: datetime) -> str:
    return ["周一","周二","周三","周四","周五","周六","周日"][dt.weekday()]


# ── Context builder ───────────────────────────────────────────────────────────

async def _build_context(db_path: str, now: datetime) -> str:
    """
    Build a text summary of current context from DB.
    Does NOT make any network calls — all data comes from local cache.
    """
    lines = []

    async with aiosqlite.connect(db_path) as db:
        db.row_factory = aiosqlite.Row

        # Pending assignments from chaoxing (cached)
        rows = await (await db.execute("""
            SELECT title, due_at, course_name
            FROM chaoxing_assignments_cache
            WHERE is_completed = 0
            AND (due_at IS NULL OR datetime(due_at) > datetime('now'))
            ORDER BY due_at ASC
            LIMIT 10
        """)).fetchall() if await _table_exists(db, "chaoxing_assignments_cache") else []

        # Fallback: server_reminders
        reminder_rows = await (await db.execute("""
            SELECT id, title, due_at, is_important
            FROM server_reminders
            WHERE is_completed = 0
            AND (due_at IS NULL OR datetime(due_at) > datetime('now'))
            ORDER BY due_at ASC
            LIMIT 10
        """)).fetchall()

        # High-importance memory entries (not archived, not expired)
        memory_rows = await (await db.execute("""
            SELECT id, title, action_hint, importance, sent_at
            FROM chaoxing_memory_entries
            WHERE importance IN ('high', 'medium')
            AND archived_at IS NULL
            AND (expires_at IS NULL OR datetime(expires_at) > datetime('now'))
            ORDER BY CASE importance WHEN 'high' THEN 0 ELSE 1 END, extracted_at DESC
            LIMIT 5
        """)).fetchall()

    if not reminder_rows and not memory_rows:
        return "当前没有待办事项或重要消息。"

    if reminder_rows:
        lines.append("【待办事项】")
        for r in reminder_rows:
            r = dict(r)
            due = _fmt_due(r.get("due_at"), now)
            imp = "⭐ " if r.get("is_important") else ""
            lines.append(f"  - {imp}{r['title']}  {due}  [id:{r['id']}]")

    if memory_rows:
        lines.append("【重要学习通消息】")
        for r in memory_rows:
            r = dict(r)
            hint = f"→ {r['action_hint']}" if r.get("action_hint") else ""
            lines.append(f"  - [{r['importance']}] {r['title']}  {hint}  [id:{r['id']}]")

    return "\n".join(lines)


async def _table_exists(db, name: str) -> bool:
    row = await (await db.execute(
        "SELECT 1 FROM sqlite_master WHERE type='table' AND name=?", (name,)
    )).fetchone()
    return row is not None


def _fmt_due(due_str: str | None, now: datetime) -> str:
    if not due_str:
        return "(无截止时间)"
    try:
        due = datetime.fromisoformat(due_str)
        if due.tzinfo is None:
            due = due.replace(tzinfo=timezone.utc)
        delta = due - now
        total = int(delta.total_seconds())
        if total < 0:
            return "(已过期)"
        h, m = divmod(total // 60, 60)
        if delta <= timedelta(hours=3):
            return f"⚠️ 还剩 {h}h{m}m"
        if delta <= timedelta(hours=24):
            return f"还剩 {h}h{m}m"
        return f"截止 {due.strftime('%m-%d %H:%M')}"
    except Exception:
        return ""


# ── Tool executor ─────────────────────────────────────────────────────────────

async def _execute_standby_tool(tc: ToolCall, db_path: str, now: datetime) -> tuple[str, str, str | None]:
    """
    Returns (decision, push_title_or_none, push_body_or_none).
    decision = "push" | "no_action" | "error"
    """
    if tc.name == "no_action":
        return "no_action", None, None

    if tc.name == "send_push_notification":
        title   = tc.arguments.get("title", "").strip()
        body    = tc.arguments.get("body", "").strip()
        item_id = tc.arguments.get("item_id", uuid.uuid4().hex)
        urgency = tc.arguments.get("urgency", "normal")

        if not title or not body:
            return "error", None, None

        # Dedup: don't push same item twice with standby_agent type
        if await has_notified(db_path, item_id, "standby_agent"):
            return "no_action", None, None

        await send_push_to_all_subscribers(
            db_path,
            title=title,
            body=body,
            tag=f"standby-{item_id[:12]}",
            data={"type": "standby_push", "urgency": urgency, "item_id": item_id},
        )
        await log_notification_sent(db_path, item_id, "standby_agent")
        return "push", title, body

    return "error", None, None


# ── Main entry point ──────────────────────────────────────────────────────────

async def run_standby_agent(app_state):
    """
    Called by APScheduler every N minutes.
    Runs an LLM call with context, executes its tool decision, logs result.
    """
    from app.services.provider_registry import resolve_provider
    from app.services.agent_service import merge_system_messages

    db_path = app_state.settings.database_path
    now = datetime.now(timezone.utc)
    t0 = asyncio.get_event_loop().time()

    # Check if there are any push subscribers — skip if none
    async with aiosqlite.connect(db_path) as db:
        sub_count = (await (await db.execute(
            "SELECT COUNT(*) FROM push_subscriptions"
        )).fetchone())[0]

    if sub_count == 0:
        return  # No subscribers, nothing to do

    # Build context and messages
    context = await _build_context(db_path, now)
    system_prompt = _build_system_prompt(now)

    messages = [
        AgentMsg(role="system", content=system_prompt),
        AgentMsg(role="user", content=f"当前状态：\n{context}\n\n请根据以上信息决定是否推送通知。"),
    ]
    messages = merge_system_messages(messages)

    # Resolve provider — use cheapest available model
    provider, api_key = await resolve_provider(
        app_state.settings.standby_agent_provider or "openai"
    )
    model = app_state.settings.standby_agent_model or "gpt-4o-mini"

    decision = "error"
    push_title = None
    push_body = None
    input_tokens = 0
    output_tokens = 0

    try:
        response = await agent_complete(
            messages, STANDBY_TOOLS, provider, model, api_key,
            thinking_budget=0,
        )
        if response.usage:
            input_tokens  = response.usage.input_tokens
            output_tokens = response.usage.output_tokens

        if response.tool_calls:
            tc = response.tool_calls[0]  # Only process first tool call
            decision, push_title, push_body = await _execute_standby_tool(tc, db_path, now)
        else:
            # Model generated text but no tool call — treat as no_action
            decision = "no_action"

    except Exception as e:
        decision = "error"
        print(f"[StandbyAgent] Error: {e}")

    # Log result
    duration_ms = int((asyncio.get_event_loop().time() - t0) * 1000)
    async with aiosqlite.connect(db_path) as db:
        await db.execute(
            """INSERT INTO standby_agent_log
               (ran_at, decision, push_title, push_body, model, input_tokens, output_tokens, duration_ms)
               VALUES (?,?,?,?,?,?,?,?)""",
            (now.isoformat(), decision, push_title, push_body,
             model, input_tokens, output_tokens, duration_ms),
        )
        await db.commit()

    print(f"[StandbyAgent] {now.strftime('%H:%M')} → {decision}"
          + (f": {push_title}" if push_title else ""))
```

### Wire into scheduler

In `tasks/scheduler.py`, add the standby job:

```python
from app.tasks.standby_agent import run_standby_agent

scheduler.add_job(
    run_standby_agent,
    IntervalTrigger(minutes=app_state.settings.standby_interval_minutes),
    args=[app_state],
    id="standby_agent",
    misfire_grace_time=120,
    replace_existing=True,
)
```

### Config additions (`config.py`)

```python
standby_interval_minutes: int = 15       # how often standby agent runs
standby_agent_provider: str = "openai"   # provider for standby agent
standby_agent_model: str = "gpt-4o-mini" # cheap model for standby
```

And `.env.example`:
```bash
STANDBY_INTERVAL_MINUTES=15
STANDBY_AGENT_PROVIDER=openai
STANDBY_AGENT_MODEL=gpt-4o-mini
```

---

## 4. Feature F3 — Debug Pipeline

### New file: `routers/debug.py`

Mount only when `DEBUG=true` in `.env`. These endpoints let you test each subsystem
independently without needing a frontend.

```python
"""
Debug endpoints — only mounted when settings.debug == True.
NEVER expose in production.

Usage:
  curl http://localhost:8080/api/debug/sse
  curl -X POST http://localhost:8080/api/debug/agent
  curl -X POST http://localhost:8080/api/debug/push -H "Content-Type: application/json" \
       -d '{"title":"Test","body":"Hello"}'
  curl http://localhost:8080/api/debug/db
  curl http://localhost:8080/api/debug/scheduler
  curl -X POST http://localhost:8080/api/debug/standby
"""

from fastapi import APIRouter
from fastapi.responses import StreamingResponse
import json, asyncio, time
from app.database import db_conn
from app.config import settings

router = APIRouter(prefix="/api/debug", tags=["debug"])
```

#### `GET /api/debug/sse` — Test SSE streaming

Streams 10 numbered tokens over 2 seconds. Verifies nginx buffering config is correct.

```python
@router.get("/sse")
async def debug_sse():
    """Stream 10 tokens. If you see them all at once at the end, nginx is buffering — fix nginx.conf."""
    async def generate():
        for i in range(10):
            yield f"data: {json.dumps({'type': 'text', 'content': f'token_{i} '})}\n\n"
            await asyncio.sleep(0.2)
        yield f"data: {json.dumps({'type': 'done'})}\n\n"

    return StreamingResponse(
        generate(),
        media_type="text/event-stream",
        headers={"Cache-Control": "no-cache", "X-Accel-Buffering": "no"},
    )
```

#### `POST /api/debug/agent` — Test agentic loop

Runs one iteration of the agentic loop with a trivial echo tool.

```python
@router.post("/agent")
async def debug_agent(body: dict = {}):
    """
    Test the agentic loop end-to-end with a fake echo tool.
    Body: {"provider_id": "openai", "model": "gpt-4o-mini", "message": "ping"}
    """
    from app.services.agent_service import AgentMsg, ToolDefinition, run_agentic_loop
    from app.services.provider_registry import resolve_provider

    provider_id = body.get("provider_id", "openai")
    model       = body.get("model", "gpt-4o-mini")
    message     = body.get("message", "Call the echo tool with input 'hello'.")

    provider, api_key = await resolve_provider(provider_id)
    if not api_key:
        return {"error": f"No API key for provider: {provider_id}"}

    echo_tool = ToolDefinition(
        name="echo",
        description="Echo back the input string.",
        input_schema={
            "type": "object",
            "properties": {"input": {"type": "string"}},
            "required": ["input"],
            "additionalProperties": False,
        },
    )

    async def executor(tc):
        return f"Echo: {tc.arguments.get('input', '')}"

    events = []
    async for event in run_agentic_loop(
        [AgentMsg(role="user", content=message)],
        [echo_tool],
        executor,
        provider, model, api_key,
        max_iterations=3,
    ):
        events.append(event)

    return {"events": events, "provider": provider_id, "model": model}
```

#### `POST /api/debug/push` — Test push notification

```python
@router.post("/push")
async def debug_push(body: dict = {}):
    """
    Send a test push to all subscribers.
    Body: {"title": "...", "body": "..."}
    """
    from app.services.push_service import send_push_to_all_subscribers

    title = body.get("title", "Debug Push")
    text  = body.get("body",  f"Test at {__import__('datetime').datetime.now().strftime('%H:%M:%S')}")

    result = await send_push_to_all_subscribers(
        settings.database_path,
        title=title,
        body=text,
        tag="debug-push",
        data={"type": "debug"},
    )
    return result
```

#### `GET /api/debug/db` — Database health

```python
@router.get("/db")
async def debug_db():
    """Show table row counts and WAL mode status."""
    tables = [
        "conversations", "messages", "schedule_messages",
        "chaoxing_memory_entries", "chaoxing_processed_ids",
        "push_subscriptions", "notification_log", "standby_agent_log",
        "settings", "server_reminders",
    ]
    counts = {}
    wal_mode = None

    async with db_conn() as db:
        for t in tables:
            try:
                row = await (await db.execute(f"SELECT COUNT(*) FROM {t}")).fetchone()
                counts[t] = row[0]
            except Exception as e:
                counts[t] = f"ERROR: {e}"
        row = await (await db.execute("PRAGMA journal_mode")).fetchone()
        wal_mode = row[0] if row else "unknown"

    return {"wal_mode": wal_mode, "table_counts": counts}
```

#### `GET /api/debug/scheduler` — Scheduler status

```python
@router.get("/scheduler")
async def debug_scheduler():
    """List all scheduled jobs and their next run times."""
    from app.tasks.scheduler import scheduler

    jobs = []
    for job in scheduler.get_jobs():
        jobs.append({
            "id":       job.id,
            "name":     job.name,
            "next_run": job.next_run_time.isoformat() if job.next_run_time else None,
            "trigger":  str(job.trigger),
        })
    return {"jobs": jobs, "running": scheduler.running}
```

#### `POST /api/debug/standby` — Trigger standby agent manually

```python
@router.post("/standby")
async def debug_standby(request: Request):
    """Manually trigger one standby agent run. Returns the decision and log entry."""
    from app.tasks.standby_agent import run_standby_agent
    from app.database import db_conn

    app_state = request.app.state
    await run_standby_agent(app_state)

    # Return last log entry
    async with db_conn() as db:
        row = await (await db.execute(
            "SELECT * FROM standby_agent_log ORDER BY id DESC LIMIT 1"
        )).fetchone()
    return dict(row) if row else {"error": "no log entry found"}
```

#### `GET /api/debug/chaoxing` — Chaoxing service status

```python
@router.get("/chaoxing")
async def debug_chaoxing(request: Request):
    """Show Chaoxing login state and last sync info."""
    svc = request.app.state.chaoxing_svc

    async with db_conn() as db:
        probe_count = (await (await db.execute(
            "SELECT COUNT(*) FROM chaoxing_probe_signatures"
        )).fetchone())[0]
        processed_count = (await (await db.execute(
            "SELECT COUNT(*) FROM chaoxing_processed_ids"
        )).fetchone())[0]
        memory_count = (await (await db.execute(
            "SELECT COUNT(*) FROM chaoxing_memory_entries WHERE archived_at IS NULL"
        )).fetchone())[0]
        sync_state = await (await db.execute(
            "SELECT key, value FROM chaoxing_sync_state"
        )).fetchall()

    return {
        "is_logged_in":      svc.is_logged_in,
        "uid":               svc.uid,
        "username":          svc.username,
        "probe_signatures":  probe_count,
        "processed_ids":     processed_count,
        "active_memories":   memory_count,
        "sync_state":        {r["key"]: r["value"] for r in sync_state},
    }
```

### Mount debug router in `main.py`

```python
# main.py — add after other routers
if settings.debug:
    from app.routers.debug import router as debug_router
    app.include_router(debug_router)
    print("⚠️  Debug endpoints enabled at /api/debug/*")
```

Add to `config.py`:
```python
debug: bool = False
```

Add to `.env` for local dev:
```bash
DEBUG=true
```

---

## 5. Implementation Order

Execute strictly in this order — each step is a prerequisite for the next.

### Step 1 — Fix DB concurrency (30 min)

1. Rewrite `database.py` as shown in §1
2. Grep for all `get_db()` calls: `grep -rn "get_db" backend/app/`
3. Replace every call with `async with db_conn() as db:`
4. `docker compose up --build` — verify `/health` still returns 200
5. Hammer with concurrent requests: `for i in {1..20}; do curl http://localhost:8080/api/conversations & done`
6. Check logs for any `ProgrammingError` — there should be none

### Step 2 — Mount debug router (15 min)

1. Create `routers/debug.py` with all endpoints from §4
2. Add `debug: bool = False` to `config.py`
3. Set `DEBUG=true` in `.env`
4. Rebuild and verify each debug endpoint manually:
   ```bash
   curl -N http://localhost:8080/api/debug/sse        # should see tokens stream in
   curl http://localhost:8080/api/debug/db            # should see table counts
   curl http://localhost:8080/api/debug/scheduler     # should see jobs list
   curl http://localhost:8080/api/debug/chaoxing      # should see login status
   ```

### Step 3 — Verify SSE pipeline (15 min)

Using the debug endpoint, confirm streaming works correctly:

```bash
# Tokens should appear one by one, NOT all at once
curl -N http://localhost:8080/api/debug/sse
```

If they appear all at once: nginx is buffering. Verify `nginx.conf` has:
```nginx
location ~ ^/api/.+/chat$ {
    proxy_buffering off;
    proxy_cache off;
    proxy_read_timeout 300s;
    proxy_set_header X-Accel-Buffering no;
}
```

### Step 4 — Verify agent pipeline (15 min)

```bash
# Test with OpenAI
curl -X POST http://localhost:8080/api/debug/agent \
  -H "Content-Type: application/json" \
  -d '{"provider_id":"openai","model":"gpt-4o-mini","message":"Call echo with hello"}'

# Expected: events array containing tool_start, tool_result, text, usage
```

If this fails: check API key is in `.env`, check `provider_registry.py` resolves correctly.

### Step 5 — Add push notification tool (20 min)

1. Add `send_push_notification` ToolDefinition to `CHAT_TOOLS` in `chat.py`
2. Add the tool executor branch to `_execute_chat_tool()`
3. Add same tool + executor to `schedule_agent.py`
4. Update `_tool_keywords()` in `agent_service.py`
5. Test push tool via debug endpoint first:
   ```bash
   curl -X POST http://localhost:8080/api/debug/push \
     -H "Content-Type: application/json" \
     -d '{"title":"Test","body":"Push tool works"}'
   ```
6. Then test via chat (requires VAPID keys configured):
   - Create conversation, set agent_mode to `subAgent`
   - Send: "提醒我明天交作业，用推送通知告诉我"
   - Expect: agent calls `send_push_notification`, phone receives notification

### Step 6 — Build standby agent (45 min)

1. Create `tasks/standby_agent.py` as in §3
2. Add `standby_interval_minutes`, `standby_agent_provider`, `standby_agent_model` to `config.py`
3. Add `STANDBY_INTERVAL_MINUTES=15` to `.env`
4. Add `standby_agent_log` table to `database.py` schema (already in §1 schema above)
5. Wire `run_standby_agent` into `scheduler.py`
6. Add `/api/debug/standby` endpoint
7. Test manually:
   ```bash
   curl -X POST http://localhost:8080/api/debug/standby
   # Expected: {"ran_at": "...", "decision": "no_action", "push_title": null, ...}
   ```
8. Insert a fake reminder with a near-future due time, trigger again, verify decision = "push"

### Step 7 — VAPID setup and end-to-end push test (20 min)

Generate VAPID keys if not done:
```bash
docker compose exec backend python -c "
from py_vapid import Vapid
v = Vapid()
v.generate_keys()
import base64, json
priv = base64.urlsafe_b64encode(v.private_key.private_bytes(
    __import__('cryptography.hazmat.primitives.serialization', fromlist=['Encoding','PrivateFormat','NoEncryption']).Encoding.Raw,
    __import__('cryptography.hazmat.primitives.serialization', fromlist=['Encoding','PrivateFormat','NoEncryption']).PrivateFormat.Raw,
    __import__('cryptography.hazmat.primitives.serialization', fromlist=['Encoding','PrivateFormat','NoEncryption']).NoEncryption(),
)).decode()
pub = base64.urlsafe_b64encode(v.public_key.public_bytes(
    __import__('cryptography.hazmat.primitives.serialization', fromlist=['Encoding','PublicFormat']).Encoding.Raw,
    __import__('cryptography.hazmat.primitives.serialization', fromlist=['Encoding','PublicFormat']).PublicFormat.Raw,
)).decode()
print('VAPID_PRIVATE_KEY=' + priv)
print('VAPID_PUBLIC_KEY=' + pub)
"
```

Paste output into `.env`, restart, then:
1. Open `http://localhost:8080` in mobile Chrome
2. Go to Settings → Enable Push Notifications → Allow
3. `curl -X POST http://localhost:8080/api/debug/push -H "Content-Type: application/json" -d '{"title":"Hello","body":"Push works!"}'`
4. Phone should receive notification

### Step 8 — Full pipeline smoke test

```bash
# 1. DB health
curl http://localhost:8080/api/debug/db

# 2. SSE streaming
curl -N http://localhost:8080/api/debug/sse

# 3. Agent loop
curl -X POST http://localhost:8080/api/debug/agent \
  -H "Content-Type: application/json" \
  -d '{"provider_id":"openai","model":"gpt-4o-mini"}'

# 4. Push
curl -X POST http://localhost:8080/api/debug/push \
  -H "Content-Type: application/json" \
  -d '{"title":"Smoke test","body":"All systems go"}'

# 5. Standby agent decision
curl -X POST http://localhost:8080/api/debug/standby

# 6. Scheduler jobs
curl http://localhost:8080/api/debug/scheduler

# 7. Chaoxing status
curl http://localhost:8080/api/debug/chaoxing

# 8. Real chat stream (requires API key)
CONV=$(curl -s -X POST http://localhost:8080/api/conversations \
  -H "Content-Type: application/json" \
  -d '{"title":"Test","provider_id":"openai","model":"gpt-4o-mini"}' | python3 -c "import sys,json;print(json.load(sys.stdin)['id'])")
curl -N -X POST http://localhost:8080/api/conversations/$CONV/chat \
  -H "Content-Type: application/json" \
  -d '{"message":"Hello, say hi back"}'
```

All 8 should return non-error responses.

---

## 6. Known Gaps (Not In This Phase)

These exist but are deliberately deferred:

| Gap | File | Notes |
|---|---|---|
| `memory_agent._extract_memory_entries` | `memory_agent.py` | Needs extraction prompt ported from Swift |
| Chaoxing real HTTP endpoints | `chaoxing_service.py` | Reverse-engineer from Swift `ChaoxingService.swift` |
| Multi-agent mode | `chat.py` | `agent_mode == "multiAgent"` falls through to direct stream |
| Context window compression | `chat.py` | `buildCompressedChatPromptMessages` not ported |
| Frontend push registration flow | `PushSettings.jsx` | UI exists, needs wiring to `usePush.js` |

---

## 7. Files Changed Summary

| File | Change |
|---|---|
| `backend/app/database.py` | Full rewrite — context manager pattern |
| `backend/app/config.py` | Add `debug`, `standby_*` fields |
| `backend/app/.env` / `.env.example` | Add `DEBUG`, `STANDBY_*` vars |
| `backend/app/routers/debug.py` | **New** — all debug endpoints |
| `backend/app/tasks/standby_agent.py` | **New** — LLM standby decision maker |
| `backend/app/tasks/scheduler.py` | Add standby job |
| `backend/app/routers/chat.py` | Add push tool + fix `get_db` → `db_conn` |
| `backend/app/services/schedule_agent.py` | Add push tool + fix `get_db` → `db_conn` |
| `backend/app/services/agent_service.py` | Update `_tool_keywords` |
| `backend/app/main.py` | Mount debug router conditionally |
| All other routers/services | Replace `get_db()` with `async with db_conn()` |
