# Memory Module Integration Spec

> Reference document for adding new memory source modules to the chatbot.
> The automation engine (`app/memory/engine.py`) is fully generic —
> new modules plug in by providing a normalised message dict.

---

## Architecture Overview

```
Source Module (DingTalk / Chaoxing / Ideas / Shopping / ...)
    ↓  normalise raw data → NormalisedMessage dict
app/memory/engine.process_message()
    ↓  context build (SQL)
    ↓  intent extract (1 LLM call)
    ↓  parallel sub-agents (SQL only)
    ↓  effect merge
    ↓  effect execute (SQL transaction)
    → chaoxing_memory_entries updated
    → memory_topic_index updated
    → scheduled_notifications written
```

---

## Adding a New Source Module

### Step 1: Create `app/features/<name>/memory_provider.py`

Minimum required:

```python
from app.memory.engine import process_message, NormalisedMessage

SOURCE_TYPE = "my_source"  # unique string

def _normalise(raw: dict) -> NormalisedMessage:
    return {
        "mid": str(raw["id"]),                     # unique message id
        "text": raw.get("content") or "",          # message text (required)
        "sender_name": raw.get("author") or "",
        "conversation_title": raw.get("channel") or "",
        "is_group": bool(raw.get("is_group")),
        "source_type": SOURCE_TYPE,
        "created_at": int(raw.get("timestamp") or 0),  # milliseconds
        "category": raw.get("category") or "",
    }

async def run_sync(db_path, provider, model, api_key, now=None):
    # 1. Fetch raw data from your source
    raw_items = await fetch_your_data(since_ts)

    # 2. Process each through the engine
    for item in raw_items:
        await process_message(_normalise(item), db_path, provider, model, api_key, now)

    # 3. Update memory_sync_state
    # INSERT OR REPLACE INTO memory_sync_state (source_type, last_synced_ts, ...) VALUES (...)
```

### Step 2: Wire into the scheduler (`app/tasks/scheduler.py`)

```python
scheduler.add_job(
    run_your_sync_wrapper,
    IntervalTrigger(seconds=300),
    args=[app_state],
    id="your_source_memory_sync",
    max_instances=1,
    coalesce=True,
)
```

### Step 3: Done

The engine handles:
- Intent extraction (time-aware, conflict-detecting)
- Effect execution (upsert memory, archive, push, schedule)
- topic_index maintenance
- User context constraints

---

## NormalisedMessage Schema

| Field | Type | Required | Notes |
|-------|------|----------|-------|
| `mid` | str | ✓ | Unique message identifier |
| `text` | str | ✓ | Message text content |
| `sender_name` | str | | Display name of sender |
| `conversation_title` | str | | Chat/channel name (empty for DMs) |
| `is_group` | bool | | True if group chat |
| `source_type` | str | ✓ | Registered source identifier |
| `created_at` | int | | Unix timestamp in **milliseconds** |
| `category` | str | | Pre-classified category hint (optional) |
| `verdict` | str | | Pre-filter result (optional, e.g. 'notify') |

---

## Effect Types

The LLM produces a list of effects; the executor is generic.
New effect types can be added to `EffectType` enum + handled in `_execute_effects`.

| Effect | What it does |
|--------|-------------|
| `upsert_memory` | Create/update a `chaoxing_memory_entries` row |
| `archive_memory` | Soft-delete matching memory entries |
| `push_now` | Immediate Web Push notification |
| `schedule_push` | Write to `scheduled_notifications` for deferred push |
| `link_entries` | Cross-reference two memory entries |

---

## User Automation Context

Stored in `settings` table as `key='user_automation_context'`.
Free-form text prepended to every intent extraction prompt.

Examples:
- `"我是浙工大计算机学院2024级本科生，教室常在东院和西院"`
- `"我对非CS方向的竞赛不感兴趣"`
- `"我晚上11点睡觉"`

Readable via `GET /api/settings/user_automation_context`
Writable via `PUT /api/settings/user_automation_context` with `{"value": "..."}`

---

## Topic Index

Written automatically by the engine when memory entries are upserted.
Used by sub-agents for O(1) entity lookup (no full-table scan).

```sql
-- Table: memory_topic_index
entity_key   TEXT  -- normalised entity name (lowercase, no punctuation)
entity_type  TEXT  -- 'course' | 'assignment' | 'general' | ...
memory_id    TEXT  -- FK → chaoxing_memory_entries.id
source_type  TEXT
expires_at   TEXT
PRIMARY KEY (entity_key, memory_id)
```

Multiple keys are written per entry (full name, substrings, CJK bigrams).
Query example:
```sql
SELECT m.* FROM chaoxing_memory_entries m
JOIN memory_topic_index t ON t.memory_id = m.id
WHERE t.entity_key = 'web前端开发' AND m.archived_at IS NULL
```

---

## Scheduled Follow-ups

The engine writes to `scheduled_notifications` (existing table).
The `check_scheduled_notifications` job (runs every minute) handles delivery.
No new tables or jobs needed.

```python
# Engine writes this automatically when LLM produces schedule_push effect:
INSERT INTO scheduled_notifications
  (id, title, body, scheduled_at, source_type, reason, created_at)
  VALUES (uuid, "补课提醒", "去上院101", "2026-06-10T08:30:00Z",
          "automation_engine", "memory automation", now)
```

---

## Memory Hierarchy Tiers

| Tier | Name | Criteria | Context injection |
|------|------|----------|-------------------|
| 0 | CRITICAL | expires today OR explicit urgent flag | Always |
| 1 | ACTIONABLE | expires this week + has action_hint | Always |
| 2 | CONTEXT | background info, no immediate action | Keyword-matched |
| 3 | REFERENCE | ideas, notes, long-term | On-demand tool call |
| 4 | HISTORICAL | compressed summaries | Archive only |

Computed by `compute_tier(importance, expires_at, for_automation, now)` in `base.py`.
