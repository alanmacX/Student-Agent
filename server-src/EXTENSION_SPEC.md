# Extension 开发规范

本文件定义了 Student-Agent 系统的扩展开发规范。所有新功能（extension）必须遵循以下模式。

---

## 目录

1. [架构概览](#1-架构概览)
2. [后端：数据库层](#2-后端数据库层)
3. [后端：Agent Tool 注册](#3-后端agent-tool-注册)
4. [后端：Memory 接入](#4-后端memory-接入)
5. [后端：REST API](#5-后端rest-api)
6. [后端：定时任务](#6-后端定时任务)
7. [后端：Standby Agent 接入](#7-后端standby-agent-接入)
8. [前端：Settings Tab](#8-前端settings-tab)
9. [前端：Hub 卡片](#9-前端hub-卡片)
10. [前端：总览页卡片](#10-前端总览页卡片)
11. [部署清单](#11-部署清单)
12. [完整 Checklist](#12-完整-checklist)

---

## 1. 架构概览

```
┌─────────────────────────────────────────────────────────┐
│  Frontend (React + Vite)                                │
│  ├─ Settings tabs (SettingsView.jsx)                    │
│  ├─ Hub cards (HubView.jsx)                             │
│  ├─ Overview cards (ScheduleOverview.jsx)               │
│  └─ Chat input + slash commands (ChatInput.jsx)         │
├─────────────────────────────────────────────────────────┤
│  Backend (FastAPI + aiosqlite)                          │
│  ├─ Routers (routers/*.py)      ← REST endpoints       │
│  ├─ Services (services/*.py)    ← Agent logic          │
│  ├─ Tasks (tasks/*.py)          ← Background jobs      │
│  └─ Database (database.py)      ← Schema + migrations  │
├─────────────────────────────────────────────────────────┤
│  Agent Layer                                            │
│  ├─ Schedule Agent (schedule_agent.py)  ← 主 agent      │
│  ├─ Standby Agent (standby_agent.py)    ← 后台决策       │
│  └─ Memory Agent (memory_agent.py)      ← 消息提取       │
└─────────────────────────────────────────────────────────┘
```

---

## 2. 后端：数据库层

**文件：** `backend/app/database.py`

### 新建表

在 `_SCHEMA` 字符串中添加 `CREATE TABLE IF NOT EXISTS`：

```sql
CREATE TABLE IF NOT EXISTS my_table (
    id         INTEGER PRIMARY KEY AUTOINCREMENT,
    name       TEXT NOT NULL,
    status     TEXT NOT NULL DEFAULT 'active',
    created_at TEXT NOT NULL DEFAULT (datetime('now')),
    updated_at TEXT NOT NULL DEFAULT (datetime('now'))
);
```

### 给已有表加列

在 `_COLUMN_MIGRATIONS` 列表中追加 `ALTER TABLE`：

```python
_COLUMN_MIGRATIONS: list[str] = [
    # ... existing migrations ...
    "ALTER TABLE my_table ADD COLUMN new_field TEXT DEFAULT 'default_value'",
]
```

迁移自动忽略"列已存在"错误，可安全重复执行。

### 连接模式

```python
from app.database import db_conn

async with db_conn() as db:
    rows = await (await db.execute("SELECT * FROM my_table")).fetchall()
```

---

## 3. 后端：Agent Tool 注册

**文件：** `backend/app/services/schedule_agent.py`

注册一个新 tool 需要修改 **4 个位置**：

### 3.1 ToolDefinition（`_build_schedule_tools()`）

```python
ToolDefinition(
    name="my_tool",
    description="工具描述，告诉 LLM 什么时候该调用。用中文写。",
    input_schema={
        "type": "object",
        "properties": {
            "param1": {"type": "string", "description": "参数说明"},
            "param2": {"type": "integer", "description": "数字参数"},
        },
        "required": ["param1"],
        "additionalProperties": False,
    },
),
```

规范：
- `description` 用中文，说明**何时调用**
- `input_schema` 必须是合法 JSON Schema
- 始终设置 `"additionalProperties": False`
- `required` 列出必填参数

### 3.2 关键词路由（`_SCHEDULE_KEYWORDS` 字典）

```python
"my_tool": ["关键词1", "关键词2", "keyword1", "keyword2"],
```

用户消息包含任一关键词时，该 tool 被包含在 LLM 的可用工具列表中。无匹配时排除（节省 token）。

特殊：`ALWAYS_INCLUDE = {"get_schedule_context"}` 中的工具始终包含。

### 3.3 Handler（`_execute_schedule_tool()` 的 if/elif 链）

```python
elif tc.name == "my_tool":
    param1 = tc.arguments.get("param1", "").strip()
    param2 = tc.arguments.get("param2", 0)
    if not param1:
        return "错误: param1 不能为空"
    # 业务逻辑...
    return json.dumps({"ok": True, "result": ...}, ensure_ascii=False)
```

规范：
- 从 `tc.arguments` 读取参数
- 错误返回 `"错误: ..."` 前缀字符串
- 成功返回 `json.dumps(...)` 字符串
- 写操作使用确认模式（见 3.4）

### 3.4 写操作确认模式

对于 create/update/delete 操作，使用 `_require_confirmation()`：

```python
elif tc.name == "create_something":
    confirmation = _require_confirmation(tc.name, user_message, tc.arguments)
    if confirmation:
        await _store_pending_mutation(db_path, tc.name, tc.arguments)
        return confirmation
    # 用户已确认，执行实际操作
    async with aiosqlite.connect(db_path) as db:
        await db.execute("INSERT INTO ...")
        await db.commit()
    return json.dumps({"ok": True}, ensure_ascii=False)
```

### 3.5 Payload 映射（前端渲染）

如果工具返回结构化数据供前端渲染：

```python
# 在 run_schedule_agent() 的 _TOOL_PAYLOAD_MAP 中添加：
_TOOL_PAYLOAD_MAP = {
    "list_my_items": "my_items",
    # ...
}

# 如果是写操作，在 _ACTION_TOOLS 中添加：
_ACTION_TOOLS = {
    "create_my_item", "update_my_item", "delete_my_item",
    # ...
}
```

---

## 4. 后端：Memory 接入

### 4.1 写入 user_memory

通过 `save_memory` tool（已内置），或直接 SQL：

```python
await db.execute(
    "INSERT INTO user_memory (key, value, category) VALUES (?, ?, ?) "
    "ON CONFLICT(key) DO UPDATE SET value=excluded.value, updated_at=datetime('now')",
    ("my_key", "my_value", "preference"),
)
```

### 4.2 读取 user_memory

在 `build_turn_context()` 中查询并注入 agent prompt：

```python
user_mem = await (await db.execute(
    "SELECT key, value, category FROM user_memory ORDER BY updated_at DESC LIMIT 20"
)).fetchall()
if user_mem:
    lines.append("【用户记忆】" + "；".join(
        f"{r['key']}: {r['value']} ({r['category']})" for r in user_mem
    ))
```

### 4.3 写入 chaoxing_memory_entries

适用于需要提取消息、生成摘要、设置重要度的场景：

```python
import uuid
await db.execute(
    """INSERT INTO chaoxing_memory_entries
       (id, title, summary, reason, action_hint, importance, sent_at, extracted_at, source_type, hierarchy_tier)
       VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?)""",
    (str(uuid.uuid4()), title, summary, reason, action_hint, importance,
     sent_at, datetime.now().isoformat(), "my_source", 1),
)
```

`source_type` 可选值：`chaoxing` | `dingtalk` | `idea` | `shopping` | `user` | `system`

`hierarchy_tier`：0=CRITICAL, 1=ACTIONABLE, 2=CONTEXT, 3=REFERENCE, 4=HISTORICAL

### 4.4 在 Standby Agent 中读取 Memory

在 `tasks/standby_agent.py` 的 `_build_context()` 中添加查询：

```python
my_rows = await (await db.execute(
    "SELECT id, title, importance FROM my_table WHERE status='active' LIMIT 5"
)).fetchall()
if my_rows:
    lines.append("【我的数据】")
    for r in my_rows:
        lines.append(f"  - [{r['importance']}] {r['title']}  [id:{r['id']}]")
```

---

## 5. 后端：REST API

**新文件：** `backend/app/routers/my_feature.py`

```python
from fastapi import APIRouter
from app.database import db_conn

router = APIRouter(prefix="/api/my_feature", tags=["my_feature"])


@router.get("")
async def list_items():
    async with db_conn() as db:
        rows = await (await db.execute("SELECT * FROM my_table")).fetchall()
    return [dict(r) for r in rows]


@router.post("")
async def create_item(data: dict):
    async with db_conn() as db:
        await db.execute("INSERT INTO my_table (name) VALUES (?)", (data["name"],))
        await db.commit()
    return {"ok": True}


@router.put("/{item_id}")
async def update_item(item_id: int, data: dict):
    async with db_conn() as db:
        await db.execute("UPDATE my_table SET name=? WHERE id=?", (data["name"], item_id))
        await db.commit()
    return {"ok": True}


@router.delete("/{item_id}")
async def delete_item(item_id: int):
    async with db_conn() as db:
        await db.execute("DELETE FROM my_table WHERE id=?", (item_id,))
        await db.commit()
    return {"ok": True}
```

**注册到 main.py：**

```python
from app.routers import my_feature
app.include_router(my_feature.router)
```

---

## 6. 后端：定时任务

**新文件：** `backend/app/tasks/my_task.py`

```python
async def run_my_task(app_state):
    """每 N 分钟执行一次。"""
    db_path = app_state.settings.database_path
    # 业务逻辑...
```

**注册到 scheduler.py：**

```python
from app.tasks.my_task import run_my_task

# 在 init_scheduler() 中添加：
scheduler.add_job(
    run_my_task,
    IntervalTrigger(minutes=30),    # 或 CronTrigger(hour=8, minute=0)
    args=[app_state],
    id="my_task",
    misfire_grace_time=120,
    replace_existing=True,
)
```

触发器类型：
- `IntervalTrigger(minutes=N)` — 固定间隔
- `CronTrigger(hour=8, minute=0)` — 每天定时
- `DateTrigger(run_date=datetime)` — 一次性

可选参数：`max_instances=1`（防重叠）、`coalesce=True`（合并错过的执行）

---

## 7. 后端：Standby Agent 接入

**文件：** `backend/app/tasks/standby_agent.py`

如果 extension 需要 Standby Agent 主动监控：

### 7.1 在 `_build_context()` 中添加数据源

```python
# 在现有数据源之后添加
my_data = await (await db.execute(
    "SELECT id, title, urgency FROM my_table WHERE needs_attention=1 LIMIT 5"
)).fetchall()

if my_data:
    lines.append("【我的扩展数据】")
    for r in my_data:
        lines.append(f"  - {r['title']} urgency={r['urgency']} [id:{r['id']}]")
```

### 7.2 更新 `_compute_context_hash()`

在哈希输入中加入新表的 `MAX(updated_at)`：

```python
r4 = await (await db.execute(
    "SELECT MAX(updated_at) FROM my_table"
)).fetchone()
raw = f"{r1[0]}|{r2[0]}|{r3[0]}|{r4[0]}"
```

### 7.3 更新 `_build_system_prompt()` 决策标准

```python
决策标准：
1. ... existing criteria ...
7. 我的扩展条件（xxx）→ 推送（高优先级），item_id 用 my_alert_{id}
```

---

## 8. 前端：Settings Tab

**文件：** `frontend/src/components/settings/SettingsView.jsx`

```jsx
import { MyIcon } from "lucide-react";
import MyFeaturePanel from "./MyFeaturePanel";

const TABS = [
  // ... existing tabs ...
  { id: "myfeature", label: "我的功能", mobileLabel: "功能", icon: MyIcon },
];

// 在内容区域添加：
{tab === "myfeature" && <MyFeaturePanel />}
```

---

## 9. 前端：Hub 卡片

**文件：** `frontend/src/components/hub/HubView.jsx`

在 `<div className="stagger">` 内添加新 section：

```jsx
<section className="surface-card animate-rise p-4" style={{ animationDelay: "160ms" }}>
  <div className="mb-3 flex items-center gap-2">
    <MyIcon size={14} className="text-[var(--accent)]" />
    <h3 className="text-[11px] font-semibold uppercase tracking-[0.16em] text-[var(--text-tertiary)]">
      我的功能
    </h3>
  </div>
  {/* 内容 */}
</section>
```

---

## 10. 前端：总览页卡片

**文件：** `frontend/src/components/schedule/ScheduleOverview.jsx`

在 TodayCard 和 ScheduleSection 之间插入：

```jsx
<TodayCard ... />
<MyNewCard />           {/* 新增 */}
<ScheduleSection ... />
```

创建独立组件 `frontend/src/components/schedule/MyNewCard.jsx`，参考 `StatusStrip.jsx` 或 `TokenSummary.jsx` 的模式。

---

## 11. 部署清单

每次新增 extension 后：

```bash
# 1. 本地构建前端
cd server-src/frontend && npm run build

# 2. 同步到服务器
rsync -avz server-src/ aliyun-root:/opt/chatbot/server-src/

# 3. 重建容器
ssh aliyun-root "cd /opt/chatbot/server-src && docker compose up -d --build"

# 4. 推送到 GitHub
git add -A && git commit -m "feat: my extension" && git push
```

---

## 12. 完整 Checklist

新增 extension 时，按需勾选：

| # | 步骤 | 文件 | 是否需要 |
|---|------|------|----------|
| 1 | 数据库表/列 | `database.py` | □ |
| 2 | CRUD 服务层 | `services/my_service.py` | □ |
| 3 | Tool 定义 | `schedule_agent.py` `_build_schedule_tools()` | □ |
| 4 | 关键词路由 | `schedule_agent.py` `_SCHEDULE_KEYWORDS` | □ |
| 5 | Tool handler | `schedule_agent.py` `_execute_schedule_tool()` | □ |
| 6 | Payload 映射 | `schedule_agent.py` `_TOOL_PAYLOAD_MAP` / `_ACTION_TOOLS` | □ |
| 7 | REST API | `routers/my_feature.py` + `main.py` | □ |
| 8 | 定时任务 | `tasks/my_task.py` + `scheduler.py` | □ |
| 9 | Standby 接入 | `standby_agent.py` `_build_context()` + hash + prompt | □ |
| 10 | Memory 写入 | tool handler 或 service 中的 SQL | □ |
| 11 | Memory 读取 | `build_turn_context()` 或 `_build_context()` | □ |
| 12 | Settings tab | `SettingsView.jsx` | □ |
| 13 | Hub 卡片 | `HubView.jsx` | □ |
| 14 | 总览页卡片 | `ScheduleOverview.jsx` + 新组件 | □ |
| 15 | Slash 命令 | `commands.js` + `ChatInput.jsx` + `ScheduleView.jsx` | □ |
| 16 | 前端 API 客户端 | `api/my_feature.js` | □ |
