# ChatBot — Agent QA Playbook

> **你是一个自主修复 agent。你的任务是：对每个功能块执行 check，判断是否 pass，不 pass 就修代码、部署、重新 check，直到所有模块全部 pass。**
>
> 不要跳过任何 check。不要只修代码不验证。每个模块都要最终输出 PASS 或 FAIL。

---

## 环境信息

### 本地代码
```
/Users/macalan/Documents/chatbot/web/
├── backend/app/          ← Python 后端
└── frontend/             ← React 前端
    └── public/sw.js      ← Service Worker
```

### 服务器连接
SSH alias 已配置，直接用：
```bash
ssh aliyun-root "echo ok"   # 应输出 ok
```

服务器应用目录：`/opt/chatbot/`
数据库：`/data/chatbot.db`（容器内路径）

### 查日志
```bash
ssh aliyun-root "docker logs chatbot-backend-1 --tail 50 2>&1"
```

### 查数据库（模板，按需修改 SQL）
```bash
ssh aliyun-root 'docker exec chatbot-backend-1 python3 -c "
import sqlite3
db = sqlite3.connect(\"/data/chatbot.db\")
db.row_factory = sqlite3.Row
rows = db.execute(\"SELECT * FROM notification_log ORDER BY sent_at DESC LIMIT 5\").fetchall()
for r in rows: print(dict(r))
"'
```

### 部署（每次改代码后执行）
```bash
# 后端
rsync -az --exclude='__pycache__' --exclude='*.pyc' -e ssh \
  /Users/macalan/Documents/chatbot/web/backend/app/ \
  aliyun-root:/opt/chatbot/backend/app/
ssh aliyun-root "cd /opt/chatbot && docker compose build backend && docker compose up -d --force-recreate backend"

# 前端（改了 sw.js 或 JSX 时）
rsync -az --exclude='node_modules' --exclude='dist' -e ssh \
  /Users/macalan/Documents/chatbot/web/frontend/ \
  aliyun-root:/opt/chatbot/frontend/
ssh aliyun-root "cd /opt/chatbot && docker compose build frontend && docker compose up -d --force-recreate frontend"

# 验证启动
ssh aliyun-root "docker logs chatbot-backend-1 --tail 10 2>&1"
# 必须看到 "Application startup complete." 且无 ERROR/Traceback
```

---

## Module 1 — Push 推送队列

**功能描述**：用户通过 Schedule Agent 安排通知，写入 `scheduled_notifications` 表，后台每分钟扫一次，到时间就通过 Web Push 发到手机。

### Check 1-A：scheduled_notifications 时区是否统一为 UTC

运行：
```bash
ssh aliyun-root 'docker exec chatbot-backend-1 python3 -c "
import sqlite3
from datetime import datetime, timezone, timedelta
db = sqlite3.connect(\"/data/chatbot.db\")

# 插入一条测试通知（2分钟后，UTC格式）
import uuid
nid = str(uuid.uuid4())
fire_at = (datetime.now(timezone.utc) + timedelta(minutes=2)).isoformat()
now = datetime.now(timezone.utc).isoformat()
db.execute(\"INSERT INTO scheduled_notifications (id,title,body,scheduled_at,source_id,source_type,reason,created_at) VALUES (?,?,?,?,?,?,?,?)\",
    (nid, \"Check 1-A\", \"timezone test\", fire_at, nid, \"debug\", \"qa\", now))
db.commit()

# 验证 check_scheduled_notifications 能查到它
rows = db.execute(\"SELECT id, scheduled_at FROM scheduled_notifications WHERE sent_at IS NULL AND cancelled_at IS NULL AND scheduled_at <= ?\", (datetime.now(timezone.utc).isoformat(),)).fetchall()
print(\"Rows due NOW:\", rows)

# 查刚插入的
r = db.execute(\"SELECT id, scheduled_at FROM scheduled_notifications WHERE id=?\", (nid,)).fetchone()
print(\"Inserted:\", dict(zip([\"id\",\"scheduled_at\"], r)))
print(\"scheduled_at ends with +00:00 or Z:\", r[1].endswith(\"+00:00\") or r[1].endswith(\"Z\"))
"'
```

**PASS 条件**：输出中 `scheduled_at ends with +00:00 or Z: True`

**如果 FAIL**：`app/services/schedule_agent.py` 里 `schedule_notification` 工具写入前没有转 UTC。找到 INSERT 语句前，加：
```python
_sch = datetime.fromisoformat(scheduled_at_str)
if _sch.tzinfo is None:
    _sch = _sch.replace(tzinfo=zoneinfo.ZoneInfo("Asia/Shanghai"))
scheduled_at_str = _sch.astimezone(timezone.utc).isoformat()
```

---

### Check 1-B：定时通知能否在到期后 2 分钟内被自动发出

先清理 Check 1-A 插入的测试数据，再插入一条 1 分钟后的通知，等待，检查 sent_at：

```bash
# 清理 debug 数据
ssh aliyun-root 'docker exec chatbot-backend-1 python3 -c "
import sqlite3
db = sqlite3.connect(\"/data/chatbot.db\")
db.execute(\"DELETE FROM scheduled_notifications WHERE source_type=\\'debug\\'\")
db.commit()
print(\"cleaned\")
"'

# 插入 1 分钟后的通知
ssh aliyun-root 'docker exec chatbot-backend-1 python3 -c "
import sqlite3, uuid
from datetime import datetime, timezone, timedelta
db = sqlite3.connect(\"/data/chatbot.db\")
nid = str(uuid.uuid4())
fire_at = (datetime.now(timezone.utc) + timedelta(minutes=1)).isoformat()
db.execute(\"INSERT INTO scheduled_notifications (id,title,body,scheduled_at,source_id,source_type,reason,created_at) VALUES (?,?,?,?,?,?,?,?)\",
    (nid, \"Check 1-B\", \"fire test\", fire_at, nid, \"debug\", \"qa\", datetime.now(timezone.utc).isoformat()))
db.commit()
print(\"id:\", nid)
print(\"fires_at:\", fire_at)
"'
```

等待 90 秒，然后检查：
```bash
ssh aliyun-root 'docker exec chatbot-backend-1 python3 -c "
import sqlite3
db = sqlite3.connect(\"/data/chatbot.db\")
db.row_factory = sqlite3.Row
rows = db.execute(\"SELECT id, title, scheduled_at, sent_at FROM scheduled_notifications WHERE source_type=\\'debug\\'\").fetchall()
for r in rows: print(dict(r))
"'
```

**PASS 条件**：`sent_at` 非 NULL

**如果 FAIL**：
- 检查 `check_scheduled_notifications` 的 SQL 查询：`scheduled_at <= ?` 两边是否都是 UTC 格式字符串
- 检查 scheduler 是否在运行：`ssh aliyun-root "docker logs chatbot-backend-1 --tail 100 2>&1 | grep scheduled"`
- 检查是否有 push_subscriptions：`SELECT COUNT(*) FROM push_subscriptions` — 如果为 0，通知发出但 attempted=0

---

### Check 1-C：has_notified 去重是否正确（不能在 24h 内重复推同一事件）

```bash
ssh aliyun-root 'docker exec chatbot-backend-1 python3 -c "
import asyncio, sys
sys.path.insert(0, \"/app\")
from app.services.push_service import has_notified, log_notification_sent
from app.config import settings

async def test():
    # 插一条记录
    await log_notification_sent(settings.database_path, \"test-dedup-001\", \"test_type\")
    
    # 立刻查，应该返回 True（已通知，不重发）
    result = await has_notified(settings.database_path, \"test-dedup-001\", \"test_type\")
    print(\"has_notified right after log:\", result)  # 期望 True
    
    # 不同 notif_type，应该返回 False
    result2 = await has_notified(settings.database_path, \"test-dedup-001\", \"other_type\")
    print(\"has_notified different type:\", result2)  # 期望 False

asyncio.run(test())
"'
```

**PASS 条件**：第一行 `True`，第二行 `False`

**如果 FAIL**：检查 `app/services/push_service.py` 的 `has_notified` 函数，datetime 比较是否 timezone-aware：
```python
# 修法：
sent_at = datetime.fromisoformat(row[0])
if sent_at.tzinfo is None:
    sent_at = sent_at.replace(tzinfo=timezone.utc)
return datetime.now(timezone.utc) - sent_at < timedelta(hours=24)
```

清理测试数据：
```bash
ssh aliyun-root 'docker exec chatbot-backend-1 python3 -c "
import sqlite3
db = sqlite3.connect(\"/data/chatbot.db\")
db.execute(\"DELETE FROM notification_log WHERE item_id LIKE \\'test-dedup%\\'\")
db.execute(\"DELETE FROM scheduled_notifications WHERE source_type=\\'debug\\'\")
db.commit()
"'
```

---

## Module 2 — Chaoxing 学习通会话

**功能描述**：服务端用 HTTP cookie 维持学习通登录状态，定期拉取消息和作业，写入 memory 和提醒。

### Check 2-A：重启后会话是否保持

```bash
# 重启 backend
ssh aliyun-root "docker restart chatbot-backend-1"
sleep 10

# 检查 health
ssh aliyun-root 'docker exec chatbot-backend-1 python3 -c "
import urllib.request, json
r = urllib.request.urlopen(\"http://localhost:8000/health\")
data = json.loads(r.read())
print(data)
print(\"PASS\" if data.get(\"chaoxing_logged_in\") else \"FAIL: chaoxing not logged in after restart\")
"'
```

**PASS 条件**：`chaoxing_logged_in: true`

**如果 FAIL**：
- 检查 `chaoxing_session` 表是否有 uid：`SELECT uid, username FROM chaoxing_session WHERE id=1`
- 如果 uid 存在但还是 False，说明 `_probe_session` 把会话误判为死亡
- 检查 `app/services/chaoxing_service.py` 的 `_probe_session` 方法：非 JSON 响应（HTML redirect）时是否正确返回 `self.uid is not None`
- 加一个二次验证：probe 收到 HTML 时，用 `/api/check` 以外的轻量接口再验一次

**修法**（如果 probe 误杀会话）：
```python
# 在 _probe_session 的 except json decode 分支里：
except Exception:
    log.warning(f"Chaoxing probe: non-JSON (HTTP {resp.status_code}), keeping stored session")
    return self.uid is not None  # 有 uid 就信任，不要标记为掉线
```

---

### Check 2-B：作业列表能否正常拉取（前提：2-A PASS）

```bash
ssh aliyun-root 'docker exec chatbot-backend-1 python3 -c "
import asyncio, sys
sys.path.insert(0, \"/app\")
from app.main import app

async def test():
    svc = app.state.chaoxing_svc
    print(\"is_logged_in:\", svc.is_logged_in)
    if not svc.is_logged_in:
        print(\"SKIP: not logged in\")
        return
    assignments = await svc.fetch_all_pending_assignments()
    print(f\"assignments count: {len(assignments)}\")
    print(\"PASS\" if isinstance(assignments, list) else \"FAIL\")

asyncio.run(test())
"'
```

**PASS 条件**：`assignments count: N`（N >= 0，且是 list）

**如果 FAIL**：看具体报错，可能是 cookie 失效或网络超时。

---

## Module 3 — Schedule Agent 对话

**功能描述**：用户在 Agent tab 对话，agent 能管理提醒、日历、安排推送通知，对话按 session 隔离。

### Check 3-A：schedule_sessions 表有 'default' 行（历史消息可见）

```bash
ssh aliyun-root 'docker exec chatbot-backend-1 python3 -c "
import sqlite3
db = sqlite3.connect(\"/data/chatbot.db\")
row = db.execute(\"SELECT id, title FROM schedule_sessions WHERE id=\\'default\\'\").fetchone()
print(\"default session exists:\", row is not None)
print(\"PASS\" if row else \"FAIL\")
"'
```

**PASS 条件**：`default session exists: True`

**如果 FAIL**：在 `app/database.py` 的 `run_migrations()` 函数末尾，在最后一个 `await db.commit()` 之前加：
```python
await db.execute("""
    INSERT OR IGNORE INTO schedule_sessions (id, title, created_at, updated_at)
    VALUES ('default', '默认对话', datetime('now'), datetime('now'))
""")
```
然后部署，重新 check。

---

### Check 3-B：schedule_notification 工具直接写入，无需二次确认

通过 HTTP API 直接模拟一次 agent 工具调用：
```bash
ssh aliyun-root 'docker exec chatbot-backend-1 python3 -c "
import asyncio, sys, json
sys.path.insert(0, \"/app\")
from app.services.schedule_agent import _execute_schedule_tool
from app.services.agent_service import ToolCall
from app.config import settings
import sqlite3
from datetime import datetime, timezone, timedelta

async def test():
    # 清旧测试数据
    db = sqlite3.connect(settings.database_path)
    db.execute(\"DELETE FROM scheduled_notifications WHERE source_type=\\'user\\' AND reason IS NULL\")
    db.commit()
    
    fire_at = (datetime.now(timezone.utc) + timedelta(hours=1)).isoformat()
    tc = ToolCall(id=\"test\", name=\"schedule_notification\", arguments={
        \"title\": \"Check 3-B\",
        \"body\": \"confirmation flow test\",
        \"scheduled_at\": fire_at,
    })
    # 用非确认词触发，如果还有确认流程会返回 '需要用户确认'
    result = await _execute_schedule_tool(tc, None, settings.database_path, \"帮我安排通知\")
    print(\"result:\", result)
    parsed = json.loads(result)
    print(\"PASS\" if parsed.get(\"ok\") else \"FAIL: got confirmation flow or error\")
    
    # 清理
    if parsed.get(\"id\"):
        db = sqlite3.connect(settings.database_path)
        db.execute(\"DELETE FROM scheduled_notifications WHERE id=?\", (parsed[\"id\"],))
        db.commit()

asyncio.run(test())
"'
```

**PASS 条件**：result 是 `{"ok": true, "id": "..."}` 之类，不包含"需要用户确认"

**如果 FAIL**：`app/services/schedule_agent.py` 里 `schedule_notification` 分支还有 `_require_confirmation` 调用，删掉它。

---

### Check 3-C：历史消息有条数限制（防止 context 无限增长）

```bash
ssh aliyun-root 'docker exec chatbot-backend-1 python3 -c "
# 检查 schedule.py 里 history 查询是否有 LIMIT
import subprocess
result = subprocess.run(
    [\"grep\", \"-n\", \"SELECT.*schedule_messages.*ORDER\", \"/app/app/routers/schedule.py\"],
    capture_output=True, text=True
)
print(result.stdout)
"'
```

手动检查输出的 SQL 是否有 `LIMIT 40` 或类似限制。

**PASS 条件**：history 查询有 `LIMIT`（建议 40）

**如果 FAIL**：在 `app/routers/schedule.py` 的 `stream_schedule_chat` 里，把 history 查询改为：
```python
history_rows = await (await db.execute(
    """SELECT role, content FROM schedule_messages
       WHERE session_id=? ORDER BY position DESC LIMIT 40""",
    (session_id,),
)).fetchall()
history = list(reversed([dict(r) for r in history_rows]))
```

---

## Module 4 — Agent Pipeline（agentic loop + streaming）

**功能描述**：`run_agentic_loop` 支持多轮工具调用，结果 SSE 流式传给前端。

### Check 4-A：工具调用链能正确完成（不 crash，不超时）

```bash
ssh aliyun-root 'docker exec chatbot-backend-1 python3 -c "
import asyncio, sys
sys.path.insert(0, \"/app\")
from app.services.agent_service import run_agentic_loop, AgentMsg, ToolDefinition, ToolCall
from app.services.provider_registry import resolve_provider

async def test():
    provider, api_key = await resolve_provider(\"openai\")
    if not api_key:
        # fallback to mimo
        provider, api_key = await resolve_provider(\"xiaomimimo\")
    
    model = (provider.get(\"models\") or [\"gpt-4o-mini\"])[0]
    
    echo_tool = ToolDefinition(
        name=\"echo\",
        description=\"Echo back the input\",
        input_schema={\"type\":\"object\",\"properties\":{\"text\":{\"type\":\"string\"}},\"required\":[\"text\"]}
    )
    
    async def executor(tc):
        return f\"echoed: {tc.arguments.get(\"text\", \"\")}\"
    
    messages = [
        AgentMsg(role=\"system\", content=\"You must call the echo tool with text=hello, then respond.\"),
        AgentMsg(role=\"user\", content=\"Please echo hello.\"),
    ]
    
    events = []
    async for event in run_agentic_loop(messages, [echo_tool], executor, provider, model, api_key):
        events.append(event)
        print(event[\"type\"], event.get(\"content\", \"\")[:50])
    
    has_tool_start = any(e[\"type\"] == \"tool_start\" for e in events)
    has_text = any(e[\"type\"] == \"text\" for e in events)
    print(\"PASS\" if has_tool_start and has_text else \"FAIL\")

asyncio.run(test())
"'
```

**PASS 条件**：看到 `tool_start`、`tool_result`、`text` 事件，最后输出 `PASS`

**如果 FAIL**：检查 `app/services/agent_service.py` 的 `run_agentic_loop` 和 `_openai_agent_complete`，看 API 调用是否报错，是否有 key 配置问题。

---

### Check 4-B：fetch_url 结果不超过 8KB 进入 LLM context

```bash
grep -n "max_chars\|text\[:.*\]\|220000\|8000" \
  /Users/macalan/Documents/chatbot/web/backend/app/routers/chat.py \
  /Users/macalan/Documents/chatbot/web/backend/app/services/agent_service.py
```

**PASS 条件**：`chat.py` 里 `fetch_url` 的 `resp.text` 截断值 ≤ 8000 字符

**如果 FAIL**：把 `chat.py` 里 `fetch_url` 的截断改为：
```python
text = resp.text[:8000]
```

---

## Module 5 — 前端 Service Worker

**功能描述**：SW 接收 push 后展示通知，并回调服务端确认到达（`device_received_at`）。

### Check 5-A：SW push 事件后是否调用 /api/push/received

```bash
# 检查 sw.js 的 push handler 结构
grep -A 20 "addEventListener.*push" \
  /Users/macalan/Documents/chatbot/web/frontend/public/sw.js
```

**PASS 条件**：`fetch("/api/push/received"...)` 和 `showNotification(...)` 在 `Promise.all([...])` 里并行，**不是** `.then()` 链式调用

**如果 FAIL**：`showNotification()` 返回 `undefined`，`.then()` 会 TypeError 导致 fetch 永远不执行。修法：
```js
event.waitUntil(
  Promise.all([
    self.registration.showNotification(title, options),
    fetch("/api/push/received", {
      method: "POST",
      headers: { "Content-Type": "application/json" },
      body: JSON.stringify({ tag: options.data?.tag ?? options.tag }),
      keepalive: true,
    }).catch(() => {}),
  ])
);
```

---

### Check 5-B：push 到达后 device_received_at 能否被记录

先触发一条测试推送（需要有 push_subscriptions）：
```bash
ssh aliyun-root 'docker exec chatbot-backend-1 python3 -c "
import asyncio, sys
sys.path.insert(0, \"/app\")
from app.services.push_service import send_push_to_all_subscribers, log_notification_sent
from app.config import settings

async def test():
    result = await send_push_to_all_subscribers(
        settings.database_path,
        title=\"Check 5-B\",
        body=\"receipt test\",
        tag=\"check-5b\",
        data={\"tag\": \"check-5b\"},
    )
    print(\"send result:\", result)
    await log_notification_sent(settings.database_path, \"check-5b\", \"qa_test\", \"Check 5-B\", \"receipt test\")

asyncio.run(test())
"'
```

等待 30 秒（手机收到通知），然后检查：
```bash
ssh aliyun-root 'docker exec chatbot-backend-1 python3 -c "
import sqlite3
db = sqlite3.connect(\"/data/chatbot.db\")
db.row_factory = sqlite3.Row
r = db.execute(\"SELECT item_id, sent_at, device_received_at FROM notification_log WHERE item_id=\\'check-5b\\'\").fetchone()
print(dict(r) if r else \"not found\")
print(\"PASS\" if r and r[\"device_received_at\"] else \"FAIL: device_received_at is NULL\")
"'
```

**PASS 条件**：`device_received_at` 非 NULL

**如果 FAIL**：
- 5-A 是否 PASS？SW 的 fetch 调用修好了吗？
- 检查 `_mark_delivery` 函数里 `WHERE item_id IN (...)` 的 candidates 是否包含 `"check-5b"`
- 检查 iOS 是否把网页添加到了主屏幕

清理：
```bash
ssh aliyun-root 'docker exec chatbot-backend-1 python3 -c "
import sqlite3
db = sqlite3.connect(\"/data/chatbot.db\")
db.execute(\"DELETE FROM notification_log WHERE item_id=\\'check-5b\\'\")
db.commit()
"'
```

---

## 完成标准

所有 check 都 PASS 后，跑一次端到端场景：

1. 打开 Agent tab，新建一个 session
2. 输入：`帮我3分钟后发一条推送，内容是"端到端测试完成"`
3. Agent 应立即回复"已安排"（无确认步骤）
4. 3 分钟后手机收到通知
5. 检查 DB：
```bash
ssh aliyun-root 'docker exec chatbot-backend-1 python3 -c "
import sqlite3
db = sqlite3.connect(\"/data/chatbot.db\")
db.row_factory = sqlite3.Row
rows = db.execute(\"SELECT title, sent_at FROM scheduled_notifications ORDER BY created_at DESC LIMIT 3\").fetchall()
for r in rows: print(dict(r))
rows2 = db.execute(\"SELECT item_id, sent_at, device_received_at FROM notification_log ORDER BY sent_at DESC LIMIT 3\").fetchall()
for r in rows2: print(dict(r))
"'
```
6. `sent_at` 非 NULL + `device_received_at` 非 NULL = **全部 PASS ✅**
