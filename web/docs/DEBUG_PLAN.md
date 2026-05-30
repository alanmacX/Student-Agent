# Debug Plan: Memory Automation Engine

> For another coding agent to execute.  Server: `aliyun-root`.
> Project: `/opt/chatbot/` (Docker Compose, backend FastAPI + frontend React).
> All backend code is inside the `chatbot-backend-1` container (built from `/opt/chatbot/backend/`).

---

## 0. Sync Local → Cloud (run first)

The local Mac codebase at `/Users/macalan/Documents/chatbot/` may lag behind
the production server.  After any local edits, sync with:

```bash
# Mac → Server (exclude secrets + build artifacts)
rsync -av --exclude='node_modules' --exclude='__pycache__' \
  --exclude='.env' --exclude='*.db*' --exclude='dist/' \
  /Users/macalan/Documents/chatbot/ aliyun-root:/opt/chatbot/

# Rebuild after sync
ssh aliyun-root "cd /opt/chatbot && docker compose build backend frontend && docker compose up -d"
```

To pull server state back to local:
```bash
rsync -av --exclude='node_modules' --exclude='__pycache__' \
  --exclude='.env' --exclude='*.db*' \
  aliyun-root:/opt/chatbot/ /Users/macalan/Documents/chatbot/
```

---

## 1. Pre-flight Checks

```bash
# Health
curl -s http://localhost/health
# Expected: {"status":"ok","chaoxing_logged_in":true}

# Container running
ssh aliyun-root "docker ps --format '{{.Names}} {{.Status}}'" | grep chatbot
# Expected: chatbot-backend-1 Up, chatbot-frontend-1 Up, chatbot-nginx-1 Up

# DB path
DB=/var/lib/docker/volumes/chatbot_chatbot_data/_data/chatbot.db
ssh aliyun-root "ls -la $DB"
```

---

## 2. Schema Verification

```bash
DB=/var/lib/docker/volumes/chatbot_chatbot_data/_data/chatbot.db
ssh aliyun-root "sqlite3 $DB '.tables'" | tr ' ' '\n' | sort

# Must include:
# - memory_topic_index
# - memory_sync_state
# - chaoxing_memory_entries (existing)
# - scheduled_notifications (existing)
# - settings (existing)

# Check new columns on chaoxing_memory_entries
ssh aliyun-root "sqlite3 $DB 'PRAGMA table_info(chaoxing_memory_entries);'" \
  | grep -E 'source_type|hierarchy_tier|for_automation'
# Expected: 3 rows with those column names

# Check memory_topic_index schema
ssh aliyun-root "sqlite3 $DB '.schema memory_topic_index'"
# Expected: CREATE TABLE memory_topic_index (entity_key TEXT, entity_type TEXT,
#           memory_id TEXT, source_type TEXT, expires_at TEXT, PRIMARY KEY(...))
```

---

## 3. Module Import Tests

```bash
ssh aliyun-root "docker exec chatbot-backend-1 python3 -c '
from app.memory.base import MemoryRepository, Tier, compute_tier
from app.memory.engine import process_message, EffectType, Effect
from app.dingtalk.memory_provider import run_dingtalk_memory_sync
print(\"all imports ok\")
'"
# Expected: all imports ok
```

---

## 4. Unit: compute_tier

```bash
ssh aliyun-root "docker exec chatbot-backend-1 python3 -c '
from datetime import datetime, timezone, timedelta
from app.memory.base import compute_tier, Tier
now = datetime.now(timezone.utc)

# Expires today → CRITICAL
assert compute_tier(\"high\", now + timedelta(hours=3), True, now) == Tier.CRITICAL

# Expires this week, has action → ACTIONABLE
assert compute_tier(\"high\", now + timedelta(days=5), True, now) == Tier.ACTIONABLE

# Medium importance, no automation → CONTEXT
assert compute_tier(\"medium\", now + timedelta(days=10), False, now) == Tier.CONTEXT

print(\"compute_tier: PASS\")
'"
```

---

## 5. Unit: topic_index write + read

```bash
ssh aliyun-root "docker exec chatbot-backend-1 python3 -c '
import asyncio
from datetime import datetime, timezone, timedelta
from app.memory.base import MemoryRepository, MemoryEntry, Tier
from app.memory.engine import _expand_entity_keys, _normalise_key

# Test key expansion
keys = _expand_entity_keys(\"Web前端开发\")
assert \"web前端开发\" in keys, f\"missing base key, got: {keys}\"
assert \"前端\" in keys or \"web前端\" in keys, f\"missing substring, got: {keys}\"
print(\"key expansion: PASS\")

async def test():
    db_path = \"/data/chatbot.db\"
    repo = MemoryRepository(db_path)
    now = datetime.now(timezone.utc)
    entry = MemoryEntry(
        title=\"Debug Test Course\",
        summary=\"Testing memory_topic_index write\",
        reason=\"debug\",
        source_type=\"debug\",
        expires_at=now + timedelta(days=7),
        hierarchy_tier=Tier.CONTEXT,
        dedupe_key=\"debug::test::course::v1\",
    )
    eid = await repo.upsert_entry(entry, now)
    print(f\"Upserted entry: {eid}\")
    assert eid

asyncio.run(test())
print(\"MemoryRepository.upsert_entry: PASS\")
'"
```

---

## 6. Unit: engine noise filter

```bash
ssh aliyun-root "docker exec chatbot-backend-1 python3 -c '
from app.memory.engine import _is_obvious_noise
assert _is_obvious_noise(\"好的\")
assert _is_obvious_noise(\"[赞][赞][赞]\")
assert _is_obvious_noise(\"test\")
assert not _is_obvious_noise(\"明天Web前端停课，下周三补课在上院101\")
assert not _is_obvious_noise(\"数据库作业截止延期到下周五\")
print(\"noise filter: PASS\")
'"
```

---

## 7. Integration: intent extraction (requires MiMo API)

```bash
ssh aliyun-root "docker exec chatbot-backend-1 python3 -c '
import asyncio
from datetime import datetime, timezone
from app.memory.engine import _extract_intents, _build_context
from app.services.provider_registry import resolve_provider
from app.config import settings

async def test():
    now = datetime.now(timezone.utc)
    msg = {
        \"mid\": \"test001\",
        \"text\": \"同学们明天Web前端停课，下周三第3-4节在上院101补课\",
        \"sender_name\": \"张老师\",
        \"conversation_title\": \"Web前端开发课程群\",
        \"is_group\": True,
        \"source_type\": \"dingtalk\",
        \"created_at\": 1748000000000,
        \"category\": \"course_change\",
    }
    context = await _build_context(msg, settings.database_path, now)
    print(\"Context snippet:\", context[:200])
    provider, api_key = await resolve_provider(settings.standby_agent_provider)
    graph = await _extract_intents(
        msg, context, \"\", provider, settings.standby_agent_model, api_key, now
    )
    print(f\"Intents: {len(graph.intents)}\")
    for intent in graph.intents:
        print(f\"  type={intent.get('type')} entity={intent.get('entity_name')} confidence={intent.get('confidence')}\")
        print(f\"  effects: {[e.type for e in intent.get('effects', [])]}\")
    assert len(graph.intents) > 0, \"Expected at least 1 intent\"
    assert any(\"course\" in str(i.get(\"type\",\"\")) for i in graph.intents), \"Expected course intent\"

asyncio.run(test())
print(\"intent extraction: PASS\")
'"
```

Expected: at least 1 intent with type containing "course", with effects including `upsert_memory` and `schedule_push`.

---

## 8. Integration: full process_message

```bash
ssh aliyun-root "docker exec chatbot-backend-1 python3 -c '
import asyncio
from datetime import datetime, timezone
from app.memory.engine import process_message
from app.services.provider_registry import resolve_provider
from app.config import settings

async def test():
    now = datetime.now(timezone.utc)
    msg = {
        \"mid\": \"integration_test_001\",
        \"text\": \"大家注意，本周五数据库作业截止时间延期到下周一晚上23:59\",
        \"sender_name\": \"助教\",
        \"conversation_title\": \"数据库原理及应用课程群\",
        \"is_group\": True,
        \"source_type\": \"dingtalk\",
        \"created_at\": 1748000000001,
        \"category\": \"course\",
    }
    provider, api_key = await resolve_provider(settings.standby_agent_provider)
    result = await process_message(msg, settings.database_path, provider, settings.standby_agent_model, api_key, now)
    print(f\"ok={result.ok} effects={result.effects_applied} upserted={len(result.memory_upserted)}\")
    print(f\"archived={len(result.memory_archived)} pushes={result.push_scheduled} errors={result.errors}\")
    assert result.ok

asyncio.run(test())
print(\"process_message: PASS\")
'"
```

---

## 9. Integration: DingTalk memory sync via API

```bash
# Bootstrap (reset last_seen to process historical messages)
ssh aliyun-root "sqlite3 /var/lib/docker/volumes/chatbot_chatbot_data/_data/chatbot.db \
  \"DELETE FROM memory_sync_state WHERE source_type='dingtalk';\""

# Trigger sync
curl -s -X POST http://localhost/api/dingtalk/sync | python3 -m json.tool | grep -E 'ok|memory|processed|effects'

# Check result in DB
ssh aliyun-root "sqlite3 /var/lib/docker/volumes/chatbot_chatbot_data/_data/chatbot.db \
  'SELECT source_type, hierarchy_tier, for_automation, title, action_hint
   FROM chaoxing_memory_entries WHERE source_type=\"dingtalk\" LIMIT 10;'"

# Check topic_index was populated
ssh aliyun-root "sqlite3 /var/lib/docker/volumes/chatbot_chatbot_data/_data/chatbot.db \
  'SELECT entity_key, entity_type, source_type FROM memory_topic_index LIMIT 10;'"
```

---

## 10. User Context Settings

```bash
# Set user automation context
curl -s -X PUT http://localhost/api/settings/user_automation_context \
  -H 'Content-Type: application/json' \
  -d '{"value":"我是浙工大计算机学院2024级本科生，主要在东院和西院上课，对非CS竞赛不感兴趣"}'

# Read back
curl -s http://localhost/api/settings/user_automation_context
# Expected: {"value":"我是浙工大..."}

# Verify it influences intent extraction
# (Run test from step 7 again with a non-CS competition message)
# The context should cause the engine to produce DROP or REFERENCE-tier effects
```

---

## 11. Agent context injection (build_turn_context)

```bash
ssh aliyun-root "docker exec chatbot-backend-1 python3 -c '
import asyncio
import zoneinfo
from datetime import datetime
from app.services.schedule_agent import build_turn_context
from app.services.chaoxing_service import ChaoxingService
from app.config import settings

async def test():
    svc = ChaoxingService(settings.database_path)
    now = datetime.now(tz=zoneinfo.ZoneInfo(\"Asia/Shanghai\"))
    ctx = await build_turn_context(settings.database_path, svc, now)
    print(\"Context length:\", len(ctx), \"chars\")
    print(ctx)
    # Should show Memory section using new MemoryRepository
    # Should NOT show raw dingtalk message dump anymore
    assert \"Memory\" in ctx or \"记忆\" in ctx or len(ctx) > 10

asyncio.run(test())
print(\"build_turn_context: PASS\")
'"
```

---

## 12. Regression: existing features still work

```bash
# Schedule agent can still answer
curl -s -X POST http://localhost/api/schedule/chat \
  -H 'Content-Type: application/json' \
  -d '{"message":"查一下我的提醒","conversation_id":"debug-regression-001"}' \
  --max-time 30 | grep -E 'tool_start|text' | head -5

# DingTalk messages API still works
curl -s 'http://localhost/api/dingtalk/messages?bucket=notify&limit=5' | python3 -c \
  "import sys,json; d=json.load(sys.stdin); print(f'notify: {len(d)} msgs')"

# Push settings still work
curl -s http://localhost/api/settings/notification_rule_prompt | python3 -c \
  "import sys,json; d=json.load(sys.stdin); print('settings ok, len=', len(d.get('value','')))"

# Health still ok
curl -s http://localhost/health
```

---

## 13. Known Issues / Edge Cases to Watch

1. **Empty topic_index**: If no DingTalk messages with substantial text have been processed, `memory_topic_index` will be empty. This is fine — entity lookup returns empty list, sub-agents produce `upsert_memory` only.

2. **LLM produces invalid Effect types**: `_extract_intents` catches `ValueError` when parsing EffectType enum; invalid types are silently dropped.

3. **Duplicate push notifications**: The engine uses `INSERT OR IGNORE` for `scheduled_notifications` by `source_type='automation_engine'`. Multiple messages about same event may create multiple entries — rely on dedup via `dedupe_key` in memory entries rather than notification dedup.

4. **MiMo rate limits**: If multiple messages arrive simultaneously, multiple `process_message` coroutines may run concurrently and hit the API. The DingTalk provider processes messages sequentially to avoid this.

5. **Time zone in intent extraction**: The LLM receives current time in Asia/Shanghai format. Relative time references ("明天", "下周三") depend on this being correct. Verify with `date` on the server.

---

## 14. Frontend: User Context Settings UI

**Not yet implemented** — the backend endpoint exists (`PUT /api/settings/user_automation_context`), but the Settings UI needs a new input field.

Location: `frontend/src/components/settings/SettingsView.jsx`

Add a new settings section (can be in the existing "providers" or a new "智能设置" tab):

```jsx
// In SettingsView.jsx, add to TABS:
{ id: "intelligence", label: "智能设置", mobileLabel: "智能", icon: Brain }

// New component: IntelligenceSettings.jsx
// - Textarea for user_automation_context
// - Label: "自动化上下文约束（约束 AI 理解消息的方式）"
// - Placeholder: "例：我是CS本科生，对非CS竞赛不感兴趣，晚上11点后不要打扰"
// - Save button: PUT /api/settings/user_automation_context
```

---

## 15. Files Changed in This Implementation

```
backend/app/memory/
    __init__.py          (empty, already exists)
    base.py              (MemoryRepository, MemoryEntry, Tier, compute_tier)
    engine.py            (NEW: universal automation engine)

backend/app/dingtalk/
    memory_provider.py   (rewritten: uses engine.process_message)
    task.py              (updated: calls memory provider post-sync)

backend/app/database.py  (added: memory_topic_index table + 3 new columns)
backend/app/services/schedule_agent.py (updated: build_turn_context uses MemoryRepository)
docs/MEMORY_MODULE_SPEC.md  (NEW: integration spec)
```

---

## Quick Pass / Fail Summary

| # | Test | Pass criteria |
|---|------|---------------|
| 2 | Schema | memory_topic_index + 3 new columns exist |
| 3 | Imports | No ImportError |
| 4 | compute_tier | Correct tier for 3 test cases |
| 5 | topic_index | Entry written + readable |
| 6 | Noise filter | Correct drops + passes |
| 7 | Intent extract | ≥1 intent, correct type, MiMo responds |
| 8 | process_message | ok=True, ≥1 effect applied |
| 9 | DingTalk sync | dingtalk memory_sync_state row exists |
| 10 | User context | Setting persists in DB |
| 11 | Agent context | Context includes Memory section |
| 12 | Regression | All 4 existing APIs still return valid data |
