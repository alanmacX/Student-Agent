# ChatBot Web — Detailed Implementation Specification

> **Audience**: A coding agent implementing this project from scratch.
> **Source**: Port of a macOS SwiftUI chatbot app. Understand the original Swift logic
> before writing any Python — every section below references the original file.
> **Key constraint**: Single-user deployment (no auth system). Docker Compose on a Linux VPS.
> **Local testing first**: Run `docker compose up` locally before any server deployment.

---

## ⚠️ KNOWN BUGS IN THE SWIFT SOURCE — FIX THESE IN THE PYTHON PORT

The original macOS app has real bugs. Do **not** replicate them.

### Bug 1 — Anthropic loses dynamic context (CRITICAL)
**File**: `ScheduleHarness.buildMessages()` line 207 + `anthropicAgentComplete()` line 270  
**Problem**: `buildMessages()` appends dynamic context (current time, cached reminders,
course schedule) as a second `AgentMsg(role: .system, ...)` at the end of the array.
`anthropicAgentComplete()` only reads `messages.first { $0.role == .system }`.
**Result**: The entire dynamic context — current time, timezone, reminders, Chaoxing
status — is silently dropped for every Anthropic API call. The agent operates without
knowing the current date for Anthropic providers.  
**Fix**: Merge ALL system messages into one string before calling any provider API.
Concatenate with `\n\n` separator. Never send multiple `.system` role messages.

```python
def merge_system_messages(messages: list[AgentMsg]) -> list[AgentMsg]:
    """Collect all system messages, merge into one, prepend to non-system messages."""
    system_parts = [m.content for m in messages if m.role == "system" and m.content]
    non_system = [m for m in messages if m.role != "system"]
    if not system_parts:
        return non_system
    merged = AgentMsg(role="system", content="\n\n".join(system_parts))
    return [merged] + non_system
```
Call `merge_system_messages()` inside `agent_complete()` before dispatching to any provider.

### Bug 2 — `trimIntraTurnContext` corrupts conversation history (CRITICAL)
**File**: `ScheduleHarness.trimIntraTurnContext()` lines 355–360  
**Problem**: The function splits messages into `anchors` (role==system or user) and
`toolRound` (role==assistant or tool), then keeps all anchors + last N tool pairs.
When the conversation has multiple user turns (e.g., 5 back-and-forth exchanges),
ALL historical user messages are kept as "anchors", but the corresponding assistant
replies are dropped by the suffix trim. The conversation becomes incoherent.  
**The real intent**: Trim intra-turn tool pairs (within a single agent iteration),
NOT the multi-turn conversation history. The 20-message window in `buildMessages()`
already handles conversation history.  
**Fix**: Track intra-turn messages separately from conversation history. The agentic
loop should maintain:
  - `history_messages`: the conversation context (from `buildMessages`), never trimmed mid-loop
  - `intra_turn_pairs`: assistant+tool pairs appended during the current agentic iteration

```python
async def run_agentic_loop(initial_messages, tools, tool_executor, ...):
    history = merge_system_messages(initial_messages)  # stable, never trimmed
    intra_turn = []   # grows within this agent turn, trimmed each iteration

    for _ in range(max_iterations):
        # Trim only intra-turn pairs, never history
        trimmed_intra = _trim_intra_turn_pairs(intra_turn, max_pairs=6)
        current_messages = history + trimmed_intra

        response = await agent_complete(current_messages, tools, ...)
        if not response.tool_calls:
            break

        # Append assistant + tool results to intra_turn, NOT history
        intra_turn.append(AgentMsg(role="assistant", ...))
        for result in tool_results:
            intra_turn.append(AgentMsg(role="tool", ...))

def _trim_intra_turn_pairs(pairs: list[AgentMsg], max_pairs: int) -> list[AgentMsg]:
    """Trim assistant+tool pairs to last max_pairs. Pairs always come in 2s."""
    pair_size = 2
    max_msgs = max_pairs * pair_size
    return pairs[-max_msgs:] if len(pairs) > max_msgs else pairs
```

### Bug 3 — Chat sub-agent tools run sequentially (PERFORMANCE)
**File**: `ChatViewModel+Engine.swift` `runChatSubAgent()` lines 398–423  
**Problem**: Sub-agent tool calls iterate with `for call in calls { await runChatTool(call) }`.
Main agent uses `withTaskGroup` for parallel execution. The sub-agent is 2–5× slower.  
**Fix**: In Python, always use `asyncio.gather(*[executor(tc) for tc in tool_calls])`.

### Bug 4 — Main chat loop has no `trimIntraTurnContext` (MEMORY LEAK)
**File**: `ChatViewModel+Engine.swift` `completeChatWithSkillTools()`  
**Problem**: `agentMessages` grows unboundedly as each iteration appends assistant+tool
messages. The Schedule Agent harness calls `trimIntraTurnContext` each iteration; the chat
agent does not. After 8 rounds with 5 parallel tools each, `agentMessages` can have 90+
messages.  
**Fix**: Apply the same `_trim_intra_turn_pairs()` fix in the chat agent loop (§6 below).

### Bug 5 — `isItemSemanticallyExpired` regex ignores date context (LOGIC ERROR)
**File**: `ChatViewModel+Schedule.swift` lines 518–531  
**Problem**: Regex extracts times like `12:00` from memory text, constructs today's
date at that time, and marks the item expired if `target < now - 45min`. A memory
saying "**明天** 12:00 截止" extracts 12:00, checks if *today's* 12:00 passed → marks
it expired even though the deadline is tomorrow.  
**Fix**: In Python, check if the text contains a date context word before marking expired:

```python
def is_semantically_expired(item: dict, now: datetime) -> bool:
    text = f"{item['title']} {item['summary']} {item.get('action_hint', '')}"
    # Skip expiry check if text mentions future date words
    future_markers = ["明天", "后天", "下周", "下个", "明日"]
    if any(m in text for m in future_markers):
        return False
    # ... rest of regex logic
```

---

---

## 0. What This App Does (Read First)

The original macOS app has two core UIs:

1. **Chat** — multi-conversation chat with multiple AI providers (OpenAI, Anthropic, Gemini,
   custom OpenAI-compatible, Xiaomi MiMo). Supports tool-use (web fetch, PDF, skills),
   multi-agent mode (multiple providers deliberate in parallel), and deep thinking (reasoning).

2. **Schedule Agent** — a dedicated agentic chat that reads 超星学习通 (Chaoxing, a Chinese
   university LMS) for assignments, messages, and course schedules. The agent can display
   structured "schedule payloads" (course lists, assignment cards, reminder items) as rich UI.
   In the web version, Calendar/Reminders integration is **skipped**.

3. **Push Notifications** — the web version adds mobile push: the APScheduler background
   daemon checks Chaoxing data every 5 minutes and sends Web Push notifications for
   upcoming deadlines, important messages, and summary digests.

---

## 1. Project Directory Structure

```
chatbot-web/
├── backend/
│   ├── app/
│   │   ├── __init__.py
│   │   ├── main.py                   # FastAPI app, lifespan, middleware
│   │   ├── database.py               # aiosqlite connection pool, migrations
│   │   ├── config.py                 # Settings from env vars (pydantic-settings)
│   │   ├── models.py                 # Pydantic request/response models
│   │   │
│   │   ├── services/
│   │   │   ├── api_service.py        # AI streaming: OpenAI / Anthropic / Gemini
│   │   │   ├── agent_service.py      # Agentic loop (tool-use orchestration)
│   │   │   ├── chaoxing_service.py   # Chaoxing HTTP client (login, assignments, messages)
│   │   │   ├── memory_agent.py       # ChaoxingMemoryAgent — AI-driven memory extraction
│   │   │   ├── schedule_agent.py     # Schedule Agent orchestrator
│   │   │   ├── push_service.py       # Web Push via pywebpush
│   │   │   └── companion_engine.py   # Rule-based state machine for notification text
│   │   │
│   │   ├── routers/
│   │   │   ├── conversations.py      # /api/conversations CRUD
│   │   │   ├── chat.py               # /api/conversations/{id}/chat SSE stream
│   │   │   ├── schedule.py           # /api/schedule/* (agent, sidebar, messages)
│   │   │   ├── chaoxing.py           # /api/chaoxing/* (login, sync, memory)
│   │   │   ├── providers.py          # /api/providers (list, models, reachability, balance)
│   │   │   ├── settings.py           # /api/settings (get/put)
│   │   │   └── push.py               # /api/push/* (subscribe, test, vapid-key)
│   │   │
│   │   └── tasks/
│   │       ├── scheduler.py          # APScheduler setup and job definitions
│   │       ├── chaoxing_sync.py      # Periodic Chaoxing probe + memory maintenance
│   │       └── notification_sender.py # Deadline/summary push logic
│   │
│   ├── requirements.txt
│   ├── Dockerfile
│   └── .env.example
│
├── frontend/
│   ├── public/
│   │   ├── manifest.json             # PWA manifest
│   │   └── sw.js                     # Service Worker (push + offline)
│   ├── src/
│   │   ├── main.jsx
│   │   ├── App.jsx                   # Root: TabView (Chat | Schedule | Settings)
│   │   ├── api/
│   │   │   ├── client.js             # fetch wrapper with base URL
│   │   │   ├── conversations.js
│   │   │   ├── schedule.js
│   │   │   ├── chaoxing.js
│   │   │   ├── providers.js
│   │   │   └── push.js
│   │   ├── hooks/
│   │   │   ├── useSSEStream.js       # Generic SSE hook for streaming chat
│   │   │   ├── usePush.js            # Register/unregister Web Push subscription
│   │   │   └── useConversations.js
│   │   ├── components/
│   │   │   ├── layout/
│   │   │   │   ├── Sidebar.jsx       # Conversation list (left panel)
│   │   │   │   └── TabBar.jsx        # Chat | Schedule | Settings tabs
│   │   │   ├── chat/
│   │   │   │   ├── ChatView.jsx      # Main chat area
│   │   │   │   ├── MessageBubble.jsx # Markdown-rendering bubble with copy button
│   │   │   │   ├── ChatInput.jsx     # Textarea + send button + stop button
│   │   │   │   ├── ModelPicker.jsx   # Provider + model selector
│   │   │   │   └── UsageBadge.jsx    # Token count + estimated cost
│   │   │   ├── schedule/
│   │   │   │   ├── ScheduleView.jsx  # Schedule Agent chat + sidebar
│   │   │   │   ├── ScheduleSidebar.jsx # Assignments, courses, message insights
│   │   │   │   ├── SchedulePayload.jsx # Renders structured schedule cards
│   │   │   │   └── ChaoxingStatus.jsx  # Login status + sync indicator
│   │   │   └── settings/
│   │   │       ├── SettingsView.jsx
│   │   │       ├── ProviderSettings.jsx
│   │   │       └── PushSettings.jsx   # Enable/disable push + test button
│   │   └── stores/
│   │       ├── useAppStore.js        # Zustand global store
│   │       └── useChaoxingStore.js
│   ├── index.html
│   ├── vite.config.js
│   ├── tailwind.config.js
│   └── package.json
│
├── nginx.conf
├── docker-compose.yml
└── .env
```

---

## 2. Environment Variables (`.env`)

```bash
# AI API Keys
OPENAI_API_KEY=sk-...
ANTHROPIC_API_KEY=sk-ant-...
GEMINI_API_KEY=AIza...
MIMO_API_KEY=...

# VAPID keys for Web Push — generate once with:
#   python -c "from pywebpush import Vapid; v=Vapid(); v.generate_keys(); print(v.private_key, v.public_key)"
VAPID_PRIVATE_KEY=...
VAPID_PUBLIC_KEY=...
VAPID_MAILTO=mailto:you@example.com

# DB path (inside container)
DATABASE_PATH=/data/chatbot.db

# Optional: override default Chaoxing sync interval (seconds)
CHAOXING_SYNC_INTERVAL=300
CHAOXING_MEMORY_INTERVAL=1800
```

---

## 3. Database Schema (`database.py`)

Run migrations at startup inside the FastAPI lifespan. Use `aiosqlite` for all async access.

```sql
-- Key-value store for all settings (replaces UserDefaults)
CREATE TABLE IF NOT EXISTS settings (
    key   TEXT PRIMARY KEY,
    value TEXT             -- JSON-encoded values
);

-- Conversations
CREATE TABLE IF NOT EXISTS conversations (
    id                              TEXT PRIMARY KEY,
    title                           TEXT NOT NULL DEFAULT 'New Chat',
    provider_id                     TEXT NOT NULL DEFAULT 'openai',
    model                           TEXT NOT NULL DEFAULT 'gpt-4o',
    agent_mode                      TEXT NOT NULL DEFAULT 'normal',  -- normal|multiAgent|subAgent
    system_prompt                   TEXT NOT NULL DEFAULT '',
    context_summary                 TEXT,
    context_summary_message_count   INTEGER,
    context_summary_updated_at      TEXT,
    created_at                      TEXT NOT NULL,
    updated_at                      TEXT NOT NULL
);

-- Chat messages
CREATE TABLE IF NOT EXISTS messages (
    id                   TEXT PRIMARY KEY,
    conversation_id      TEXT NOT NULL REFERENCES conversations(id) ON DELETE CASCADE,
    role                 TEXT NOT NULL,   -- user|assistant|system
    content              TEXT NOT NULL DEFAULT '',
    reasoning_content    TEXT,
    usage_json           TEXT,            -- JSON: UsageStats
    schedule_payload_json TEXT,
    chat_list_payload_json TEXT,
    timestamp            TEXT NOT NULL,
    position             INTEGER NOT NULL  -- ordering within conversation
);
CREATE INDEX IF NOT EXISTS idx_messages_conv ON messages(conversation_id, position);

-- Schedule Agent conversation (separate from chat)
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

-- Chaoxing persistent session
CREATE TABLE IF NOT EXISTS chaoxing_session (
    id          INTEGER PRIMARY KEY CHECK (id = 1),
    cookies_json TEXT,           -- serialized httpx cookies
    uid         TEXT,
    username    TEXT,
    phone       TEXT,
    logged_in_at TEXT
);

-- Chaoxing memory store (replaces ChaoxingMemoryStore file)
-- One row per memory entry (mirrors the Swift ChaoxingMemoryEntry model)
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
    importance      TEXT NOT NULL DEFAULT 'medium',  -- low|medium|high
    sent_at         TEXT NOT NULL,
    extracted_at    TEXT NOT NULL,
    expires_at      TEXT,   -- optional explicit expiry (ISO8601); NULL = no expiry
    archived_at     TEXT,
    source_text_preview TEXT
);

-- Chaoxing conversation probe signatures (lightweight change detection)
-- Port of ChaoxingService.chaoxingProbeSignatures in Swift.
-- Key: conversation_id, Value: hash of (last_message_id + message_count)
-- Used by fetch_conversation_probes() to skip full message fetch if unchanged.
CREATE TABLE IF NOT EXISTS chaoxing_probe_signatures (
    conversation_id TEXT PRIMARY KEY,
    signature       TEXT NOT NULL,   -- e.g. "{lastMsgId}:{count}"
    updated_at      TEXT NOT NULL
);

-- Chaoxing sync state (replaces in-memory Swift state)
-- Tracks what has been processed to avoid reprocessing on restart.
CREATE TABLE IF NOT EXISTS chaoxing_sync_state (
    key   TEXT PRIMARY KEY,
    value TEXT NOT NULL   -- JSON-encoded; keys: processedSourceIDs, processedFingerprints, consecutiveNoChangeCount
);

-- Chaoxing processed message IDs (dedup)
CREATE TABLE IF NOT EXISTS chaoxing_processed_ids (
    message_id  TEXT PRIMARY KEY,
    processed_at TEXT NOT NULL
);

-- Custom providers
CREATE TABLE IF NOT EXISTS custom_providers (
    id          TEXT PRIMARY KEY,
    data_json   TEXT NOT NULL    -- JSON: Provider object
);

-- Web Push subscriptions
CREATE TABLE IF NOT EXISTS push_subscriptions (
    id          INTEGER PRIMARY KEY AUTOINCREMENT,
    endpoint    TEXT UNIQUE NOT NULL,
    p256dh      TEXT NOT NULL,
    auth        TEXT NOT NULL,
    user_agent  TEXT,
    created_at  TEXT NOT NULL
);

-- Notification log (avoid sending duplicate notifications)
CREATE TABLE IF NOT EXISTS notification_log (
    id          INTEGER PRIMARY KEY AUTOINCREMENT,
    item_id     TEXT NOT NULL,   -- assignment id / event id / etc.
    notif_type  TEXT NOT NULL,   -- deadline_1h|deadline_24h|memory_high|daily_summary
    sent_at     TEXT NOT NULL,
    UNIQUE(item_id, notif_type)
);
```

---

## 4. Backend — `config.py`

```python
from pydantic_settings import BaseSettings

class Settings(BaseSettings):
    openai_api_key: str = ""
    anthropic_api_key: str = ""
    gemini_api_key: str = ""
    mimo_api_key: str = ""

    vapid_private_key: str = ""
    vapid_public_key: str = ""
    vapid_mailto: str = "mailto:admin@example.com"

    database_path: str = "/data/chatbot.db"
    chaoxing_sync_interval: int = 300    # seconds
    chaoxing_memory_interval: int = 1800

    class Config:
        env_file = ".env"

settings = Settings()
```

---

## 5. Backend — `services/api_service.py`

This is the direct port of `APIService.swift`. Implement three async generator functions —
one per provider — that yield `StreamEvent` dataclass instances.

```python
from dataclasses import dataclass, field
from typing import AsyncGenerator, Optional
import httpx, json

@dataclass
class UsageStats:
    input_tokens: int = 0
    output_tokens: int = 0
    cache_hit_tokens: int = 0
    cache_miss_tokens: int = 0
    reasoning_tokens: int = 0
    estimated_cost_usd: Optional[float] = None

@dataclass
class StreamEvent:
    type: str          # "text" | "reasoning" | "usage"
    content: str = ""
    usage: Optional[UsageStats] = None

# Shared httpx client — MUST be a module-level singleton, not created per-request.
# Initialize in FastAPI lifespan and inject as app.state.http_client.
# This is the key 24/7 optimization: connection pooling.
_http_client: Optional[httpx.AsyncClient] = None

def get_http_client() -> httpx.AsyncClient:
    return _http_client

async def init_http_client():
    global _http_client
    _http_client = httpx.AsyncClient(
        timeout=httpx.Timeout(120.0, connect=10.0),
        limits=httpx.Limits(max_connections=20, max_keepalive_connections=10),
    )

async def close_http_client():
    if _http_client:
        await _http_client.aclose()
```

### 5a. Design note: agent call timeouts

The Swift source (`AgentService.swift`) calls `URLSession.shared.data(for:)` with no
timeout configured. For a 24/7 server this is a problem — a hung API call will block an
async task indefinitely, eventually exhausting the event loop.

In the Python port, the shared `httpx.AsyncClient` already has `timeout=httpx.Timeout(120.0, connect=10.0)`.
Ensure `_anthropic_agent_complete()` and `_openai_agent_complete()` in `agent_service.py`
also use this client (not a fresh one) so the 120s ceiling applies to all agent calls.
If a provider is known to be slow (e.g., DeepSeek R1 reasoning), increase the read timeout
for that client instance only.

### 5b. `economicalModel()` algorithm

Port of `ChatViewModel+Providers.swift economicalModel()`.
Used by the background scheduler to pick the cheapest model for memory extraction.

```python
KNOWN_PRICING: dict[str, tuple[float, float]] = {
    # model_id: (input_per_million_USD, output_per_million_USD)
    "gpt-4o-mini":          (0.15,  0.60),
    "gpt-4o":               (2.50, 10.00),
    "claude-haiku-3-5":     (0.80,  4.00),
    "claude-sonnet-3-7":    (3.00, 15.00),
    "gemini-1.5-flash":     (0.075, 0.30),
    "gemini-1.5-pro":       (3.50,  7.00),
    # Add more from Models.swift knownPricing dict
}

def economical_model(provider_id: str) -> str:
    """
    Returns the model ID with the lowest combined cost (input + output per million tokens)
    for the given provider. Port of economicalModel() in ChatViewModel+Providers.swift.
    """
    candidates = {
        mid: inp + out
        for mid, (inp, out) in KNOWN_PRICING.items()
        if mid.startswith(_provider_model_prefix(provider_id))
    }
    if not candidates:
        return _default_model(provider_id)
    return min(candidates, key=candidates.get)

def _provider_model_prefix(provider_id: str) -> str:
    return {
        "openai": "gpt-",
        "anthropic": "claude-",
        "gemini": "gemini-",
    }.get(provider_id, "")
```

Port the full `knownPricing` dict from `Models.swift` to keep cost estimates accurate.

### 5c. `filterRelevantTools` optimization

Port of `ChatViewModel+Engine.swift filterRelevantTools()`.
The chat agent sends ALL registered skill tools in every API call. When the user message
clearly doesn't need certain tools (e.g., a pure conversation question has no need for
`fetch_url`, `search_web`, `read_pdf`), filter them out before calling `run_agentic_loop`.

This matters for cost (tools inflate the prompt) and for model behavior (too many tools
confuse some models). Implement a simple keyword heuristic:

```python
def filter_relevant_tools(
    tools: list[ToolDefinition],
    user_message: str,
    always_include: set[str] = frozenset(),
) -> list[ToolDefinition]:
    """
    Heuristic: keep tools whose name or description keywords appear in the message,
    plus always_include set. Fall back to all tools if <2 match.
    Port of filterRelevantTools() in ChatViewModel+Engine.swift.
    """
    msg_lower = user_message.lower()
    relevant = [
        t for t in tools
        if t.name in always_include
        or any(kw in msg_lower for kw in _tool_keywords(t.name))
    ]
    return relevant if len(relevant) >= 2 else tools

def _tool_keywords(tool_name: str) -> list[str]:
    return {
        "fetch_url": ["http", "url", "网页", "链接", "网站"],
        "search_web": ["搜索", "查找", "找", "search"],
        "read_pdf": ["pdf", "文件", "文档"],
        "get_schedule_context": ["课", "作业", "日程", "提醒"],
    }.get(tool_name, [tool_name])
```

---

### 5e. OpenAI / OpenAI-compatible streaming

```python
async def stream_openai(
    messages: list[dict],
    model: str,
    api_key: str,
    base_url: str,
    thinking_enabled: bool = False,
) -> AsyncGenerator[StreamEvent, None]:
    """
    Port of OpenAIService.stream() in APIService.swift.
    Handles standard OpenAI SSE format including DeepSeek reasoning_content.
    """
    client = get_http_client()
    url = _endpoint_url(base_url, "/v1/chat/completions")
    headers = _openai_auth_headers(api_key, base_url)
    headers["Content-Type"] = "application/json"

    body = {
        "model": model,
        "messages": messages,
        "stream": True,
        "stream_options": {"include_usage": True},
    }
    if thinking_enabled and _should_send_deepseek_thinking(model, base_url):
        body["thinking"] = {"type": "enabled"}

    async with client.stream("POST", url, headers=headers, json=body) as response:
        _check_http(response)
        async for line in response.aiter_lines():
            if not line.startswith("data: "):
                continue
            payload = line[6:]
            if payload == "[DONE]":
                break
            try:
                data = json.loads(payload)
            except json.JSONDecodeError:
                continue

            # Text / reasoning chunks
            choices = data.get("choices", [])
            if choices:
                delta = choices[0].get("delta", {})
                if reasoning := delta.get("reasoning_content", ""):
                    yield StreamEvent(type="reasoning", content=reasoning)
                if text := delta.get("content", ""):
                    yield StreamEvent(type="text", content=text)

            # Usage (final chunk)
            if usage_raw := data.get("usage"):
                yield StreamEvent(type="usage", usage=_parse_openai_usage(usage_raw))


def _parse_openai_usage(u: dict) -> UsageStats:
    stats = UsageStats(
        input_tokens=u.get("prompt_tokens", 0),
        output_tokens=u.get("completion_tokens", 0),
    )
    # OpenAI nests cache info in prompt_tokens_details
    details = u.get("prompt_tokens_details", {})
    stats.cache_hit_tokens = details.get("cached_tokens", 0)
    # DeepSeek-style
    stats.cache_hit_tokens = stats.cache_hit_tokens or u.get("prompt_cache_hit_tokens", 0)
    stats.cache_miss_tokens = u.get("prompt_cache_miss_tokens", 0)
    cd = u.get("completion_tokens_details", {})
    stats.reasoning_tokens = cd.get("reasoning_tokens", 0)
    return stats


def _endpoint_url(base_url: str, path: str) -> str:
    base = base_url.rstrip("/")
    # De-duplicate /v1 prefix (port of endpointURL() in Swift)
    if base.lower().endswith("/v1") and path.startswith("/v1/"):
        path = path[3:]
    return base + path


def _openai_auth_headers(api_key: str, base_url: str) -> dict:
    key = _normalize_api_key(api_key)
    if not key:
        return {}
    if "xiaomimimo.com" in base_url.lower():
        return {"api-key": key}
    return {"Authorization": f"Bearer {key}"}


def _normalize_api_key(key: str) -> str:
    """Port of normalizedOpenAICompatibleAPIKey() in Swift."""
    key = key.strip()
    if "\n" in key:
        key = key.split("\n")[0].strip()
    prefixes = ["authorization:", "api-key:", "bearer "]
    changed = True
    while changed:
        changed = False
        lower = key.lower()
        for prefix in prefixes:
            if lower.startswith(prefix):
                key = key[len(prefix):].strip()
                changed = True
    return key


def _should_send_deepseek_thinking(model: str, base_url: str) -> bool:
    return "deepseek" in base_url.lower() and model.lower() == "deepseek-chat"


def _check_http(response: httpx.Response):
    if response.status_code >= 400:
        raise httpx.HTTPStatusError(
            f"HTTP {response.status_code}",
            request=response.request,
            response=response,
        )
```

### 5f. Anthropic streaming

```python
async def stream_anthropic(
    messages: list[dict],
    model: str,
    api_key: str,
    base_url: str = "https://api.anthropic.com",
    thinking_enabled: bool = False,
) -> AsyncGenerator[StreamEvent, None]:
    """Port of AnthropicService.stream() in APIService.swift."""
    client = get_http_client()
    # Separate system messages (Anthropic API requires system at top level)
    system_msg = next((m["content"] for m in messages if m["role"] == "system"), None)
    non_sys = [m for m in messages if m["role"] != "system"]

    body = {
        "model": model,
        "max_tokens": 8096,
        "stream": True,
        "messages": non_sys,
    }
    if system_msg:
        body["system"] = system_msg

    headers = {
        "x-api-key": api_key,
        "anthropic-version": "2023-06-01",
        "Content-Type": "application/json",
    }

    usage = UsageStats()
    async with client.stream("POST", f"{base_url}/v1/messages", headers=headers, json=body) as resp:
        _check_http(resp)
        async for line in resp.aiter_lines():
            if not line.startswith("data: "):
                continue
            try:
                data = json.loads(line[6:])
            except json.JSONDecodeError:
                continue

            match data.get("type"):
                case "message_start":
                    u = data.get("message", {}).get("usage", {})
                    usage.input_tokens = u.get("input_tokens", 0)
                    usage.cache_hit_tokens = u.get("cache_read_input_tokens", 0)
                    usage.cache_miss_tokens = usage.input_tokens - usage.cache_hit_tokens
                case "content_block_delta":
                    delta = data.get("delta", {})
                    if text := delta.get("text", ""):
                        yield StreamEvent(type="text", content=text)
                case "message_delta":
                    u = data.get("usage", {})
                    usage.output_tokens = u.get("output_tokens", 0)
                case "message_stop":
                    yield StreamEvent(type="usage", usage=usage)
```

### 5g. Gemini streaming

```python
async def stream_gemini(
    messages: list[dict],
    model: str,
    api_key: str,
    base_url: str = "https://generativelanguage.googleapis.com",
) -> AsyncGenerator[StreamEvent, None]:
    """Port of GeminiService.stream() in APIService.swift."""
    client = get_http_client()
    url = f"{base_url}/v1beta/models/{model}:streamGenerateContent"
    params = {"key": api_key, "alt": "sse"}

    system_msg = next((m["content"] for m in messages if m["role"] == "system"), None)
    contents = [
        {"role": "user" if m["role"] == "user" else "model",
         "parts": [{"text": m["content"]}]}
        for m in messages if m["role"] != "system"
    ]
    body = {"contents": contents}
    if system_msg:
        body["systemInstruction"] = {"parts": [{"text": system_msg}]}

    last_usage: Optional[UsageStats] = None
    async with client.stream("POST", url, params=params, json=body) as resp:
        _check_http(resp)
        async for line in resp.aiter_lines():
            if not line.startswith("data: "):
                continue
            try:
                data = json.loads(line[6:])
            except json.JSONDecodeError:
                continue
            candidates = data.get("candidates", [])
            if candidates:
                parts = candidates[0].get("content", {}).get("parts", [])
                for part in parts:
                    if text := part.get("text", ""):
                        yield StreamEvent(type="text", content=text)
            if um := data.get("usageMetadata"):
                last_usage = UsageStats(
                    input_tokens=um.get("promptTokenCount", 0),
                    output_tokens=um.get("candidatesTokenCount", 0),
                    cache_hit_tokens=um.get("cachedContentTokenCount", 0),
                )
    if last_usage:
        yield StreamEvent(type="usage", usage=last_usage)


def make_service(api_type: str):
    """Factory — port of makeService() in Swift."""
    return {
        "openAI": stream_openai,
        "openAICompatible": stream_openai,
        "xiaomiMimo": stream_openai,   # MiMo uses OpenAI-compatible non-stream (handle separately)
        "anthropic": stream_anthropic,
        "gemini": stream_gemini,
    }.get(api_type, stream_openai)
```

---

## 6. Backend — `services/agent_service.py`

Port of `AgentService.swift`. This implements the tool-use agentic loop used by both
the Chat (with skills) and the Schedule Agent.

```python
import asyncio
import json
from dataclasses import dataclass, field
from typing import Any, Optional, AsyncGenerator
import httpx

@dataclass
class AgentMsg:
    role: str   # "system" | "user" | "assistant"
    content: str

@dataclass
class ToolDefinition:
    name: str
    description: str
    input_schema: dict   # JSON Schema object

@dataclass
class ToolCall:
    id: str
    name: str
    arguments: dict

@dataclass
class AgentResponse:
    text: Optional[str]
    tool_calls: list[ToolCall]
    usage: Optional["UsageStats"]
    stop_reason: str   # "end_turn" | "tool_use" | "max_tokens"


async def agent_complete(
    messages: list[AgentMsg],
    tools: list[ToolDefinition],
    provider: dict,
    model: str,
    api_key: str,
    thinking_budget: int = 0,
) -> AgentResponse:
    """
    Single non-streaming LLM call with tool definitions.
    Used internally by the agentic loop.
    Port of agentComplete() in AgentService.swift.
    """
    api_type = provider["api_type"]
    base_url = provider["base_url"]

    if api_type == "anthropic":
        return await _anthropic_agent_complete(messages, tools, model, api_key, base_url, thinking_budget)
    else:
        return await _openai_agent_complete(messages, tools, model, api_key, base_url)


async def _anthropic_agent_complete(messages, tools, model, api_key, base_url, thinking_budget) -> AgentResponse:
    from .api_service import get_http_client
    client = get_http_client()

    system_msg = next((m.content for m in messages if m.role == "system"), None)
    non_sys = [{"role": m.role, "content": m.content} for m in messages if m.role != "system"]

    body: dict[str, Any] = {
        "model": model,
        "max_tokens": 8096,
        "messages": non_sys,
        "tools": [
            {"name": t.name, "description": t.description, "input_schema": t.input_schema}
            for t in tools
        ],
    }
    if system_msg:
        body["system"] = system_msg
    if thinking_budget > 0:
        body["thinking"] = {"type": "enabled", "budget_tokens": thinking_budget}

    headers = {"x-api-key": api_key, "anthropic-version": "2023-06-01", "Content-Type": "application/json"}
    resp = await client.post(f"{base_url}/v1/messages", headers=headers, json=body)
    resp.raise_for_status()
    data = resp.json()

    text = None
    tool_calls = []
    for block in data.get("content", []):
        if block.get("type") == "text":
            text = block["text"]
        elif block.get("type") == "tool_use":
            tool_calls.append(ToolCall(
                id=block["id"],
                name=block["name"],
                arguments=block.get("input", {}),
            ))

    from .api_service import UsageStats
    u = data.get("usage", {})
    usage = UsageStats(input_tokens=u.get("input_tokens", 0), output_tokens=u.get("output_tokens", 0))

    return AgentResponse(
        text=text,
        tool_calls=tool_calls,
        usage=usage,
        stop_reason=data.get("stop_reason", "end_turn"),
    )


async def _openai_agent_complete(messages, tools, model, api_key, base_url) -> AgentResponse:
    from .api_service import get_http_client, _endpoint_url, _openai_auth_headers, UsageStats
    client = get_http_client()

    oai_tools = [
        {
            "type": "function",
            "function": {
                "name": t.name,
                "description": t.description,
                "parameters": t.input_schema,
            }
        }
        for t in tools
    ]
    body = {
        "model": model,
        "messages": [{"role": m.role, "content": m.content} for m in messages],
        "tools": oai_tools,
        "tool_choice": "auto",
    }
    headers = _openai_auth_headers(api_key, base_url)
    headers["Content-Type"] = "application/json"

    resp = await client.post(_endpoint_url(base_url, "/v1/chat/completions"), headers=headers, json=body)
    resp.raise_for_status()
    data = resp.json()

    choice = data["choices"][0]
    msg = choice["message"]
    text = msg.get("content")
    tool_calls = []
    for tc in msg.get("tool_calls", []):
        args = json.loads(tc["function"]["arguments"]) if isinstance(tc["function"]["arguments"], str) else tc["function"]["arguments"]
        tool_calls.append(ToolCall(id=tc["id"], name=tc["function"]["name"], arguments=args))

    u = data.get("usage", {})
    usage = UsageStats(input_tokens=u.get("prompt_tokens", 0), output_tokens=u.get("completion_tokens", 0))

    stop_reason = "tool_use" if tool_calls else "end_turn"
    return AgentResponse(text=text, tool_calls=tool_calls, usage=usage, stop_reason=stop_reason)


def merge_system_messages(messages: list[AgentMsg]) -> list[AgentMsg]:
    """
    FIX FOR BUG 1: Merge all system messages into one before any API call.
    The Swift source sends multiple system-role AgentMsg objects; Anthropic only
    reads the first one. Always call this before agent_complete().
    """
    system_parts = [m.content for m in messages if m.role == "system" and m.content]
    non_system = [m for m in messages if m.role != "system"]
    if not system_parts:
        return non_system
    return [AgentMsg(role="system", content="\n\n".join(system_parts))] + non_system


def _trim_intra_turn_pairs(pairs: list[AgentMsg], max_pairs: int = 6) -> list[AgentMsg]:
    """
    FIX FOR BUG 2: Trim only intra-turn tool pairs (assistant+tool messages from
    the CURRENT agent iteration). Never trim the conversation history.
    A "pair" = one assistant msg (with tool_calls) + one or more tool result msgs.
    Since Anthropic/OpenAI alternate assistant↔user(tool_result), pairs come in 2s.
    """
    max_msgs = max_pairs * 2
    return pairs[-max_msgs:] if len(pairs) > max_msgs else pairs


async def run_agentic_loop(
    initial_messages: list[AgentMsg],
    tools: list[ToolDefinition],
    tool_executor,          # async callable: (ToolCall) -> str
    provider: dict,
    model: str,
    api_key: str,
    max_iterations: int = 8,
    thinking_budget: int = 0,
) -> AsyncGenerator[dict, None]:
    """
    Full agentic loop with parallel tool execution.
    Yields SSE-compatible dicts for streaming to the frontend.
    Port of ScheduleHarness.run() in Swift, with Bug 2 and Bug 3 fixed.

    Key behaviors:
    - history_messages: the conversation context from buildMessages(), NEVER trimmed
    - intra_turn: tool pairs from the CURRENT iteration only, trimmed to 6 pairs
    - Tool calls within one turn run in PARALLEL (asyncio.gather) — Bug 3 fix
    - Tool results are truncated to 8,000 chars
    - Max 8 iterations (matches ScheduleHarness maxIterations=8)
    """
    # Separate stable history from intra-turn accumulation (Bug 2 fix)
    history = merge_system_messages(initial_messages)
    intra_turn: list[AgentMsg] = []

    failure_summaries: []
    reached_final = False

    for _ in range(max_iterations):
        # Trim ONLY intra-turn pairs, keep full history
        trimmed_intra = _trim_intra_turn_pairs(intra_turn)
        current_messages = history + trimmed_intra

        response = await agent_complete(current_messages, tools, provider, model, api_key, thinking_budget)

        if response.usage:
            yield {"type": "usage", "usage": _usage_to_dict(response.usage)}

        if response.reasoning:
            yield {"type": "reasoning", "content": response.reasoning}

        if not response.tool_calls:
            final_text = (response.text or "").strip()
            reached_final = True
            if final_text:
                yield {"type": "text", "content": final_text}
            break

        # Parallel tool execution — Bug 3 fix (sub-agent was sequential in Swift)
        yield {"type": "tool_start", "tools": [{"name": tc.name, "id": tc.id} for tc in response.tool_calls]}
        results = await asyncio.gather(*[tool_executor(tc) for tc in response.tool_calls])

        for tc, result in zip(response.tool_calls, results):
            yield {"type": "tool_result", "tool_name": tc.name, "result_preview": result[:200]}
            if result.startswith("错误:"):
                failure_summaries.append(f"{tc.name}: {result[:120]}")

        # Append to intra_turn (NOT history) — Bug 2 fix
        intra_turn.append(AgentMsg(
            role="assistant",
            content=None,
            tool_calls=response.tool_calls,
        ))
        for tc, result in zip(response.tool_calls, results):
            intra_turn.append(AgentMsg(
                role="tool",
                content=_truncate_tool_result(result),
                tool_call_id=tc.id,
                tool_name=tc.name,
            ))

    if not reached_final:
        if failure_summaries:
            yield {"type": "text", "content": _partial_failure_summary(failure_summaries)}
        else:
            yield {"type": "text", "content": "任务未完成：Agent 达到工具调用轮次上限，但没有生成最终回答。"}


def _truncate_tool_result(result: str, max_chars: int = 8000) -> str:
    if len(result) <= max_chars:
        return result
    return result[:max_chars] + f"\n…（内容已截断，共 {len(result)} 字符，仅传递前 {max_chars} 字符）"


def _partial_failure_summary(failures: list[str]) -> str:
    unique = list(dict.fromkeys(failures))[:4]
    lines = "\n".join(f"- {f}" for f in unique)
    return f"任务没有完全完成：有 {len(failures)} 个工具失败。\n{lines}"


def _usage_to_dict(u) -> dict:
    return {
        "input_tokens": u.input_tokens,
        "output_tokens": u.output_tokens,
        "cache_hit_tokens": u.cache_hit_tokens,
        "cache_miss_tokens": u.cache_miss_tokens,
        "reasoning_tokens": u.reasoning_tokens,
    }
```

---

## 7. Backend — `services/chaoxing_service.py`

Port of `ChaoxingService.swift`. Chaoxing uses a proprietary auth flow.
The session cookies must be persisted to SQLite after login.

```python
"""
Chaoxing (超星学习通) HTTP client.
Port of ChaoxingService.swift.

Auth flow:
1. POST phone number → receive OTP
2. POST phone + OTP → receive cookies (uid, _d, vc3, ...)
3. All subsequent requests use these cookies.

Key endpoints (reverse-engineered; may change):
- Login:       https://passport2.chaoxing.com/login (form post)
- OTP login:   https://passport2.chaoxing.com/mlogin/phoneLoginV2 (phone)
- Courses:     https://mooc1-api.chaoxing.com/mycourse/studentcourse (paginated)
- Assignments: https://mooc1-api.chaoxing.com/work/doHomeWorkList
- Messages:    https://im.chaoxing.com/webim/ME (paginated conversations)
               https://im.chaoxing.com/webim/GetMessages (per-conversation)

IMPORTANT: Mirror the exact session probing logic from ChaoxingService.swift.
The probe uses a lightweight endpoint to detect cookie expiry without a full fetch.
On expiry → set is_logged_in = False, emit status event.
"""

import httpx
import json
from datetime import datetime
from typing import Optional
import aiosqlite

CHAOXING_UA = "Mozilla/5.0 (iPhone; CPU iPhone OS 17_0 like Mac OS X) AppleWebKit/605.1.15"

class ChaoxingService:
    """Singleton. Initialize once in FastAPI lifespan."""

    def __init__(self, db_path: str):
        self.db_path = db_path
        self._client: Optional[httpx.AsyncClient] = None
        self.is_logged_in = False
        self.uid: Optional[str] = None
        self.username: Optional[str] = None

    async def init(self):
        """Load persisted session from DB on startup."""
        async with aiosqlite.connect(self.db_path) as db:
            row = await (await db.execute("SELECT cookies_json, uid, username FROM chaoxing_session WHERE id=1")).fetchone()
            if row and row[0]:
                cookies = json.loads(row[0])
                self._client = self._make_client(cookies)
                self.uid = row[1]
                self.username = row[2]
                # Probe to verify session still valid
                self.is_logged_in = await self._probe_session()

    def _make_client(self, cookies: dict) -> httpx.AsyncClient:
        return httpx.AsyncClient(
            cookies=cookies,
            headers={"User-Agent": CHAOXING_UA},
            follow_redirects=True,
            timeout=httpx.Timeout(20.0),
        )

    async def _probe_session(self) -> bool:
        """Lightweight session validity check."""
        try:
            resp = await self._client.get("https://passport2.chaoxing.com/api/check?islogin=1")
            data = resp.json()
            return data.get("isLogin", False)
        except Exception:
            return False

    async def request_otp(self, phone: str) -> bool:
        """Step 1: Send OTP to phone."""
        client = httpx.AsyncClient(headers={"User-Agent": CHAOXING_UA}, follow_redirects=True)
        resp = await client.post(
            "https://passport2.chaoxing.com/mlogin/phoneLoginV2",
            data={"phone": phone, "type": "1"},
        )
        return resp.json().get("status", False)

    async def verify_otp(self, phone: str, code: str) -> bool:
        """Step 2: Verify OTP and save session."""
        client = httpx.AsyncClient(headers={"User-Agent": CHAOXING_UA}, follow_redirects=True)
        resp = await client.post(
            "https://passport2.chaoxing.com/mlogin/phoneLoginV2",
            data={"phone": phone, "code": code, "type": "2"},
        )
        data = resp.json()
        if not data.get("status"):
            return False

        cookies = dict(client.cookies)
        uid = cookies.get("_uid") or cookies.get("UID")
        self._client = self._make_client(cookies)
        self.is_logged_in = True
        self.uid = uid
        self.username = phone

        async with aiosqlite.connect(self.db_path) as db:
            await db.execute(
                "INSERT OR REPLACE INTO chaoxing_session (id, cookies_json, uid, username, phone, logged_in_at) VALUES (1,?,?,?,?,?)",
                (json.dumps(cookies), uid, phone, phone, datetime.utcnow().isoformat()),
            )
            await db.commit()
        return True

    async def logout(self):
        self.is_logged_in = False
        self._client = None
        self.uid = None
        async with aiosqlite.connect(self.db_path) as db:
            await db.execute("DELETE FROM chaoxing_session WHERE id=1")
            await db.commit()

    async def fetch_all_pending_assignments(self) -> list[dict]:
        """
        Port of ChaoxingService.fetchAllPendingAssignments().
        Returns list of assignment dicts matching ScheduleChaoxingAssignmentItem shape.
        """
        if not self.is_logged_in:
            return []
        # Implementation: iterate paginated assignment list endpoint
        # Return list of dicts with keys: id, originalID, courseID, courseName,
        #   title, dueDate (ISO8601), status, type, remainingTime
        raise NotImplementedError("Implement Chaoxing assignment fetch")

    async def fetch_conversation_probes(
        self,
        limit: int = 12,
    ) -> list[dict]:
        """
        Port of ChaoxingService.fetchMessageConversationProbes() in Swift.

        Lightweight probe — fetches only conversation headers (no message bodies).
        Returns list of dicts with keys: conversation_id, name, signature
        where signature = f"{lastMessageId}:{messageCount}".

        The background sync job calls this first. If the signature for a conversation
        matches the stored value in chaoxing_probe_signatures, skip the full message
        fetch for that conversation. Only fetch full messages for changed conversations.

        This reduces API calls by 80–95% when nothing has changed.
        """
        if not self.is_logged_in:
            return []
        raise NotImplementedError("Implement Chaoxing conversation probe")

    async def fetch_recent_messages(
        self,
        max_conversations: int = 12,
        per_conversation: int = 20,
        changed_conversation_ids: list[str] | None = None,
    ) -> list[dict]:
        """
        Port of ChaoxingService.fetchRecentMessages().
        Returns list of conversation message dicts.

        If changed_conversation_ids is provided, only fetch those conversations
        (probe-before-full-fetch optimization). If None, fetch all max_conversations.
        """
        if not self.is_logged_in:
            return []
        raise NotImplementedError("Implement Chaoxing message fetch")

    async def fetch_courses(self) -> list[dict]:
        """Fetch enrolled courses. Used for schedule sidebar."""
        if not self.is_logged_in:
            return []
        raise NotImplementedError("Implement Chaoxing course fetch")

    async def adaptive_sync_pass(self, db_path: str) -> float:
        """
        Port of ChatViewModel+Schedule.swift runChaoxingRuntimeSyncPass() +
        nextChaoxingRuntimeInterval().

        Runs one sync cycle and returns the next interval in seconds.

        Adaptive interval logic (port exactly from Swift):
        - Start: 45s
        - Each cycle with no new data: increment consecutiveNoChangeCount
        - After 2 unchanged cycles: 90s
        - After 4 unchanged cycles: 180s
        - After 8 unchanged cycles: 300s
        - After 12 unchanged cycles: 600s
        - Reset count when new data found

        During "important window" (within 1h of any assignment deadline): always 45s.

        The count is persisted in chaoxing_sync_state table
        (key="consecutive_no_change_count") so restarts don't reset it.
        """
        # 1. Probe conversations
        probes = await self.fetch_conversation_probes()
        changed_ids = await self._filter_changed_probes(probes, db_path)

        # 2. Only fetch full messages for changed conversations
        if changed_ids:
            messages = await self.fetch_recent_messages(changed_conversation_ids=changed_ids)
            consecutive_no_change = 0
        else:
            messages = []
            consecutive_no_change = await self._get_consecutive_no_change(db_path) + 1

        await self._save_probe_signatures(probes, db_path)
        await self._save_consecutive_no_change(consecutive_no_change, db_path)

        # 3. Return next interval
        return self._next_interval(consecutive_no_change, await self._in_important_window(db_path))

    def _next_interval(self, consecutive_no_change: int, in_important_window: bool) -> float:
        if in_important_window:
            return 45.0
        if consecutive_no_change >= 12:
            return 600.0
        if consecutive_no_change >= 8:
            return 300.0
        if consecutive_no_change >= 4:
            return 180.0
        if consecutive_no_change >= 2:
            return 90.0
        return 45.0
```

> **Implementation note**: The actual HTTP request details for Chaoxing endpoints must be
> reverse-engineered from the Swift source (`ChaoxingService.swift`, 1341 lines). Copy the
> exact URL paths, headers, form fields, and response parsing logic from Swift to Python.
> Do NOT guess — Chaoxing's API is undocumented and fragile.

---

## 8. Backend — `services/memory_agent.py`

Port of `ChaoxingMemoryAgent.swift` + `ChaoxingMemoryReducer.swift`.

```python
"""
AI-driven memory extraction from Chaoxing messages.
Port of ChaoxingMemoryAgent.swift.

⚠️  OCR STRIPPING: The Swift source calls OCRService.enrichMessagesWithOCR() before
extraction (ChaoxingMemoryAgent.swift lines 40–48). This uses macOS Vision framework
(VNRecognizeTextRequest) which is NOT available on a Linux server. In the web version,
skip this step entirely. Feed the raw message text directly to the LLM without enrichment.
The line to omit is:
    enriched = await OCRService.enrichMessagesWithOCR(candidates)
Replace with:
    enriched = candidates

Algorithm:
1. Receive recent Chaoxing messages (from fetch_recent_messages).
2. Filter out already-processed IDs (chaoxing_processed_ids table).
3. Also filter out muted conversation names (settings table: "chaoxing_muted_conversations").
4. Send remaining messages to LLM with a structured extraction prompt.
   (Skip OCR enrichment — not available on server.)
5. LLM returns JSON array of memory entries (title, summary, importance, action_hint, ...).
6. Upsert into chaoxing_memory_entries table.
7. Save processed IDs to chaoxing_processed_ids.
8. Run maintenance: expire old low-importance entries (> 30 days).

The extraction prompt is CRITICAL — port it exactly from ChaoxingMemoryAgent.swift.
It instructs the model to identify actionable/important information, assign importance
levels (low/medium/high), and generate action hints.

Memory schema (mirrors ChaoxingMemoryEntry in Swift):
{
  "id": str,
  "source_message_id": str,
  "conversation_id": str,
  "conversation_name": str,
  "sender_id": str,
  "sender_name": str | null,
  "title": str,
  "summary": str,
  "reason": str,
  "action_hint": str | null,
  "importance": "low" | "medium" | "high",
  "sent_at": ISO8601,
  "extracted_at": ISO8601,
  "expires_at": ISO8601 | null,   -- explicit expiry set by LLM extraction prompt when applicable
  "source_text_preview": str
}

Note: expires_at is populated from the LLM extraction response when the extracted item
has a clear deadline (e.g., an assignment due date). The is_semantically_expired() check
(Bug 5 fix) uses expires_at when present instead of regex-parsing the text.

Maintenance rules (port from ChaoxingMemoryStore.maintain()):
- Archive entries older than 30 days with importance == "low"
- Archive entries older than 60 days with importance == "medium"
- Never archive importance == "high" automatically
- Keep at most 200 entries total; drop oldest low-importance first
"""

async def run_memory_agent(
    chaoxing_svc,
    db_path: str,
    provider: dict,
    model: str,
    api_key: str,
    muted_names: set[str] = None,
) -> dict:
    """Returns {"candidate_count": int, "kept_count": int, "processed_ids": list[str]}"""
    from .agent_service import get_http_client
    # 1. Fetch messages
    messages = await chaoxing_svc.fetch_recent_messages(max_conversations=12, per_conversation=20)
    if not messages:
        return {"candidate_count": 0, "kept_count": 0, "processed_ids": []}

    # 2. Filter processed + muted
    async with aiosqlite.connect(db_path) as db:
        rows = await (await db.execute("SELECT message_id FROM chaoxing_processed_ids")).fetchall()
        processed_ids = {r[0] for r in rows}

    candidates = [
        m for m in messages
        if m["id"] not in processed_ids
        and (not muted_names or m.get("conversation_name") not in muted_names)
    ]

    if not candidates:
        return {"candidate_count": 0, "kept_count": 0, "processed_ids": []}

    # 3. LLM extraction
    extracted = await _extract_memory_entries(candidates, provider, model, api_key)

    # 4. Upsert to DB
    async with aiosqlite.connect(db_path) as db:
        for entry in extracted:
            await db.execute("""
                INSERT OR REPLACE INTO chaoxing_memory_entries
                (id, source_message_id, conversation_id, conversation_name,
                 sender_id, sender_name, title, summary, reason, action_hint,
                 importance, sent_at, extracted_at, source_text_preview)
                VALUES (?,?,?,?,?,?,?,?,?,?,?,?,?,?)
            """, (
                entry["id"], entry["source_message_id"], entry["conversation_id"],
                entry["conversation_name"], entry["sender_id"], entry.get("sender_name"),
                entry["title"], entry["summary"], entry["reason"], entry.get("action_hint"),
                entry["importance"], entry["sent_at"],
                datetime.utcnow().isoformat(), entry.get("source_text_preview", "")[:200],
            ))
        # Save processed IDs
        for m in candidates:
            await db.execute(
                "INSERT OR IGNORE INTO chaoxing_processed_ids (message_id, processed_at) VALUES (?,?)",
                (m["id"], datetime.utcnow().isoformat()),
            )
        await db.commit()

    return {
        "candidate_count": len(candidates),
        "kept_count": len(extracted),
        "processed_ids": [m["id"] for m in candidates],
    }


async def _extract_memory_entries(messages: list[dict], provider, model, api_key) -> list[dict]:
    """Call LLM with extraction prompt. Port the exact system prompt from ChaoxingMemoryAgent.swift."""
    # Build the prompt — MUST mirror the Swift version exactly.
    # The prompt instructs the model to return a JSON array.
    # Use json.loads() on the response and validate the schema.
    raise NotImplementedError("Port extraction prompt from ChaoxingMemoryAgent.swift")


async def run_memory_maintenance(db_path: str):
    """Port of ChaoxingMemoryStore.maintain() — expire old entries."""
    now = datetime.utcnow()
    async with aiosqlite.connect(db_path) as db:
        # Archive low importance > 30 days
        await db.execute("""
            UPDATE chaoxing_memory_entries SET archived_at=?
            WHERE importance='low' AND archived_at IS NULL
            AND julianday(?) - julianday(sent_at) > 30
        """, (now.isoformat(), now.isoformat()))
        # Archive medium importance > 60 days
        await db.execute("""
            UPDATE chaoxing_memory_entries SET archived_at=?
            WHERE importance='medium' AND archived_at IS NULL
            AND julianday(?) - julianday(sent_at) > 60
        """, (now.isoformat(), now.isoformat()))
        # Enforce 200-entry limit
        await db.execute("""
            UPDATE chaoxing_memory_entries SET archived_at=?
            WHERE id IN (
                SELECT id FROM chaoxing_memory_entries
                WHERE archived_at IS NULL
                ORDER BY CASE importance WHEN 'high' THEN 3 WHEN 'medium' THEN 2 ELSE 1 END ASC,
                         sent_at ASC
                LIMIT MAX(0, (SELECT COUNT(*) FROM chaoxing_memory_entries WHERE archived_at IS NULL) - 200)
            )
        """, (now.isoformat(),))
        await db.commit()
```

---

## 9. Backend — `services/schedule_agent.py`

Port of `ScheduleSkill.swift` + `ScheduleHarness.swift` + `ChatViewModel+Schedule.swift`.

The Schedule Agent is an agentic loop with these tools:
- `get_schedule_context` — returns sidebar snapshot (courses, assignments, memories, quick captures)
- `get_chaoxing_memory` — returns curated memory entries
- `refresh_chaoxing_memory` — triggers memory agent re-run
- `read_chaoxing_assignments` — fetch fresh assignments from Chaoxing
- `read_chaoxing_messages` — fetch recent messages
- ~~`create_reminder`~~ / ~~`create_calendar_event`~~ — **SKIPPED** (no EventKit)

The agent produces a **structured schedule payload** in its response:
```json
{
  "type": "schedule_payload",
  "courses": [...],
  "chaoxing_assignments": [...],
  "chaoxing_messages": [...],
  "reminders": [],
  "actions": [{"kind": "info", "title": "...", "detail": "..."}]
}
```

The frontend renders this as rich cards, not plain text.

```python
async def run_schedule_agent(
    user_message: str,
    history: list[dict],
    provider: dict,
    model: str,
    api_key: str,
    chaoxing_svc,
    db_path: str,
    thinking_budget: int = 0,
) -> AsyncGenerator[dict, None]:
    """
    SSE event generator for the Schedule Agent.
    Mirrors the schedule agent flow in ChatViewModel+Schedule.swift.

    Context window: last 20 messages (scheduleContextWindowSize = 20 in Swift).
    System prompt: from settings table key "schedule_agent_prompt".
    """
    from .agent_service import AgentMsg, ToolDefinition, run_agentic_loop

    system_prompt = await _get_setting(db_path, "schedule_agent_prompt") or DEFAULT_SCHEDULE_PROMPT
    dynamic_context = _build_dynamic_context()  # current time + timezone

    # ⚠️ BUG 1 FIX: Dynamic context MUST be merged into the system prompt BEFORE
    # calling run_agentic_loop(), NOT appended as a second system-role message.
    # In the Swift source, ScheduleHarness.buildMessages() appends dynamic context
    # as a second AgentMsg(role: .system, ...) which Anthropic silently drops.
    # Fix: prepend dynamic context to the static system prompt so there is only
    # ever one system message.
    merged_system = f"{dynamic_context}\n\n{system_prompt}"

    # Build compressed context (last 20 messages)
    trimmed_history = history[-(20 * 2):]  # 20 user+assistant pairs
    messages = [AgentMsg(role="system", content=merged_system)]
    for m in trimmed_history:
        messages.append(AgentMsg(role=m["role"], content=m["content"]))
    messages.append(AgentMsg(role="user", content=user_message))

    tools = _build_schedule_tools()

    async def execute_tool(tc):
        return await _execute_schedule_tool(tc, chaoxing_svc, db_path)

    async for event in run_agentic_loop(
        messages, tools, execute_tool, provider, model, api_key,
        max_iterations=12, thinking_budget=thinking_budget,
    ):
        yield event


def _build_schedule_tools() -> list:
    from .agent_service import ToolDefinition
    return [
        ToolDefinition(
            name="get_schedule_context",
            description="获取当前日程上下文：今日课程、作业截止、重要学习通消息、备忘录",
            input_schema={"type": "object", "properties": {}, "additionalProperties": False},
        ),
        ToolDefinition(
            name="get_chaoxing_memory",
            description="读取学习通消息语义记忆库，返回重要/中等重要度的已提取记忆",
            input_schema={
                "type": "object",
                "properties": {
                    "importance_filter": {
                        "type": "string",
                        "enum": ["all", "high", "medium", "high_and_medium"],
                        "description": "过滤重要度",
                    }
                },
                "additionalProperties": False,
            },
        ),
        ToolDefinition(
            name="refresh_chaoxing_memory",
            description="触发学习通 Memory Agent 重新扫描近期消息并提取记忆",
            input_schema={"type": "object", "properties": {}, "additionalProperties": False},
        ),
        ToolDefinition(
            name="read_chaoxing_assignments",
            description="从学习通实时拉取待提交作业列表",
            input_schema={"type": "object", "properties": {}, "additionalProperties": False},
        ),
    ]


DEFAULT_SCHEDULE_PROMPT = """
优先把日程、作业和学习通重要消息交给结构化 UI 展示。
最终回复只写一句中文摘要。
创建或修改条目前必须等用户确认。
""".strip()


def _build_dynamic_context() -> str:
    """
    Port of ScheduleHarness.buildDynamicContextPrompt() in Swift.
    Injects current timestamp with timezone. Prepended to system prompt (not sent
    as a separate system message — see Bug 1 fix above).

    The Swift version also injects cached reminders/events via makeTurnContextPrompt().
    In the web version, skip Calendar/Reminders (EventKit not available).
    Only inject current time + Chaoxing login status here; tool calls will fetch the rest.
    """
    from datetime import datetime, timezone
    import zoneinfo
    tz = zoneinfo.ZoneInfo("Asia/Shanghai")
    now = datetime.now(tz)
    return (
        f"Current time: {now.strftime('%Y-%m-%d %H:%M')} (CST, UTC+8)\n"
        f"Day of week: {now.strftime('%A')}"
    )
```

---

## 10. Backend — `services/push_service.py`

Web Push via VAPID. Port of the push notification trigger logic.

```python
"""
Web Push notification sender.
Uses pywebpush library.

Install: pip install pywebpush

VAPID key generation (run once):
    python -c "
    from py_vapid import Vapid
    v = Vapid()
    v.generate_keys()
    print('PRIVATE:', v.private_key.private_bytes(...))
    print('PUBLIC:', v.public_key.public_bytes(...))
    "
Or use: npx web-push generate-vapid-keys
"""

import json
from pywebpush import webpush, WebPushException
from app.config import settings
import aiosqlite
import asyncio
from datetime import datetime


async def send_push_to_all_subscribers(
    db_path: str,
    title: str,
    body: str,
    data: dict = None,
    tag: str = None,
    icon: str = "/icon-192.png",
):
    """
    Send a push notification to all registered subscribers.
    Removes subscriptions that return 404/410 (unsubscribed).
    """
    async with aiosqlite.connect(db_path) as db:
        rows = await (await db.execute(
            "SELECT id, endpoint, p256dh, auth FROM push_subscriptions"
        )).fetchall()

    stale_ids = []
    for row in rows:
        sub_id, endpoint, p256dh, auth = row
        ok = await _send_one(endpoint, p256dh, auth, title, body, data, tag, icon)
        if not ok:
            stale_ids.append(sub_id)

    if stale_ids:
        async with aiosqlite.connect(db_path) as db:
            await db.execute(
                f"DELETE FROM push_subscriptions WHERE id IN ({','.join('?' * len(stale_ids))})",
                stale_ids,
            )
            await db.commit()


async def _send_one(endpoint, p256dh, auth, title, body, data, tag, icon) -> bool:
    """Returns False if subscription is stale (should be deleted)."""
    payload = json.dumps({
        "title": title,
        "body": body,
        "icon": icon,
        "tag": tag,
        "data": data or {},
    })
    try:
        # pywebpush is synchronous — run in threadpool
        await asyncio.to_thread(
            webpush,
            subscription_info={"endpoint": endpoint, "keys": {"p256dh": p256dh, "auth": auth}},
            data=payload,
            vapid_private_key=settings.vapid_private_key,
            vapid_claims={"sub": settings.vapid_mailto},
        )
        return True
    except WebPushException as e:
        status = e.response.status_code if e.response else None
        if status in (404, 410):
            return False  # stale subscription
        # Other errors (network, etc.) — keep subscription, log error
        print(f"Push failed (status={status}): {e}")
        return True
    except Exception as e:
        print(f"Push error: {e}")
        return True


async def log_notification_sent(db_path: str, item_id: str, notif_type: str):
    """Dedup guard — prevents sending same notification twice."""
    async with aiosqlite.connect(db_path) as db:
        await db.execute(
            "INSERT OR IGNORE INTO notification_log (item_id, notif_type, sent_at) VALUES (?,?,?)",
            (item_id, notif_type, datetime.utcnow().isoformat()),
        )
        await db.commit()


async def has_notified(db_path: str, item_id: str, notif_type: str) -> bool:
    async with aiosqlite.connect(db_path) as db:
        row = await (await db.execute(
            "SELECT 1 FROM notification_log WHERE item_id=? AND notif_type=?",
            (item_id, notif_type),
        )).fetchone()
        return row is not None
```

---

## 11. Backend — `tasks/scheduler.py` + `tasks/notification_sender.py`

```python
# scheduler.py
"""
APScheduler setup. Runs inside the FastAPI process.
Port of the Timer-based polling in ChatViewModel+Schedule.swift (ChaoxingRuntimeSync).

Job intervals:
- chaoxing_probe: ADAPTIVE 45s–600s (see ChaoxingService.adaptive_sync_pass())
  The fixed 5-min interval from CHAOXING_SYNC_INTERVAL env is the fallback maximum.
  The job reschedules itself after each run based on the returned next_interval.
- memory_maintenance: every 30 min
- daily_summary: daily at 08:00 server time
- deadline_check: every 5 min

24/7 optimization notes:
- Use AsyncIOScheduler (not BackgroundScheduler) — shares the event loop.
- Misfire grace time: 60s for short jobs, 300s for long ones.
- On startup: run an immediate probe so the user sees fresh data.
- Jobs are idempotent — safe to re-run if misfire occurs.
- The chaoxing_probe uses DateTrigger for self-rescheduling (not IntervalTrigger)
  so the interval can vary per cycle.
"""
from apscheduler.schedulers.asyncio import AsyncIOScheduler
from apscheduler.triggers.interval import IntervalTrigger
from apscheduler.triggers.cron import CronTrigger
from apscheduler.triggers.date import DateTrigger
from datetime import datetime, timezone, timedelta

scheduler = AsyncIOScheduler(timezone="Asia/Shanghai")

def init_scheduler(app_state):
    """Call from FastAPI lifespan after all services are initialized."""
    from app.tasks.chaoxing_sync import run_chaoxing_probe_adaptive
    from app.tasks.notification_sender import check_and_send_deadline_notifications, send_daily_summary

    # Adaptive probe — schedules itself after each run
    scheduler.add_job(
        run_chaoxing_probe_adaptive,
        DateTrigger(run_date=datetime.now(timezone.utc) + timedelta(seconds=5)),
        args=[app_state, scheduler],
        id="chaoxing_probe",
        misfire_grace_time=60,
        replace_existing=True,
    )
    scheduler.add_job(
        check_and_send_deadline_notifications,
        IntervalTrigger(seconds=300),
        args=[app_state],
        id="deadline_check",
        misfire_grace_time=60,
        replace_existing=True,
    )
    scheduler.add_job(
        send_daily_summary,
        CronTrigger(hour=8, minute=0),
        args=[app_state],
        id="daily_summary",
        misfire_grace_time=300,
        replace_existing=True,
    )
    scheduler.start()


# chaoxing_sync.py (adaptive probe)
async def run_chaoxing_probe_adaptive(app_state, scheduler):
    """
    Run one Chaoxing sync cycle, then reschedule itself with the adaptive interval.
    Port of ChatViewModel+Schedule.swift runChaoxingRuntimeSyncPass().
    """
    if not app_state.chaoxing_svc.is_logged_in:
        next_interval = 300.0  # check less often when not logged in
    else:
        next_interval = await app_state.chaoxing_svc.adaptive_sync_pass(
            app_state.settings.database_path
        )
        # Cap at env var maximum
        max_interval = app_state.settings.chaoxing_sync_interval
        next_interval = min(next_interval, max_interval)

    # Reschedule with new interval
    run_at = datetime.now(timezone.utc) + timedelta(seconds=next_interval)
    scheduler.add_job(
        run_chaoxing_probe_adaptive,
        DateTrigger(run_date=run_at),
        args=[app_state, scheduler],
        id="chaoxing_probe",
        misfire_grace_time=60,
        replace_existing=True,
    )
```

```python
# notification_sender.py
"""
Push notification decision logic.
Port of CompanionEngine.makeState() from Swift.

Notification types:
1. deadline_1h   — assignment/event due within 1 hour
2. deadline_24h  — assignment/event due within 24 hours (sent once per day)
3. memory_high   — new high-importance Chaoxing memory entry detected
4. daily_summary — morning digest (08:00) of today's items

All notifications use dedup via notification_log table.
"""
from datetime import datetime, timedelta, timezone
from app.services.push_service import send_push_to_all_subscribers, has_notified, log_notification_sent


async def check_and_send_deadline_notifications(app_state):
    if not app_state.chaoxing_svc.is_logged_in:
        return

    db_path = app_state.settings.database_path
    now = datetime.now(timezone.utc)

    # Check assignments
    assignments = await app_state.chaoxing_svc.fetch_all_pending_assignments()
    for assignment in assignments:
        due = datetime.fromisoformat(assignment["dueDate"])
        delta = due - now

        if timedelta(0) < delta <= timedelta(hours=1):
            notif_type = "deadline_1h"
            if not await has_notified(db_path, assignment["id"], notif_type):
                await send_push_to_all_subscribers(
                    db_path,
                    title=f"⏰ {assignment['title']}",
                    body=f"截止时间不到 1 小时！{assignment['courseName']}",
                    tag=f"deadline-{assignment['id']}",
                    data={"type": "assignment", "id": assignment["id"]},
                )
                await log_notification_sent(db_path, assignment["id"], notif_type)

        elif timedelta(hours=1) < delta <= timedelta(hours=24):
            notif_type = "deadline_24h"
            if not await has_notified(db_path, assignment["id"], notif_type):
                remaining = _format_remaining(delta)
                await send_push_to_all_subscribers(
                    db_path,
                    title=f"📋 {assignment['title']}",
                    body=f"还剩 {remaining}。{assignment['courseName']}",
                    tag=f"deadline-{assignment['id']}",
                )
                await log_notification_sent(db_path, assignment["id"], notif_type)

    # Check high-importance memory entries (new ones since last check)
    import aiosqlite
    async with aiosqlite.connect(db_path) as db:
        rows = await (await db.execute("""
            SELECT id, title, action_hint FROM chaoxing_memory_entries
            WHERE importance='high' AND archived_at IS NULL
            AND datetime(extracted_at) > datetime('now', '-10 minutes')
        """)).fetchall()

    for row in rows:
        entry_id, title, action_hint = row
        notif_type = "memory_high"
        if not await has_notified(db_path, entry_id, notif_type):
            await send_push_to_all_subscribers(
                db_path,
                title=f"🔔 重要消息：{title}",
                body=action_hint or title,
                tag=f"memory-{entry_id}",
            )
            await log_notification_sent(db_path, entry_id, notif_type)


async def send_daily_summary(app_state):
    """08:00 daily digest push."""
    db_path = app_state.settings.database_path
    now = datetime.now(timezone.utc)
    today_str = now.strftime("%Y-%m-%d")
    notif_id = f"daily-{today_str}"

    if await has_notified(db_path, notif_id, "daily_summary"):
        return

    assignments = []
    if app_state.chaoxing_svc.is_logged_in:
        all_assignments = await app_state.chaoxing_svc.fetch_all_pending_assignments()
        assignments = [a for a in all_assignments if _due_within_days(a["dueDate"], days=3)]

    if assignments:
        title = f"📅 今日提醒：{len(assignments)} 个任务需要关注"
        body = "、".join(a["title"] for a in assignments[:3])
        if len(assignments) > 3:
            body += f" 等 {len(assignments)} 项"
    else:
        title = "☀️ 今天没有紧急任务"
        body = "保持好状态！"

    await send_push_to_all_subscribers(db_path, title=title, body=body, tag="daily-summary")
    await log_notification_sent(db_path, notif_id, "daily_summary")


def _format_remaining(delta: timedelta) -> str:
    total = int(delta.total_seconds())
    h, m = divmod(total // 60, 60)
    return f"{h} 小时 {m} 分钟" if h else f"{m} 分钟"

def _due_within_days(due_str: str, days: int) -> bool:
    try:
        due = datetime.fromisoformat(due_str)
        return timedelta(0) < due - datetime.now(timezone.utc) <= timedelta(days=days)
    except Exception:
        return False
```

---

## 12. Backend — Key API Routes

### `routers/chat.py` — SSE Streaming Chat

```python
from fastapi import APIRouter, Request
from fastapi.responses import StreamingResponse
import json, asyncio

router = APIRouter(prefix="/api/conversations", tags=["chat"])

@router.post("/{conv_id}/chat")
async def stream_chat(conv_id: str, request: Request):
    """
    SSE endpoint for streaming chat.
    Request body: {"message": str}
    SSE events: {"type": "text"|"reasoning"|"usage"|"tool_start"|"tool_result"|"done", ...}

    This is the main chat path. The schedule agent has its own endpoint at
    POST /api/schedule/chat.

    Implementation steps:
    1. Load conversation + messages from DB.
    2. Append user message.
    3. Determine provider, model, api_key.
    4. If agent_mode == "multiAgent": call multi_agent_complete().
    5. If agent_mode has tools enabled: call run_agentic_loop() with chat tools.
    6. Otherwise: call make_service(api_type)() directly.
    7. Stream events as SSE.
    8. On stream end: save assistant message + usage to DB.

    CRITICAL: Set these response headers for SSE:
      Cache-Control: no-cache
      X-Accel-Buffering: no   ← tells nginx NOT to buffer SSE
    """
    body = await request.json()
    user_message = body.get("message", "").strip()
    if not user_message:
        return {"error": "empty message"}

    # [load conversation, build messages, select provider...]

    async def generate():
        try:
            # [streaming logic here]
            yield f"data: {json.dumps({'type': 'done'})}\n\n"
        except asyncio.CancelledError:
            yield f"data: {json.dumps({'type': 'cancelled'})}\n\n"
        except Exception as e:
            yield f"data: {json.dumps({'type': 'error', 'message': str(e)})}\n\n"

    return StreamingResponse(
        generate(),
        media_type="text/event-stream",
        headers={
            "Cache-Control": "no-cache",
            "X-Accel-Buffering": "no",
            "Connection": "keep-alive",
        },
    )
```

### `routers/push.py`

```python
from fastapi import APIRouter
router = APIRouter(prefix="/api/push", tags=["push"])

@router.get("/vapid-public-key")
async def get_vapid_key():
    """Frontend calls this on startup to get the VAPID public key for PushManager.subscribe()."""
    from app.config import settings
    return {"publicKey": settings.vapid_public_key}

@router.post("/subscribe")
async def subscribe(body: dict, db=Depends(get_db)):
    """
    Body: {
      "endpoint": str,
      "keys": {"p256dh": str, "auth": str}
    }
    Saves to push_subscriptions table.
    """
    ...

@router.delete("/subscribe")
async def unsubscribe(body: dict, db=Depends(get_db)):
    """Remove subscription by endpoint."""
    ...

@router.post("/test")
async def send_test_push(db=Depends(get_db)):
    """Send a test notification to all subscribers."""
    from app.config import settings
    await send_push_to_all_subscribers(
        settings.database_path,
        title="✅ 推送测试",
        body="Web Push 配置正确！",
        tag="test",
    )
    return {"ok": True}
```

---

## 13. Backend — `main.py`

```python
from contextlib import asynccontextmanager
from fastapi import FastAPI
from fastapi.middleware.cors import CORSMiddleware
from app.services.api_service import init_http_client, close_http_client
from app.services.chaoxing_service import ChaoxingService
from app.database import run_migrations
from app.config import settings
from app.tasks.scheduler import init_scheduler, scheduler

@asynccontextmanager
async def lifespan(app: FastAPI):
    # Startup
    await run_migrations(settings.database_path)
    await init_http_client()

    chaoxing_svc = ChaoxingService(settings.database_path)
    await chaoxing_svc.init()
    app.state.chaoxing_svc = chaoxing_svc
    app.state.settings = settings

    init_scheduler(app.state)

    yield  # Application runs here

    # Shutdown
    scheduler.shutdown(wait=False)
    await close_http_client()


app = FastAPI(title="ChatBot API", lifespan=lifespan)

app.add_middleware(
    CORSMiddleware,
    allow_origins=["*"],  # Lock this down in production if needed
    allow_methods=["*"],
    allow_headers=["*"],
)

@app.get("/health")
async def health():
    return {"status": "ok", "chaoxing_logged_in": app.state.chaoxing_svc.is_logged_in}

# Register routers
from app.routers import conversations, chat, schedule, chaoxing, providers, settings as settings_router, push
app.include_router(conversations.router)
app.include_router(chat.router)
app.include_router(schedule.router)
app.include_router(chaoxing.router)
app.include_router(providers.router)
app.include_router(settings_router.router)
app.include_router(push.router)
```

---

## 14. Backend — `requirements.txt`

```
fastapi==0.115.0
uvicorn[standard]==0.30.0
aiosqlite==0.20.0
httpx==0.27.0
pydantic-settings==2.4.0
apscheduler==3.10.4
pywebpush==2.0.0
py-vapid==1.9.1
python-multipart==0.0.9
```

---

## 15. Frontend — PWA Service Worker (`public/sw.js`)

```javascript
// public/sw.js
// Service Worker: handles Web Push notifications and optional offline caching.

self.addEventListener("install", (e) => self.skipWaiting());
self.addEventListener("activate", (e) => e.waitUntil(self.clients.claim()));

// Push event — triggered when server sends a Web Push notification
self.addEventListener("push", (event) => {
  const data = event.data?.json() ?? {};
  const title = data.title ?? "ChatBot";
  const options = {
    body: data.body ?? "",
    icon: data.icon ?? "/icon-192.png",
    badge: "/badge-72.png",
    tag: data.tag ?? "default",
    data: data.data ?? {},
    // Vibration pattern (mobile)
    vibrate: data.urgency === "high" ? [200, 100, 200] : [100],
    // Keep notification until user taps (important for deadline reminders)
    requireInteraction: data.data?.type === "assignment",
  };
  event.waitUntil(self.registration.showNotification(title, options));
});

// Notification click — open the app to the relevant tab
self.addEventListener("notificationclick", (event) => {
  event.notification.close();
  const data = event.notification.data ?? {};
  const url = data.type === "assignment" ? "/?tab=schedule" : "/";
  event.waitUntil(
    self.clients.matchAll({ type: "window", includeUncontrolled: true }).then((clients) => {
      const existing = clients.find((c) => c.url.includes(self.location.origin));
      if (existing) {
        existing.focus();
        existing.postMessage({ type: "navigate", url });
      } else {
        self.clients.openWindow(url);
      }
    })
  );
});
```

---

## 16. Frontend — `public/manifest.json`

```json
{
  "name": "ChatBot",
  "short_name": "ChatBot",
  "start_url": "/",
  "display": "standalone",
  "background_color": "#000000",
  "theme_color": "#000000",
  "icons": [
    { "src": "/icon-192.png", "sizes": "192x192", "type": "image/png" },
    { "src": "/icon-512.png", "sizes": "512x512", "type": "image/png" }
  ]
}
```

---

## 17. Frontend — `hooks/usePush.js`

```javascript
// hooks/usePush.js
import { useState, useEffect } from "react";
import { subscribeToServer, unsubscribeFromServer, getVapidKey } from "../api/push";

export function usePush() {
  const [supported, setSupported] = useState(false);
  const [permission, setPermission] = useState("default");
  const [subscribed, setSubscribed] = useState(false);

  useEffect(() => {
    setSupported("serviceWorker" in navigator && "PushManager" in window);
    setPermission(Notification.permission);
  }, []);

  async function subscribe() {
    if (!supported) return { error: "not_supported" };

    const perm = await Notification.requestPermission();
    setPermission(perm);
    if (perm !== "granted") return { error: "denied" };

    const reg = await navigator.serviceWorker.ready;
    const { publicKey } = await getVapidKey();

    const sub = await reg.pushManager.subscribe({
      userVisibleOnly: true,
      applicationServerKey: _urlBase64ToUint8Array(publicKey),
    });

    await subscribeToServer({
      endpoint: sub.endpoint,
      keys: {
        p256dh: btoa(String.fromCharCode(...new Uint8Array(sub.getKey("p256dh")))),
        auth: btoa(String.fromCharCode(...new Uint8Array(sub.getKey("auth")))),
      },
    });
    setSubscribed(true);
    return { ok: true };
  }

  async function unsubscribe() {
    const reg = await navigator.serviceWorker.ready;
    const sub = await reg.pushManager.getSubscription();
    if (sub) {
      await unsubscribeFromServer({ endpoint: sub.endpoint });
      await sub.unsubscribe();
    }
    setSubscribed(false);
  }

  return { supported, permission, subscribed, subscribe, unsubscribe };
}

function _urlBase64ToUint8Array(base64String) {
  const padding = "=".repeat((4 - (base64String.length % 4)) % 4);
  const base64 = (base64String + padding).replace(/-/g, "+").replace(/_/g, "/");
  const rawData = atob(base64);
  return Uint8Array.from([...rawData].map((c) => c.charCodeAt(0)));
}
```

---

## 18. Frontend — `hooks/useSSEStream.js`

```javascript
// hooks/useSSEStream.js
/**
 * Generic SSE streaming hook.
 * Usage:
 *   const { startStream, stopStream, isStreaming } = useSSEStream({
 *     onText: (chunk) => setContent(prev => prev + chunk),
 *     onReasoning: (chunk) => setReasoning(prev => prev + chunk),
 *     onUsage: (usage) => setUsage(usage),
 *     onDone: () => {},
 *     onError: (msg) => setError(msg),
 *   });
 */
import { useRef, useState, useCallback } from "react";

export function useSSEStream({ onText, onReasoning, onUsage, onToolStart, onToolResult, onDone, onError }) {
  const [isStreaming, setIsStreaming] = useState(false);
  const controllerRef = useRef(null);

  const startStream = useCallback(async (url, body) => {
    if (isStreaming) return;
    setIsStreaming(true);
    controllerRef.current = new AbortController();

    try {
      const resp = await fetch(url, {
        method: "POST",
        headers: { "Content-Type": "application/json" },
        body: JSON.stringify(body),
        signal: controllerRef.current.signal,
      });

      if (!resp.ok) throw new Error(`HTTP ${resp.status}`);

      const reader = resp.body.getReader();
      const decoder = new TextDecoder();
      let buffer = "";

      while (true) {
        const { done, value } = await reader.read();
        if (done) break;

        buffer += decoder.decode(value, { stream: true });
        const lines = buffer.split("\n");
        buffer = lines.pop(); // keep incomplete last line

        for (const line of lines) {
          if (!line.startsWith("data: ")) continue;
          const payload = line.slice(6).trim();
          if (!payload) continue;

          try {
            const event = JSON.parse(payload);
            switch (event.type) {
              case "text":        onText?.(event.content); break;
              case "reasoning":   onReasoning?.(event.content); break;
              case "usage":       onUsage?.(event.usage); break;
              case "tool_start":  onToolStart?.(event.tools); break;
              case "tool_result": onToolResult?.(event); break;
              case "done":        onDone?.(); break;
              case "error":       onError?.(event.message); break;
            }
          } catch (_) {}
        }
      }
    } catch (err) {
      if (err.name !== "AbortError") {
        onError?.(err.message);
      }
    } finally {
      setIsStreaming(false);
    }
  }, [isStreaming]);

  const stopStream = useCallback(() => {
    controllerRef.current?.abort();
    setIsStreaming(false);
  }, []);

  return { startStream, stopStream, isStreaming };
}
```

---

## 19. Frontend — `package.json`

```json
{
  "name": "chatbot-web",
  "version": "1.0.0",
  "scripts": {
    "dev": "vite",
    "build": "vite build",
    "preview": "vite preview"
  },
  "dependencies": {
    "react": "^18.3.0",
    "react-dom": "^18.3.0",
    "react-markdown": "^9.0.0",
    "remark-gfm": "^4.0.0",
    "zustand": "^4.5.0",
    "lucide-react": "^0.400.0"
  },
  "devDependencies": {
    "@vitejs/plugin-react": "^4.3.0",
    "vite": "^5.3.0",
    "tailwindcss": "^3.4.0",
    "autoprefixer": "^10.4.0",
    "postcss": "^8.4.0"
  }
}
```

---

## 20. Docker Compose

```yaml
# docker-compose.yml
services:
  backend:
    build: ./backend
    restart: unless-stopped
    env_file: .env
    volumes:
      - chatbot_data:/data
    expose:
      - "8000"
    healthcheck:
      test: ["CMD", "curl", "-f", "http://localhost:8000/health"]
      interval: 30s
      timeout: 10s
      retries: 3
      start_period: 10s

  frontend:
    build: ./frontend
    restart: unless-stopped
    expose:
      - "80"
    depends_on:
      - backend

  nginx:
    image: nginx:alpine
    restart: unless-stopped
    ports:
      - "80:80"
      - "443:443"
    volumes:
      - ./nginx.conf:/etc/nginx/nginx.conf:ro
      - ./certs:/etc/nginx/certs:ro
    depends_on:
      - backend
      - frontend

volumes:
  chatbot_data:
```

### `backend/Dockerfile`

```dockerfile
FROM python:3.12-slim
WORKDIR /app
COPY requirements.txt .
RUN pip install --no-cache-dir -r requirements.txt
COPY . .
CMD ["uvicorn", "app.main:app", "--host", "0.0.0.0", "--port", "8000", "--workers", "1"]
```

> **Note**: Use `--workers 1` only. Multiple workers would share APScheduler state incorrectly.
> For concurrency, uvicorn's async event loop is sufficient.

### `frontend/Dockerfile`

```dockerfile
FROM node:20-alpine AS builder
WORKDIR /app
COPY package*.json .
RUN npm ci
COPY . .
RUN npm run build

FROM nginx:alpine
COPY --from=builder /app/dist /usr/share/nginx/html
COPY nginx-frontend.conf /etc/nginx/conf.d/default.conf
```

---

## 21. Nginx Configuration

```nginx
# nginx.conf
events { worker_connections 1024; }

http {
    upstream backend { server backend:8000; }
    upstream frontend { server frontend:80; }

    server {
        listen 443 ssl;
        server_name your-domain.com;

        ssl_certificate     /etc/nginx/certs/fullchain.pem;
        ssl_certificate_key /etc/nginx/certs/privkey.pem;
        ssl_protocols       TLSv1.2 TLSv1.3;

        # Frontend (React SPA)
        location / {
            proxy_pass http://frontend;
        }

        # Backend API
        location /api/ {
            proxy_pass http://backend;
            proxy_set_header Host $host;
            proxy_set_header X-Real-IP $remote_addr;
        }

        # SSE: MUST disable buffering, set long timeout
        location ~ ^/api/.+/chat$ {
            proxy_pass http://backend;
            proxy_set_header Host $host;
            proxy_buffering off;                 # critical for SSE
            proxy_cache off;
            proxy_read_timeout 300s;             # long timeout for streaming
            proxy_set_header X-Accel-Buffering no;
            proxy_set_header Connection '';
            proxy_http_version 1.1;
            chunked_transfer_encoding on;
        }

        location /health {
            proxy_pass http://backend;
        }
    }

    # HTTP → HTTPS redirect
    server {
        listen 80;
        return 301 https://$host$request_uri;
    }
}
```

---

## 22. Implementation Order (Recommended)

Execute in this sequence to have a working system at each step:

1. **Skeleton** — Docker Compose up with FastAPI `/health` returning `{"status":"ok"}` and
   React showing "Hello". Verify nginx SSE proxy works with a test endpoint.

2. **Database** — Run migrations, verify SQLite file persists in Docker volume.

3. **AI Streaming** (core) — Implement `api_service.py` (OpenAI + Anthropic + Gemini).
   Test via curl: `curl -N http://localhost/api/conversations/{id}/chat -d '{"message":"hi"}'`.
   Verify SSE tokens arrive in real-time (not buffered).

4. **Conversation CRUD** — `routers/conversations.py`. Test create/list/delete.

5. **Chat UI** — React chat view with `useSSEStream`. Get end-to-end streaming working in browser.

6. **Agent loop** — `agent_service.py`. Test with a simple echo tool.

7. **Settings + Providers** — API key storage in SQLite settings table, provider management.

8. **Chaoxing login** — Implement the OTP login flow. Test manually (real Chaoxing account needed).

9. **Chaoxing data fetch** — Assignments, messages, courses. Port from ChaoxingService.swift.

10. **Memory Agent** — Port extraction prompt from ChaoxingMemoryAgent.swift. Test on real data.

11. **Schedule Agent** — Wire up agentic loop with Chaoxing tools. Test schedule queries.

12. **APScheduler** — Add background sync jobs. Verify they run every 5 min.

13. **Push Notifications** — VAPID keys, service worker, pywebpush. Test on mobile Chrome/Safari.

14. **PWA** — manifest.json, service worker registration, iOS "Add to Home Screen" test.

15. **Settings UI** — API keys, provider config, push enable/disable toggle.

16. **Polish** — Loading states, error handling, empty states, mobile layout.

---

## 23. Critical Implementation Notes

### Chaoxing Session Persistence
The Chaoxing session must survive Docker restarts. Store serialized cookies in the
`chaoxing_session` table (not in memory only). On `ChaoxingService.init()`, reload cookies
and probe the session. If the probe fails, set `is_logged_in = False` and let the user
re-login via the Settings UI.

### SSE and Nginx Buffering
Without `proxy_buffering off` and `X-Accel-Buffering: no`, nginx will buffer the entire
SSE stream and the frontend will see nothing until the response ends. Both headers are
required. Also set `proxy_read_timeout` high enough for long AI responses.

### iOS Web Push Limitations
iOS 16.4+ requires the PWA to be installed to Home Screen for push to work.
Add a UI prompt (Settings page) explaining this to the user when `usePush.supported` is
false or `display-mode` is not `standalone`.

### SQLite Concurrency
Use `aiosqlite` with WAL mode: `await db.execute("PRAGMA journal_mode=WAL")` in migrations.
WAL allows concurrent reads during writes, preventing lock contention between the API
and APScheduler background jobs.

### VAPID Key Generation
Generate once and store in `.env`. Never regenerate after users have subscribed —
subscriptions are tied to the VAPID key pair.
```bash
npx web-push generate-vapid-keys
```

### API Key Security
Store API keys in the `.env` file (and `settings` table as a fallback).
The frontend should NEVER have direct access to API keys. All AI calls go through
the backend. The settings API (`PUT /api/settings`) accepts keys and stores them
in the `settings` table encrypted with Fernet if `SETTINGS_ENCRYPTION_KEY` is set.

### Multi-Agent Mode
Port `ChatViewModel+MultiAgent.swift`. The multi-agent loop sends the user's message to
N providers in parallel (`asyncio.gather`), then has a "judge" model synthesize the results.
Implement after single-agent streaming is stable.

### Context Window Compression
Port `buildCompressedChatPromptMessages()` from `ChatViewModel.swift`. When a conversation
exceeds the token limit, summarize older messages using a fast/cheap model and store
the summary in `conversations.context_summary`. This is critical for long-running conversations.

---

## 24. Data Flow Diagram

```
Mobile Browser (PWA)
       │
       │  HTTPS
       ▼
   Nginx (TLS termination, SSE proxy)
       │
       ├──── /api/*  ──────────►  FastAPI
       │                              │
       │  SSE stream                  ├── SQLite (aiosqlite)
       │  (text/event-stream)         │     conversations, messages,
       │                              │     settings, chaoxing_memory,
       │                              │     push_subscriptions
       │                              │
       │                              ├── httpx.AsyncClient (singleton)
       │                              │     ├── OpenAI API
       │                              │     ├── Anthropic API
       │                              │     ├── Gemini API
       │                              │     └── Chaoxing HTTP
       │                              │
       │                              └── APScheduler (AsyncIOScheduler)
       │                                    ├── chaoxing_probe (5min)
       │                                    ├── deadline_check (5min)
       │                                    └── daily_summary (08:00)
       │
       │  Web Push (VAPID)
       ◄── Push Service (GCM/APNs gateway)
              ▲
              │ pywebpush
              └── FastAPI push_service.py
```
