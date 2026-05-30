# ChatBot — Feature Plan

> **给 Coding Agent 用。按模块顺序实现，每个模块改完验证后再做下一个。**
> 部署命令统一见文末。

---

## 环境速查

```
本地前端：  /Users/macalan/Documents/chatbot/web/frontend/
本地后端：  /Users/macalan/Documents/chatbot/web/backend/app/
服务器：    ssh aliyun-root "..."
数据库：    /data/chatbot.db（容器内）
```

---

## Module A — 数据导出 / 导入（服务器迁移）

### 背景

迁移服务器时需要把 SQLite 数据带走。要求：
- 一键导出 → 下载 JSON 文件
- 新服务器一键导入 → 恢复所有用户数据
- 不包含 push_subscriptions（device-specific，迁移后订阅失效）
- 不包含 chaoxing_session（cookie 可能已失效，重新登录即可）

### 需导出的表

```python
EXPORT_TABLES = [
    "settings",
    "conversations",
    "messages",
    "server_reminders",
    "server_events",
    "server_courses",
    "schedule_sessions",
    "schedule_messages",
    "custom_providers",
    "chaoxing_memory_entries",
    "chaoxing_conversation_sync",
    "chaoxing_processed_ids",
    "chaoxing_processed_fingerprints",
    "scheduled_notifications",
    "notification_log",
    "standby_agent_log",
]
```

### 后端：新增 export/import 路由

新建文件 `backend/app/routers/data.py`：

```python
from __future__ import annotations
import json
from datetime import datetime, timezone
from fastapi import APIRouter, Request
from fastapi.responses import JSONResponse, Response
import aiosqlite
from app.config import settings

router = APIRouter(prefix="/api/data", tags=["data"])

EXPORT_TABLES = [
    "settings", "conversations", "messages",
    "server_reminders", "server_events", "server_courses",
    "schedule_sessions", "schedule_messages",
    "custom_providers",
    "chaoxing_memory_entries", "chaoxing_conversation_sync",
    "chaoxing_processed_ids", "chaoxing_processed_fingerprints",
    "scheduled_notifications", "notification_log", "standby_agent_log",
]


@router.get("/export")
async def export_data():
    """Dump all user data to JSON. Excludes device-specific tables."""
    dump = {
        "version": 1,
        "exported_at": datetime.now(timezone.utc).isoformat(),
        "tables": {},
    }
    async with aiosqlite.connect(settings.database_path) as db:
        db.row_factory = aiosqlite.Row
        for table in EXPORT_TABLES:
            try:
                rows = await (await db.execute(f"SELECT * FROM {table}")).fetchall()
                dump["tables"][table] = [dict(r) for r in rows]
            except Exception as e:
                dump["tables"][table] = {"error": str(e)}

    content = json.dumps(dump, ensure_ascii=False, indent=2)
    return Response(
        content=content,
        media_type="application/json",
        headers={
            "Content-Disposition": f'attachment; filename="chatbot-export-{datetime.now(timezone.utc).strftime("%Y%m%d-%H%M")}.json"'
        },
    )


@router.post("/import")
async def import_data(request: Request):
    """Restore data from a previously exported JSON file."""
    body = await request.json()
    if body.get("version") != 1 or "tables" not in body:
        return {"error": "invalid export file format"}

    results = {}
    async with aiosqlite.connect(settings.database_path) as db:
        for table, rows in body["tables"].items():
            if table not in EXPORT_TABLES:
                results[table] = "skipped (not in allowlist)"
                continue
            if isinstance(rows, dict) and "error" in rows:
                results[table] = f"skipped (export had error: {rows['error']})"
                continue
            try:
                if not rows:
                    results[table] = "empty"
                    continue
                # Use column names from the first row
                cols = list(rows[0].keys())
                placeholders = ",".join("?" for _ in cols)
                col_list = ",".join(cols)
                count = 0
                for row in rows:
                    await db.execute(
                        f"INSERT OR IGNORE INTO {table} ({col_list}) VALUES ({placeholders})",
                        [row.get(c) for c in cols],
                    )
                    count += 1
                await db.commit()
                results[table] = f"imported {count} rows"
            except Exception as e:
                results[table] = f"error: {e}"

    return {"ok": True, "results": results}
```

在 `backend/app/main.py` 中注册：

```python
from app.routers.data import router as data_router
app.include_router(data_router)
```

### 前端：在 SettingsView 加 "数据管理" 标签页

在 `frontend/src/components/settings/SettingsView.jsx` 添加标签：

```js
import { Database } from "lucide-react";

// TABS 数组末尾加：
{ id: "data", label: "数据管理", mobileLabel: "数据", icon: Database },
```

新建 `frontend/src/components/settings/DataPanel.jsx`：

```jsx
import { useState } from "react";
import { Download, Upload, AlertTriangle } from "lucide-react";

export default function DataPanel() {
  const [importing, setImporting] = useState(false);
  const [importResult, setImportResult] = useState(null);

  const handleExport = () => {
    window.location.href = "/api/data/export";
  };

  const handleImport = async (e) => {
    const file = e.target.files?.[0];
    if (!file) return;
    setImporting(true);
    setImportResult(null);
    try {
      const text = await file.text();
      const data = JSON.parse(text);
      const r = await fetch("/api/data/import", {
        method: "POST",
        headers: { "Content-Type": "application/json" },
        body: JSON.stringify(data),
      });
      const result = await r.json();
      setImportResult(result);
    } catch (err) {
      setImportResult({ error: err.message });
    } finally {
      setImporting(false);
      e.target.value = "";
    }
  };

  return (
    <div className="max-w-xl space-y-6">
      <div>
        <h2 className="text-lg font-semibold text-white">数据管理</h2>
        <p className="mt-1 text-sm text-[var(--text-tertiary)]">
          导出备份用于服务器迁移，或从备份文件恢复数据。
        </p>
      </div>

      {/* Export */}
      <div className="rounded-2xl border border-[var(--border)] bg-[var(--surface)] p-4 space-y-3">
        <h3 className="text-sm font-semibold text-white">导出数据</h3>
        <p className="text-xs text-[var(--text-tertiary)]">
          导出所有对话、课程、提醒、Memory 等数据为 JSON 文件。不含设备推送订阅和学习通登录 Cookie。
        </p>
        <button
          onClick={handleExport}
          className="flex items-center gap-2 rounded-xl bg-[var(--accent)] px-4 py-2.5 text-sm font-semibold text-white hover:bg-[var(--accent-strong)]"
        >
          <Download size={16} />
          导出 JSON 备份
        </button>
      </div>

      {/* Import */}
      <div className="rounded-2xl border border-[var(--border)] bg-[var(--surface)] p-4 space-y-3">
        <h3 className="text-sm font-semibold text-white">导入数据</h3>
        <div className="flex items-start gap-2 rounded-xl border border-orange-500/30 bg-orange-500/10 p-3">
          <AlertTriangle size={16} className="mt-0.5 shrink-0 text-orange-400" />
          <p className="text-xs text-orange-300">
            导入使用 INSERT OR IGNORE，不会覆盖已存在的记录。建议在新服务器的空数据库上导入。
          </p>
        </div>
        <label className="flex cursor-pointer items-center gap-2 rounded-xl border border-[var(--border)] bg-[var(--input-bg)] px-4 py-2.5 text-sm text-[var(--text-secondary)] hover:bg-[var(--hover-bg)]">
          <Upload size={16} />
          {importing ? "导入中..." : "选择备份文件"}
          <input
            type="file"
            accept=".json"
            className="hidden"
            onChange={handleImport}
            disabled={importing}
          />
        </label>
        {importResult && (
          <div className="rounded-xl border border-[var(--border)] bg-[var(--deep-bg)] p-3 text-xs text-[var(--text-secondary)] font-mono overflow-x-auto">
            {importResult.error ? (
              <p className="text-red-400">{importResult.error}</p>
            ) : (
              <pre>{JSON.stringify(importResult.results, null, 2)}</pre>
            )}
          </div>
        )}
      </div>
    </div>
  );
}
```

在 `SettingsView.jsx` 里加 import 和条件渲染：

```jsx
import DataPanel from "./DataPanel";
// ...
{tab === "data" && <DataPanel />}
```

### 验证

```bash
# 导出
curl http://localhost:8000/api/data/export -o backup.json
# 看 JSON 里各表行数是否正确
python3 -c "import json; d=json.load(open('backup.json')); [print(k, len(v)) for k,v in d['tables'].items()]"
```

---

## Module B — 通知系统自动推送 Debug（服务器上实测）

### 背景

验证两条核心 pipeline：
1. **Assignment deadline → 自动 push**（`check_and_send_deadline_notifications`，每 5min 跑）
2. **Chaoxing message → Memory → scheduled_notifications → push**（`memory_sweep` + `check_scheduled_notifications`）

测试直接在服务器上做，测前清空相关数据，测后再清空。

### 测试脚本：Pipeline 1 — deadline push

```bash
# Step 1: 插入一条 45 分钟后截止的假作业（绕过 chaoxing API，直接注入到 assignment cache）
# 注意：chaoxing assignment 是 live pull 的，不落表。
# 需要 mock chaoxing_svc.fetch_all_pending_assignments 或者用 memory_entries 绕过。
# 更直接的办法：触发 check_and_send_deadline_notifications 的 memory_high 分支

# 插入一条高重要性 memory entry，extracted_at = 5 分钟前（在 10 分钟窗口内）
ssh aliyun-root 'docker exec chatbot-backend-1 python3 -c "
import sqlite3, uuid
from datetime import datetime, timezone, timedelta
db = sqlite3.connect(\"/data/chatbot.db\")
eid = str(uuid.uuid4())
now = datetime.now(timezone.utc)
extracted = (now - timedelta(minutes=3)).isoformat()  # 3 分钟前
db.execute(\"\"\"
    INSERT INTO chaoxing_memory_entries
    (id, title, summary, reason, importance, category, extracted_at, sent_at, archived_at)
    VALUES (?,?,?,?,?,?,?,?,NULL)
\"\"\", (eid, \"Pipeline B-1 Test\", \"deadline push test\", \"debug\", \"high\", \"notice\", extracted, extracted))
db.commit()
print(\"entry_id:\", eid)
"'

# Step 2: 等待最多 6 分钟（deadline_check 每 5min 跑）
# 或者手动触发：
ssh aliyun-root 'docker exec chatbot-backend-1 python3 -c "
import asyncio, sys
sys.path.insert(0, \"/app\")
from app.main import app
from app.tasks.notification_sender import check_and_send_deadline_notifications

async def run():
    await check_and_send_deadline_notifications(app.state)
    print(\"done\")

asyncio.run(run())
"'

# Step 3: 验证 notification_log 有这条记录
ssh aliyun-root 'docker exec chatbot-backend-1 python3 -c "
import sqlite3
db = sqlite3.connect(\"/data/chatbot.db\")
db.row_factory = sqlite3.Row
rows = db.execute(\"SELECT item_id, notif_type, sent_at, device_received_at FROM notification_log ORDER BY sent_at DESC LIMIT 5\").fetchall()
for r in rows: print(dict(r))
"'
```

**PASS 条件**：`notification_log` 有 `notif_type=memory_high`，`sent_at` 非 NULL

**如果 FAIL**：
- 检查 `has_notified` 是否已有该 entry_id 的记录（先清理再测）
- 检查 `push_subscriptions` 是否有订阅

---

### 测试脚本：Pipeline 2 — memory entry → scheduled push

```bash
# Step 1: 清理旧测试数据
ssh aliyun-root 'docker exec chatbot-backend-1 python3 -c "
import sqlite3
db = sqlite3.connect(\"/data/chatbot.db\")
db.execute(\"DELETE FROM chaoxing_memory_entries WHERE title LIKE \"%Pipeline B%\"\")
db.execute(\"DELETE FROM scheduled_notifications WHERE reason='\''debug-pipeline-b'\'' \")
db.execute(\"DELETE FROM notification_log WHERE item_id LIKE '\''pipeline-b%'\''\")
db.commit()
print(\"cleaned\")
"'

# Step 2: 插入一条 medium+exam 的 memory entry（rule: now + 8min）
ssh aliyun-root 'docker exec chatbot-backend-1 python3 -c "
import asyncio, sys, sqlite3, uuid
from datetime import datetime, timezone, timedelta
sys.path.insert(0, \"/app\")
from app.services.notification_scheduler import auto_schedule_from_memory
from app.config import settings

eid = str(uuid.uuid4())
now = datetime.now(timezone.utc)
entry = {
    \"id\": eid,
    \"title\": \"Pipeline B-2 期末考试通知\",
    \"summary\": \"12月20日期末考试\",
    \"action_hint\": \"记得提前复习\",
    \"importance\": \"medium\",
    \"category\": \"exam\",
    \"expires_at\": (now + timedelta(days=30)).isoformat(),
}

async def run():
    count = await auto_schedule_from_memory([entry], settings.database_path, now=now)
    print(\"scheduled:\", count)
    db = sqlite3.connect(settings.database_path)
    rows = db.execute(\"SELECT id, title, scheduled_at, sent_at FROM scheduled_notifications WHERE source_id=?\", (eid,)).fetchall()
    for r in rows:
        print(\"notification:\", r)

asyncio.run(run())
"'

# Step 3: 等待 ~10 分钟，或手动触发 check_scheduled_notifications
ssh aliyun-root 'docker exec chatbot-backend-1 python3 -c "
import asyncio, sys
sys.path.insert(0, \"/app\")
from app.main import app
from app.tasks.notification_sender import check_scheduled_notifications

async def run():
    await check_scheduled_notifications(app.state)
    print(\"done\")

asyncio.run(run())
"'

# Step 4: 验证
ssh aliyun-root 'docker exec chatbot-backend-1 python3 -c "
import sqlite3
db = sqlite3.connect(\"/data/chatbot.db\")
db.row_factory = sqlite3.Row
rows = db.execute(\"SELECT title, scheduled_at, sent_at FROM scheduled_notifications WHERE reason LIKE \"%exam%\" ORDER BY created_at DESC LIMIT 5\").fetchall()
for r in rows: print(dict(r))
"'
```

**PASS 条件**：`sent_at` 非 NULL，手机收到通知

### 测后清理

```bash
ssh aliyun-root 'docker exec chatbot-backend-1 python3 -c "
import sqlite3
db = sqlite3.connect(\"/data/chatbot.db\")
db.execute(\"DELETE FROM chaoxing_memory_entries WHERE title LIKE \"%Pipeline B%\"\")
db.execute(\"DELETE FROM scheduled_notifications WHERE title LIKE \"%Pipeline B%\"\")
db.execute(\"DELETE FROM notification_log WHERE push_title LIKE \"%Pipeline B%\"\")
db.commit()
print(\"all cleaned\")
"'
```

### 如果 Pipeline 1 FAIL（无 high-importance push）

检查 `check_and_send_deadline_notifications` 里的这段：
```python
AND datetime(extracted_at) > datetime('now', '-10 minutes')
```
`extracted_at` 是 UTC 存储但无 'Z' 后缀，`datetime('now')` 是 UTC，SQLite 的 `datetime()` 函数处理无后缀字符串视为 UTC——这里**不存在**前端那样的 8 小时问题（SQLite 内部计算，不经过 JS）。如果仍然 FAIL，把窗口扩大到 30 分钟：

```python
# 修改为：
AND datetime(extracted_at) > datetime('now', '-30 minutes')
```

---

## Module C — Chat Agent 自动开新 Session

### 背景

用户隔超过 12 小时再打开 Schedule Agent，应自动进入一个新 session，而不是继续几天前的对话。

### 实现方案

在前端 `ScheduleView.jsx` 加载 sessions 列表后，检查最近 session 的 `updated_at`：若超过阈值（12h），自动 create 一个新 session 并切换到它。

### 修改文件

`frontend/src/hooks/useScheduleSessions.js`

在 `useScheduleSessions` hook 里，`refreshSessions` 之后加逻辑：

```js
const AUTO_NEW_SESSION_HOURS = 12; // 超过 12 小时无活动 → 新建

// 在 hook 里新增方法（返回值里也要加）：
const initSession = useCallback(async () => {
  const list = await fetchSessions(); // 直接 fetch，不用 state
  setSessions(list);
  setLoading(false);
  if (!list.length) {
    // 第一次使用，创建默认 session
    const s = await createSession("新对话");
    return s.id;
  }
  const latest = list[0]; // 已按 updated_at DESC 排序
  const lastActive = new Date(
    latest.updated_at.endsWith('Z') || /[+-]\d{2}:\d{2}$/.test(latest.updated_at)
      ? latest.updated_at
      : latest.updated_at + 'Z'
  );
  const hoursAgo = (Date.now() - lastActive.getTime()) / 3_600_000;
  if (hoursAgo > AUTO_NEW_SESSION_HOURS) {
    // 上次活动超过阈值，自动新建
    const s = await createSession("新对话");
    setSessions((prev) => [s, ...prev]);
    return s.id;
  }
  return latest.id;
}, [createSession]);
```

在 `ScheduleView.jsx` 的 `useEffect` 初始化里，把 `setCurrentSessionId(sessions[0]?.id)` 改为调用 `initSession()` 的返回值。

### 修改 `ScheduleView.jsx` 的初始化逻辑

找到现有的 sessions 加载 effect，替换为：

```jsx
useEffect(() => {
  let cancelled = false;
  (async () => {
    const initialId = await initSession();
    if (!cancelled) {
      setCurrentSessionId(initialId);
      // load messages for initialId
      loadMessages(initialId);
    }
  })();
  return () => { cancelled = true; };
}, []);  // 只在 mount 时跑一次
```

### 验证

把一个测试 session 的 `updated_at` 改成 2 天前：

```bash
ssh aliyun-root 'docker exec chatbot-backend-1 python3 -c "
import sqlite3
from datetime import datetime, timezone, timedelta
db = sqlite3.connect(\"/data/chatbot.db\")
old = (datetime.now(timezone.utc) - timedelta(days=2)).isoformat()
db.execute(\"UPDATE schedule_sessions SET updated_at=? WHERE id=(SELECT id FROM schedule_sessions ORDER BY updated_at DESC LIMIT 1)\", (old,))
db.commit()
print(\"done\")
"'
```

刷新页面，应该自动切换到一个新建的 session，旧 session 仍在列表中。

---

## Module D — Provider 管理：Saved API List

### 背景

现在的设置页有 4 个固定 API key 输入框，不够灵活。改成：
- 一个 Provider 列表（卡片式）
- 每个 Provider 可自定名字、base_url、api_key、模型列表（自动从 `/v1/models` 获取）
- Mimo 和 OpenAI 作为预置默认条目
- 支持添加 / 编辑 / 删除

### 后端：新 Provider CRUD 端点

在 `backend/app/routers/providers.py` 里新增（现有文件已有 `get_providers` 等，扩充即可）：

```python
@router.post("/providers")
async def create_provider(request: Request):
    body = await request.json()
    required = ["name", "base_url", "api_key"]
    if not all(body.get(k) for k in required):
        return {"error": "name, base_url, api_key required"}

    provider_id = body.get("id") or f"custom-{uuid.uuid4().hex[:8]}"
    data = {
        "id": provider_id,
        "name": body["name"],
        "base_url": body["base_url"].rstrip("/"),
        "api_key": body["api_key"],
        "api_type": body.get("api_type", "openAI"),
        "models": body.get("models", []),
    }
    async with db_conn() as db:
        await db.execute(
            "INSERT OR REPLACE INTO custom_providers (id, data_json) VALUES (?,?)",
            (provider_id, json.dumps(data)),
        )
        await db.commit()
    return {"ok": True, "id": provider_id}


@router.patch("/providers/{provider_id}")
async def update_provider(provider_id: str, request: Request):
    body = await request.json()
    async with db_conn() as db:
        row = await (await db.execute(
            "SELECT data_json FROM custom_providers WHERE id=?", (provider_id,)
        )).fetchone()
        if not row:
            return {"error": "not found"}
        data = json.loads(row[0])
        for k in ["name", "base_url", "api_key", "models", "api_type"]:
            if k in body:
                data[k] = body[k]
        await db.execute(
            "UPDATE custom_providers SET data_json=? WHERE id=?",
            (json.dumps(data), provider_id),
        )
        await db.commit()
    return {"ok": True}


@router.delete("/providers/{provider_id}")
async def delete_provider(provider_id: str):
    async with db_conn() as db:
        await db.execute("DELETE FROM custom_providers WHERE id=?", (provider_id,))
        await db.commit()
    return {"ok": True}


@router.post("/providers/{provider_id}/fetch-models")
async def fetch_provider_models(provider_id: str, request: Request):
    """Call base_url/v1/models with the stored api_key and return model ids."""
    body = await request.json()  # may include override base_url/api_key for preview
    base_url = body.get("base_url", "").rstrip("/")
    api_key = body.get("api_key", "")
    if not base_url or not api_key:
        # Try to load from DB
        async with db_conn() as db:
            row = await (await db.execute(
                "SELECT data_json FROM custom_providers WHERE id=?", (provider_id,)
            )).fetchone()
        if row:
            data = json.loads(row[0])
            base_url = base_url or data.get("base_url", "")
            api_key = api_key or data.get("api_key", "")
    try:
        import httpx
        async with httpx.AsyncClient(timeout=10) as client:
            r = await client.get(
                f"{base_url}/v1/models",
                headers={"Authorization": f"Bearer {api_key}"},
            )
            r.raise_for_status()
            data = r.json()
        model_ids = [m["id"] for m in data.get("data", [])]
        return {"ok": True, "models": model_ids}
    except Exception as e:
        return {"ok": False, "error": str(e), "models": []}
```

同时在 `provider_registry.py` 里，`resolve_provider` 已支持 `custom_providers` 表，无需改动。

### 后端：预置 Mimo 到 custom_providers（migration）

在 `database.py` 的 `run_migrations()` 末尾（`await db.commit()` 之前）加：

```python
# Pre-seed Mimo provider (idempotent)
await db.execute("""
    INSERT OR IGNORE INTO custom_providers (id, data_json)
    VALUES ('xiaomimimo', '{"id":"xiaomimimo","name":"小米 MiMo","base_url":"https://token-plan-sgp.xiaomimimo.com","api_type":"openAI","models":["mimo-v2.5-pro"],"api_key":""}')
""")
```

（api_key 由用户在 UI 里填写，空字符串是占位）

### 前端：重写 ProviderSettings.jsx

完整替换 `frontend/src/components/settings/ProviderSettings.jsx`：

```jsx
import { useState, useEffect, useCallback } from "react";
import { Plus, Trash2, Edit2, RefreshCw, Check, ChevronDown, ChevronUp, Wifi } from "lucide-react";
import { apiFetch } from "../../api/client";

// ── API helpers ───────────────────────────────────────────────────────────────
async function listProviders() {
  const d = await apiFetch("/api/providers");
  // merge builtin + custom into flat list
  return [...(d.builtin || []), ...(d.custom || [])];
}

async function saveProvider(data) {
  if (data.id && data.is_builtin === false) {
    return apiFetch(`/api/providers/${data.id}`, { method: "PATCH", body: JSON.stringify(data) });
  }
  return apiFetch("/api/providers", { method: "POST", body: JSON.stringify(data) });
}

async function deleteProvider(id) {
  return apiFetch(`/api/providers/${id}`, { method: "DELETE" });
}

async function fetchModels(providerId, base_url, api_key) {
  return apiFetch(`/api/providers/${providerId || "new"}/fetch-models`, {
    method: "POST",
    body: JSON.stringify({ base_url, api_key }),
  });
}

// ── Empty provider form ───────────────────────────────────────────────────────
const EMPTY_FORM = { name: "", base_url: "", api_key: "", models: [] };

// ── Main component ────────────────────────────────────────────────────────────
export default function ProviderSettings() {
  const [providers, setProviders] = useState([]);
  const [loading, setLoading] = useState(true);
  const [editingId, setEditingId] = useState(null); // null = no edit, "new" = add form
  const [form, setForm] = useState(EMPTY_FORM);
  const [fetchingModels, setFetchingModels] = useState(false);
  const [saving, setSaving] = useState(false);
  const [reachability, setReachability] = useState({});

  // Schedule agent provider setting
  const [scheduleProviderId, setScheduleProviderId] = useState("xiaomimimo");

  const reload = useCallback(async () => {
    setLoading(true);
    try {
      const list = await listProviders();
      setProviders(list);
    } finally {
      setLoading(false);
    }
  }, []);

  useEffect(() => {
    reload();
    // Load schedule agent provider setting
    apiFetch("/api/settings").then((s) => {
      setScheduleProviderId(s.schedule_agent_provider_id || "xiaomimimo");
    }).catch(() => {});
  }, [reload]);

  const startEdit = (provider) => {
    setEditingId(provider.id);
    setForm({
      id: provider.id,
      name: provider.name,
      base_url: provider.base_url || "",
      api_key: provider.api_key || "",
      models: provider.models || [],
      api_type: provider.api_type || "openAI",
      is_builtin: provider.is_builtin,
    });
  };

  const startAdd = () => {
    setEditingId("new");
    setForm(EMPTY_FORM);
  };

  const cancelEdit = () => {
    setEditingId(null);
    setForm(EMPTY_FORM);
  };

  const handleFetchModels = async () => {
    setFetchingModels(true);
    try {
      const result = await fetchModels(form.id, form.base_url, form.api_key);
      if (result.models?.length) {
        setForm((f) => ({ ...f, models: result.models }));
      } else {
        alert(result.error || "未获取到模型列表");
      }
    } finally {
      setFetchingModels(false);
    }
  };

  const handleSave = async () => {
    if (!form.name || !form.base_url) return;
    setSaving(true);
    try {
      await saveProvider(form);
      await reload();
      cancelEdit();
    } finally {
      setSaving(false);
    }
  };

  const handleDelete = async (id) => {
    if (!confirm("确认删除此 Provider？")) return;
    await deleteProvider(id);
    await reload();
  };

  const handleCheckReachability = async (p) => {
    setReachability((r) => ({ ...r, [p.id]: "checking" }));
    try {
      const result = await apiFetch(`/api/providers/${p.id}/reachability`);
      setReachability((r) => ({ ...r, [p.id]: result.reachable ? "ok" : "fail" }));
    } catch {
      setReachability((r) => ({ ...r, [p.id]: "fail" }));
    }
  };

  const saveScheduleProvider = async (id) => {
    setScheduleProviderId(id);
    await apiFetch("/api/settings", {
      method: "PUT",
      body: JSON.stringify({ settings: { schedule_agent_provider_id: id } }),
    });
  };

  return (
    <div className="max-w-2xl space-y-4">
      <div className="flex items-center justify-between">
        <div>
          <h2 className="text-lg font-semibold text-white">API Providers</h2>
          <p className="mt-0.5 text-xs text-[var(--text-tertiary)]">
            添加 OpenAI 兼容接口。模型列表可自动从 /v1/models 获取。
          </p>
        </div>
        <button
          onClick={startAdd}
          className="flex items-center gap-1.5 rounded-xl bg-[var(--accent)] px-3 py-2 text-sm font-semibold text-white hover:bg-[var(--accent-strong)]"
        >
          <Plus size={16} />
          添加
        </button>
      </div>

      {/* Add form */}
      {editingId === "new" && (
        <ProviderForm
          form={form}
          setForm={setForm}
          onFetchModels={handleFetchModels}
          fetchingModels={fetchingModels}
          onSave={handleSave}
          onCancel={cancelEdit}
          saving={saving}
          title="添加 Provider"
        />
      )}

      {/* Provider list */}
      {loading ? (
        <p className="text-sm text-[var(--text-tertiary)]">加载中...</p>
      ) : (
        <div className="space-y-2">
          {providers.map((p) => (
            <div key={p.id}>
              <div className="flex items-center gap-3 rounded-xl border border-[var(--border)] bg-[var(--surface)] px-3 py-3">
                <div
                  className="h-2.5 w-2.5 shrink-0 rounded-full"
                  style={{ backgroundColor: `#${p.color_hex || "6B7280"}` }}
                />
                <div className="min-w-0 flex-1">
                  <p className="text-sm font-medium text-white">{p.name}</p>
                  <p className="truncate text-xs text-[var(--text-tertiary)]">
                    {p.base_url} · {p.models?.[0] || "模型未配置"}
                    {p.models?.length > 1 && ` +${p.models.length - 1}`}
                  </p>
                </div>
                <div className="flex shrink-0 items-center gap-1">
                  {reachability[p.id] === "ok" && <Check size={14} className="text-green-400" />}
                  {reachability[p.id] === "fail" && <span className="text-xs text-red-400">✗</span>}
                  {reachability[p.id] === "checking" && <RefreshCw size={12} className="animate-spin text-[var(--text-tertiary)]" />}
                  <button
                    onClick={() => handleCheckReachability(p)}
                    className="grid h-8 w-8 place-items-center rounded-full text-[var(--text-tertiary)] hover:bg-[var(--hover-bg)]"
                    title="测试连接"
                  >
                    <Wifi size={14} />
                  </button>
                  <button
                    onClick={() => editingId === p.id ? cancelEdit() : startEdit(p)}
                    className="grid h-8 w-8 place-items-center rounded-full text-[var(--text-tertiary)] hover:bg-[var(--hover-bg)]"
                    title="编辑"
                  >
                    {editingId === p.id ? <ChevronUp size={14} /> : <Edit2 size={14} />}
                  </button>
                  {!p.is_builtin && (
                    <button
                      onClick={() => handleDelete(p.id)}
                      className="grid h-8 w-8 place-items-center rounded-full text-red-400/60 hover:bg-red-500/10 hover:text-red-400"
                      title="删除"
                    >
                      <Trash2 size={14} />
                    </button>
                  )}
                </div>
              </div>
              {editingId === p.id && (
                <div className="mt-1 rounded-xl border border-[var(--accent)]/30 bg-[var(--surface)] p-3">
                  <ProviderForm
                    form={form}
                    setForm={setForm}
                    onFetchModels={handleFetchModels}
                    fetchingModels={fetchingModels}
                    onSave={handleSave}
                    onCancel={cancelEdit}
                    saving={saving}
                    title="编辑 Provider"
                    isBuiltin={p.is_builtin}
                  />
                </div>
              )}
            </div>
          ))}
        </div>
      )}

      {/* Schedule agent provider */}
      <div className="rounded-2xl border border-[var(--border)] bg-[var(--surface)] p-4 space-y-2">
        <p className="text-sm font-semibold text-white">Schedule Agent Provider</p>
        <select
          value={scheduleProviderId}
          onChange={(e) => saveScheduleProvider(e.target.value)}
          className="min-h-10 w-full rounded-xl border border-[var(--border)] bg-[var(--input-bg)] px-3 text-sm text-white focus:outline-none"
        >
          {providers.map((p) => (
            <option key={p.id} value={p.id}>{p.name}</option>
          ))}
        </select>
        <p className="text-xs text-[var(--text-tertiary)]">
          日程 Agent 使用这个 Provider 处理对话。
        </p>
      </div>
    </div>
  );
}

// ── Provider form (add / edit) ────────────────────────────────────────────────
function ProviderForm({ form, setForm, onFetchModels, fetchingModels, onSave, onCancel, saving, title, isBuiltin }) {
  const f = (key) => (e) => setForm((prev) => ({ ...prev, [key]: e.target.value }));

  return (
    <div className="space-y-3">
      <p className="text-sm font-semibold text-[var(--text-secondary)]">{title}</p>
      <div className="grid gap-3 sm:grid-cols-2">
        <label className="block">
          <span className="mb-1 block text-xs font-medium text-[var(--text-tertiary)]">Provider 名称</span>
          <input
            value={form.name}
            onChange={f("name")}
            placeholder="我的 Provider"
            className="min-h-10 w-full rounded-xl border border-[var(--border)] bg-[var(--input-bg)] px-3 text-sm text-white placeholder-[var(--text-tertiary)] focus:outline-none focus:ring-2 focus:ring-[var(--accent-ring)]"
          />
        </label>
        <label className="block">
          <span className="mb-1 block text-xs font-medium text-[var(--text-tertiary)]">Base URL</span>
          <input
            value={form.base_url}
            onChange={f("base_url")}
            placeholder="https://api.example.com"
            disabled={isBuiltin}
            className="min-h-10 w-full rounded-xl border border-[var(--border)] bg-[var(--input-bg)] px-3 text-sm text-white placeholder-[var(--text-tertiary)] focus:outline-none focus:ring-2 focus:ring-[var(--accent-ring)] disabled:opacity-50"
          />
        </label>
      </div>
      <label className="block">
        <span className="mb-1 block text-xs font-medium text-[var(--text-tertiary)]">API Key</span>
        <input
          type="password"
          value={form.api_key}
          onChange={f("api_key")}
          placeholder="sk-..."
          className="min-h-10 w-full rounded-xl border border-[var(--border)] bg-[var(--input-bg)] px-3 text-sm text-white placeholder-[var(--text-tertiary)] focus:outline-none focus:ring-2 focus:ring-[var(--accent-ring)]"
        />
      </label>

      {/* Models */}
      <div>
        <div className="flex items-center justify-between mb-1">
          <span className="text-xs font-medium text-[var(--text-tertiary)]">
            模型列表 {form.models.length > 0 && `(${form.models.length} 个)`}
          </span>
          <button
            onClick={onFetchModels}
            disabled={fetchingModels || !form.base_url || !form.api_key}
            className="flex items-center gap-1 rounded-lg border border-[var(--border)] px-2 py-1 text-xs text-[var(--text-secondary)] hover:bg-[var(--hover-bg)] disabled:opacity-40"
          >
            <RefreshCw size={11} className={fetchingModels ? "animate-spin" : ""} />
            自动获取
          </button>
        </div>
        <textarea
          value={form.models.join("\n")}
          onChange={(e) => setForm((f) => ({ ...f, models: e.target.value.split("\n").map((s) => s.trim()).filter(Boolean) }))}
          placeholder="每行一个模型 ID，或点击自动获取"
          rows={3}
          className="w-full rounded-xl border border-[var(--border)] bg-[var(--input-bg)] px-3 py-2 text-xs text-white placeholder-[var(--text-tertiary)] focus:outline-none focus:ring-2 focus:ring-[var(--accent-ring)]"
        />
      </div>

      <div className="flex gap-2">
        <button
          onClick={onSave}
          disabled={saving || !form.name || !form.base_url}
          className="rounded-xl bg-[var(--accent)] px-4 py-2 text-sm font-semibold text-white hover:bg-[var(--accent-strong)] disabled:opacity-50"
        >
          {saving ? "保存中..." : "保存"}
        </button>
        <button
          onClick={onCancel}
          className="rounded-xl border border-[var(--border)] px-4 py-2 text-sm text-[var(--text-secondary)] hover:bg-[var(--hover-bg)]"
        >
          取消
        </button>
      </div>
    </div>
  );
}
```

### 验证

1. 设置页 → Provider 列表显示内置 + Mimo 预置条目
2. 点"添加"，填写 base_url + api_key，点"自动获取"，模型列表自动填入
3. 保存后，新 Provider 出现在列表，能在 Schedule Agent Provider 选择它
4. 删除自定义 Provider 成功，内置条目不显示删除按钮

---

## 部署命令

```bash
# 后端改动
rsync -az --exclude='__pycache__' --exclude='*.pyc' -e ssh \
  /Users/macalan/Documents/chatbot/web/backend/app/ \
  aliyun-root:/opt/chatbot/backend/app/
ssh aliyun-root "cd /opt/chatbot && docker compose build backend && docker compose up -d --force-recreate backend"

# 前端改动
rsync -az --exclude='node_modules' --exclude='dist' -e ssh \
  /Users/macalan/Documents/chatbot/web/frontend/ \
  aliyun-root:/opt/chatbot/frontend/
ssh aliyun-root "cd /opt/chatbot && docker compose build frontend && docker compose up -d --force-recreate frontend"

# 验证
ssh aliyun-root "docker logs chatbot-backend-1 --tail 10 2>&1"
```

---

## 实现顺序（原 A-D）

| 顺序 | 模块 | 依赖 |
|------|------|------|
| 1 | Module A（导出/导入） | 独立 |
| 2 | Module D（Provider 列表） | 独立，但影响 Agent 可用模型 |
| 3 | Module B（Push debug） | 需要先部署，在服务器上执行测试 |
| 4 | Module C（自动新 Session） | 独立前端改动 |

---

## Module E — Token 优化 + Chat 调控工具

### E1：Standby Agent 跳过无变化的重复调用

**原理**：standby_agent 每 N 分钟运行，但如果 reminders / memory_entries / notification_log 三张表自上次运行后没有任何新写入，LLM 的输入与上次完全相同，必然输出 `no_action`——这次调用是纯浪费。

**修改文件**：`backend/app/tasks/standby_agent.py`

在 `run_standby_agent` 里，LLM 调用前加 context hash 检查：

```python
# 在 "Build context" 注释之前插入

async def _compute_context_hash(db_path: str) -> str:
    """Hash of the 3 tables that affect standby decisions. Cheap DB read."""
    import hashlib
    async with aiosqlite.connect(db_path) as db:
        r1 = await (await db.execute(
            "SELECT MAX(updated_at) FROM server_reminders WHERE is_completed=0"
        )).fetchone()
        r2 = await (await db.execute(
            "SELECT MAX(updated_at) FROM chaoxing_memory_entries WHERE archived_at IS NULL"
        )).fetchone()
        r3 = await (await db.execute(
            "SELECT MAX(sent_at) FROM notification_log"
        )).fetchone()
    raw = f"{r1[0]}|{r2[0]}|{r3[0]}"
    return hashlib.md5(raw.encode()).hexdigest()
```

在 `run_standby_agent` 里，计算 hash 并与上次比对：

```python
# 在 sub_count 检查之后、context build 之前：
current_hash = await _compute_context_hash(db_path)

# 取上次 hash（存在 standby_agent_log 里，decision != 'error' 的最近一条）
async with aiosqlite.connect(db_path) as db:
    last_row = await (await db.execute("""
        SELECT push_title FROM standby_agent_log
        WHERE decision != 'error'
        ORDER BY ran_at DESC LIMIT 1
    """)).fetchone()
    # 复用 push_title 列存 hash（如果 decision=no_action push_title 是 NULL，存在 push_body 里）
    last_hash_row = await (await db.execute("""
        SELECT push_body FROM standby_agent_log
        WHERE decision = 'no_action'
        ORDER BY ran_at DESC LIMIT 1
    """)).fetchone()

last_hash = (last_hash_row[0] or "") if last_hash_row else ""
if last_hash == current_hash:
    # Nothing changed since last run — skip LLM
    async with aiosqlite.connect(db_path) as db:
        await db.execute(
            "INSERT INTO standby_agent_log (ran_at, decision, model, input_tokens, output_tokens, duration_ms) VALUES (?,?,?,?,?,?)",
            (now.isoformat(), "skipped_no_change", model, 0, 0, 0),
        )
        await db.commit()
    return
```

在 `no_action` 分支的 log 写入处，把 `current_hash` 存入 `push_body`：

```python
# 修改最终的 log INSERT，当 decision=no_action 时把 hash 写入 push_body
await db.execute(
    """INSERT INTO standby_agent_log
       (ran_at, decision, push_title, push_body, model, input_tokens, output_tokens, duration_ms)
       VALUES (?,?,?,?,?,?,?,?)""",
    (now.isoformat(), decision,
     push_title,
     current_hash if decision == "no_action" else push_body,   # ← store hash when no_action
     model, input_tokens, output_tokens, duration_ms),
)
```

**预期效果**：无新事件时，standby_agent 跳过 LLM，节省 ~80% 的调用次数。

---

### E2：Memory Agent active_memory context 压缩

**原理**：`memory_agent.py` 的 `_user_payload` 给 LLM 发的 active_memory 每条有 8 个字段（id, dedupe_key, title, summary, action_hint, importance, sent_at, expires_at），LLM 只用 `dedupe_key + title` 来判断是否重复，其余 6 个字段是噪声。

**修改文件**：`backend/app/services/memory_agent.py`

找到 `_user_payload` 里的 `memory_summary` 列表构建（约第 138 行），改为：

```python
# 改前（8 字段）：
memory_summary = [
    {
        "dedupe_key": m.get("dedupe_key"),
        "title": m.get("title"),
        "summary": m.get("summary"),
        "expires_at": m.get("expires_at"),
    }
    for m in active_memory_entries[:30]
]

# 改后（3 字段，~60% token 减少）：
memory_summary = [
    {
        "k": m.get("dedupe_key"),   # key for dedup
        "t": m.get("title"),        # title for reference
        "x": m.get("expires_at"),   # expiry so LLM knows if still active
    }
    for m in active_memory_entries[:20]  # 30 → 20 也足够
]
```

同时在 system_prompt 里更新说明：

```python
# 找到 "Active memory summary:" 那行，修改提示让 LLM 知道字段缩写
"""Active memory (k=dedupe_key, t=title, x=expires_at):
{json.dumps(memory_summary, ensure_ascii=False)}"""
```

---

### E3：Schedule Agent 调控工具（Chat 作为控制面）

给 schedule_agent 加四个工具，让 chat 能感知和控制整个系统。

**修改文件**：`backend/app/services/schedule_agent.py`

**1. 工具定义**（加入 `_TOOL_DEFS` 列表）：

```python
{
    "name": "get_memory_insights",
    "description": "查询学习通 Memory，返回最近重要的通知和事项。用户问到学习通消息、最近通知、重要事项时调用。",
    "input_schema": {
        "type": "object",
        "properties": {
            "limit": {"type": "integer", "description": "返回条数，默认 10"},
            "importance": {"type": "string", "enum": ["high", "medium", "all"], "description": "重要度过滤"},
        },
    },
},
{
    "name": "get_system_status",
    "description": "查看系统运行状态：standby agent 最近决策、待发通知数、学习通登录状态、内存条目数。",
    "input_schema": {"type": "object", "properties": {}},
},
{
    "name": "trigger_memory_scan",
    "description": "立刻触发一次学习通消息扫描（异步，不等结果）。用户说'立刻检查学习通'或'帮我扫一下'时调用。",
    "input_schema": {"type": "object", "properties": {}},
},
{
    "name": "set_push_config",
    "description": "设置推送静默时段或调整 standby 间隔。",
    "input_schema": {
        "type": "object",
        "properties": {
            "quiet_until": {"type": "string", "description": "ISO-8601 datetime，到这个时间之前不推送"},
            "standby_interval_minutes": {"type": "integer", "description": "standby agent 检查间隔（分钟），最小 5"},
        },
    },
},
```

**2. 工具执行**（在 `_execute_schedule_tool` 里新增）：

```python
elif name == "get_memory_insights":
    limit = int(args.get("limit") or 10)
    importance = args.get("importance", "all")
    async with aiosqlite.connect(db_path) as db:
        where = "" if importance == "all" else f"AND importance='{importance}'"
        rows = await (await db.execute(f"""
            SELECT title, summary, action_hint, importance, category,
                   content_time, expires_at
            FROM chaoxing_memory_entries
            WHERE archived_at IS NULL
            AND (expires_at IS NULL OR expires_at > datetime('now'))
            {where}
            ORDER BY CASE importance WHEN 'high' THEN 1 WHEN 'medium' THEN 2 ELSE 3 END,
                     COALESCE(content_time, updated_at, sent_at) DESC
            LIMIT ?
        """, (limit,))).fetchall()
    entries = [dict(zip(["title","summary","action_hint","importance","category","content_time","expires_at"], r)) for r in rows]
    if not entries:
        return json.dumps({"ok": True, "count": 0, "message": "暂无未过期的 Memory 条目。"})
    return json.dumps({"ok": True, "count": len(entries), "entries": entries}, ensure_ascii=False)

elif name == "get_system_status":
    async with aiosqlite.connect(db_path) as db:
        standby_rows = await (await db.execute(
            "SELECT ran_at, decision, push_title, input_tokens FROM standby_agent_log ORDER BY ran_at DESC LIMIT 3"
        )).fetchall()
        pending_notifs = (await (await db.execute(
            "SELECT COUNT(*) FROM scheduled_notifications WHERE sent_at IS NULL AND cancelled_at IS NULL"
        )).fetchone())[0]
        memory_count = (await (await db.execute(
            "SELECT COUNT(*) FROM chaoxing_memory_entries WHERE archived_at IS NULL"
        )).fetchone())[0]
        sub_count = (await (await db.execute("SELECT COUNT(*) FROM push_subscriptions")).fetchone())[0]
    return json.dumps({
        "ok": True,
        "push_subscribers": sub_count,
        "pending_notifications": pending_notifs,
        "active_memory_entries": memory_count,
        "recent_standby_decisions": [
            {"ran_at": r[0], "decision": r[1], "push_title": r[2], "tokens": r[3]}
            for r in standby_rows
        ],
    }, ensure_ascii=False)

elif name == "trigger_memory_scan":
    # Fire and forget
    import asyncio as _asyncio
    from app.tasks.memory_sweep import run_memory_sweep
    _asyncio.create_task(run_memory_sweep(chaoxing_svc.app_state if hasattr(chaoxing_svc, 'app_state') else None))
    return json.dumps({"ok": True, "message": "已触发学习通扫描，结果将在约 1 分钟内更新。"})

elif name == "set_push_config":
    quiet_until = args.get("quiet_until")
    interval = args.get("standby_interval_minutes")
    async with aiosqlite.connect(db_path) as db:
        if quiet_until:
            await db.execute(
                "INSERT OR REPLACE INTO settings (key, value) VALUES ('push_quiet_until', ?)",
                (quiet_until,),
            )
        if interval and int(interval) >= 5:
            await db.execute(
                "INSERT OR REPLACE INTO settings (key, value) VALUES ('standby_interval_minutes', ?)",
                (str(interval),),
            )
        await db.commit()
    parts = []
    if quiet_until:
        parts.append(f"已设置静默到 {quiet_until}")
    if interval:
        parts.append(f"standby 间隔改为 {interval} 分钟")
    return json.dumps({"ok": True, "message": "；".join(parts) or "配置已更新。"})
```

**3. 传 app_state**

`schedule.py` 的 `stream_schedule_chat` 已经拿到 `request.app.state.chaoxing_svc`，把 `app.state` 也传下去：

```python
# schedule.py stream_schedule_chat 里
chaoxing_svc = request.app.state.chaoxing_svc
app_state = request.app.state  # 新增

# 传给 run_schedule_agent
async for event in run_schedule_agent(
    user_message, history, provider, model, api_key,
    chaoxing_svc, settings.database_path,
    app_state=app_state,   # 新增
):
```

`schedule_agent.py` 的 `run_schedule_agent` 和 `_execute_schedule_tool` 签名接收 `app_state=None`，`trigger_memory_scan` 里用它。

---

## Module F — 完整 E2E Debug Playbook

> **给 Coding Agent：先实现 Module E 的 E3 工具，再按本模块执行测试。**
>
> **并行策略**：Phase 1 启动两个 sub-agent 并行。每个 sub-agent 操作不同 test ID 前缀，不冲突。
> Phase 2 在 Phase 1 全部 PASS 后执行。

---

### F0：环境准备（每次测试前执行）

```bash
# 确认后端运行正常
ssh aliyun-root "docker logs chatbot-backend-1 --tail 5 2>&1 | grep -E 'startup|ERROR'"

# 确认有 push 订阅（没有的话 push 测试无意义）
ssh aliyun-root 'docker exec chatbot-backend-1 python3 -c "
import sqlite3
db = sqlite3.connect(\"/data/chatbot.db\")
print(\"push_subscriptions:\", db.execute(\"SELECT COUNT(*) FROM push_subscriptions\").fetchone()[0])
"'

# 清理旧测试数据（前缀 test-f* 的全清）
ssh aliyun-root 'docker exec chatbot-backend-1 python3 -c "
import sqlite3
db = sqlite3.connect(\"/data/chatbot.db\")
db.execute(\"DELETE FROM chaoxing_memory_entries WHERE id LIKE \"%test-f%\"\")
db.execute(\"DELETE FROM scheduled_notifications WHERE title LIKE \"%[TEST]%\"\")
db.execute(\"DELETE FROM notification_log WHERE item_id LIKE \"%test-f%\"\")
db.execute(\"DELETE FROM standby_agent_log WHERE push_title LIKE \"%[TEST]%\"\")
db.commit()
print(\"cleaned\")
"'
```

---

### Phase 1 — 并行执行（Sub-agent A + Sub-agent B 同时启动）

---

#### Sub-agent A：F1 Standby Auto-Push + F3 Chat Memory Access

---

##### F1：Standby Agent 自主推送决策

**Step 1：注入高优先级 memory 条目**

```bash
ssh aliyun-root 'docker exec chatbot-backend-1 python3 -c "
import sqlite3, uuid
from datetime import datetime, timezone, timedelta

db = sqlite3.connect(\"/data/chatbot.db\")
now = datetime.now(timezone.utc)
eid = \"test-f1-\" + uuid.uuid4().hex[:8]
expires = (now + timedelta(days=7)).isoformat()

db.execute(\"\"\"
    INSERT INTO chaoxing_memory_entries
    (id, title, summary, reason, action_hint, importance, category,
     extracted_at, sent_at, expires_at, archived_at, dedupe_key, confidence, created_at, updated_at,
     source_ids_json, source_fingerprints_json, conversation_ids_json, conversation_names_json, sender_names_json)
    VALUES (?,?,?,?,?,?,?,?,?,?,NULL,?,?,?,?,?,?,?,?,?)
\"\"\", (
    eid,
    \"[TEST] 期末考试时间确认\",
    \"数学分析期末考试于下周三14:00在A101进行\",
    \"重要考试通知\",
    \"下周三14:00去A101参加数学分析期末考试\",
    \"high\",
    \"exam\",
    now.isoformat(), now.isoformat(), expires,
    \"test-f1-exam-final\",
    0.95,
    now.isoformat(), now.isoformat(),
    \"[\\\"test-msg-f1\\\"]\", \"[\\\"fp-f1\\\"]\",
    \"[\\\"conv-f1\\\"]\", \"[\\\"高等数学A\\\"]\", \"[\\\"张老师\\\"]\"
))
db.commit()
print(\"entry_id:\", eid)
"'
```

**Step 2：手动触发 standby agent**

```bash
ssh aliyun-root 'docker exec chatbot-backend-1 python3 -c "
import asyncio, sys
sys.path.insert(0, \"/app\")
from app.main import app
from app.tasks.standby_agent import run_standby_agent

async def run():
    await run_standby_agent(app.state)
    import sqlite3
    db = sqlite3.connect(\"/data/chatbot.db\")
    db.row_factory = sqlite3.Row
    row = db.execute(\"SELECT ran_at, decision, push_title, push_body, input_tokens FROM standby_agent_log ORDER BY ran_at DESC LIMIT 1\").fetchone()
    print(\"Last run:\", dict(row))

asyncio.run(run())
"'
```

**PASS 条件**：`decision=push`，`push_title` 包含"考试"或"期末"字样

**Step 3：再次触发（验证 context hash skip 生效）**

```bash
# 同上命令再跑一次
```

**PASS 条件**：`decision=skipped_no_change`（E1 实现后），或 `decision=no_action`（E1 未实现时）

**如果 F1 FAIL（decision=no_action 而不是 push）**：
- 检查 `push_subscriptions` 是否为 0 → 需要先在 iOS 上订阅
- 检查 system_prompt 里的决策标准，确认 high importance + action_hint 应该触发 push
- 检查 `has_notified` 是否已有该 entry_id 的 standby_agent 记录（第一次应该没有）

**Step 4：验证 notification_log 有记录**

```bash
ssh aliyun-root 'docker exec chatbot-backend-1 python3 -c "
import sqlite3
db = sqlite3.connect(\"/data/chatbot.db\")
db.row_factory = sqlite3.Row
rows = db.execute(\"SELECT item_id, notif_type, sent_at, device_received_at FROM notification_log WHERE item_id LIKE \"%test-f1%\" ORDER BY sent_at DESC\").fetchall()
for r in rows: print(dict(r))
"'
```

**PASS 条件**：有一条 `notif_type=standby_agent`，`sent_at` 非 NULL

---

##### F3：Chat Agent Memory Access（依赖 E3 实现）

**Step 1：发送请求验证 get_memory_insights 工具被调用**

```bash
ssh aliyun-root 'docker exec chatbot-backend-1 python3 -c "
import asyncio, sys, json
sys.path.insert(0, \"/app\")
from app.services.schedule_agent import run_schedule_agent
from app.main import app
from app.config import settings
from app.services.provider_registry import resolve_provider

async def test():
    provider, api_key = await resolve_provider(\"xiaomimimo\")
    model = (provider.get(\"models\") or [\"mimo-v2.5-pro\"])[0]
    events = []
    async for ev in run_schedule_agent(
        \"最近学习通有什么重要通知？\",
        [],
        provider, model, api_key,
        app.state.chaoxing_svc,
        settings.database_path,
    ):
        events.append(ev)
        if ev[\"type\"] == \"text\":
            print(ev[\"content\"], end=\"\", flush=True)
    print()
    has_tool = any(e[\"type\"] == \"tool_start\" and e.get(\"tool\") == \"get_memory_insights\" for e in events)
    print(\"used get_memory_insights:\", has_tool)
    print(\"PASS\" if has_tool else \"FAIL: tool not called\")

asyncio.run(test())
"'
```

**PASS 条件**：输出包含"期末考试"相关内容，`used get_memory_insights: True`

**如果 FAIL**：E3 的工具定义没加对，检查 `_TOOL_DEFS` 里是否有 `get_memory_insights`

---

#### Sub-agent B：F2 Memory Pipeline 注入测试

##### F2：完整 Memory 提取 Pipeline（注入假消息）

**Step 1：直接调用 pipeline，绕过 chaoxing HTTP 请求**

```bash
ssh aliyun-root 'docker exec chatbot-backend-1 python3 -c "
import asyncio, sys, json
from datetime import datetime, timezone, timedelta
sys.path.insert(0, \"/app\")
from app.services.chaoxing_message_filter import run as filter_run
from app.services.memory_agent import _extract_with_llm, _user_payload
from app.services.memory_reducer import reduce_memory, get_insights
from app.services.provider_registry import resolve_provider
from app.config import settings

FAKE_MESSAGES = [
    {
        \"id\": \"test-f2-msg-001\",
        \"conversation_id\": \"test-f2-conv\",
        \"conversation_name\": \"线性代数(2025秋)\",
        \"is_group\": True,
        \"sender_id\": \"teacher-f2\",
        \"sender_name\": \"李老师\",
        \"sent_at\": datetime.now(timezone.utc).isoformat(),
        \"type\": \"TEXT\",
        \"text\": \"同学们：下周四（12月26日）第3-4节线代课调到下周五（12月27日）同时间段，地点改为B202。\",
        \"image_urls\": [],
    }
]

async def run():
    now = datetime.now(timezone.utc)
    sync_state = {
        \"processed_source_ids\": set(),
        \"processed_fingerprints\": set(),
        \"initialized_at\": now.isoformat(),
        \"conversations\": {},
    }
    result = filter_run(FAKE_MESSAGES, sync_state, assignments=[])
    candidates = result[\"candidates\"]
    print(f\"filter result: {len(candidates)} candidates, dropped: {result['dropped_reasons']}\")
    if not candidates:
        print(\"FAIL: message was filtered out\")
        return

    provider, api_key = await resolve_provider(\"xiaomimimo\")
    model = (provider.get(\"models\") or [\"mimo-v2.5-pro\"])[0]
    active_memory = await get_insights(settings.database_path, now, limit=10)
    extracted = await _extract_with_llm(candidates, [], [], active_memory, provider, model, api_key, now)
    print(\"extracted:\", json.dumps(extracted, ensure_ascii=False, indent=2)[:500])
    
    kept = [e for e in extracted if e.get(\"decision\") == \"keep\"]
    print(f\"LLM kept: {len(kept)}/{len(extracted)}\")
    if not kept:
        print(\"FAIL: LLM dropped all messages\")
        return

    new_ids = await reduce_memory(extracted, candidates, set(), now, settings.database_path)
    print(\"stored memory entry ids:\", new_ids)
    print(\"PASS\" if new_ids else \"FAIL: nothing written to memory\")

asyncio.run(run())
"'
```

**PASS 条件**：`stored memory entry ids: [...]` 非空，表示 memory entry 已写入

**Step 2：验证 notification_scheduler 已为该 entry 安排推送**

```bash
ssh aliyun-root 'docker exec chatbot-backend-1 python3 -c "
import asyncio, sys
from datetime import datetime, timezone
sys.path.insert(0, \"/app\")
from app.services.memory_reducer import get_insights
from app.services.notification_scheduler import auto_schedule_from_memory
from app.config import settings

async def run():
    now = datetime.now(timezone.utc)
    entries = await get_insights(settings.database_path, now, limit=5)
    course_change_entries = [e for e in entries if \"线代\" in (e.get(\"title\") or \"\") or \"线性代数\" in (e.get(\"title\") or \"\")]
    print(\"course_change entries found:\", len(course_change_entries))
    
    import sqlite3
    db = sqlite3.connect(settings.database_path)
    db.row_factory = sqlite3.Row
    rows = db.execute(\"SELECT title, scheduled_at, sent_at FROM scheduled_notifications WHERE title LIKE \"%线%\" ORDER BY created_at DESC LIMIT 3\").fetchall()
    for r in rows: print(dict(r))
    print(\"PASS\" if rows else \"FAIL: no notification scheduled\")

asyncio.run(run())
"'
```

**PASS 条件**：`scheduled_notifications` 中有对应条目（category=course_change 触发 8 分钟后 rule）

**如果 FAIL（LLM 返回 drop）**：
- 检查 system_prompt 里是否明确说明"调课"应该 keep
- 检查 `importance` —— reducer 要求 importance in (high, medium)，调课一般是 medium
- 检查 `confidence` — 需要 >= 0.55

---

### Phase 2 — 顺序执行（Phase 1 全部 PASS 后）

---

#### F4：每日晨报 + 晚报 Push

**F4a：晨报测试**

```bash
# Step 1: 确保今天的 daily-begin 没有发过（清除记录）
ssh aliyun-root 'docker exec chatbot-backend-1 python3 -c "
import sqlite3
from datetime import datetime, timezone, timedelta
db = sqlite3.connect(\"/data/chatbot.db\")
today = (datetime.now(timezone.utc) + timedelta(hours=8)).strftime(\"%Y-%m-%d\")
notif_id = f\"daily-begin-{today}\"
db.execute(\"DELETE FROM notification_log WHERE item_id=?\", (notif_id,))
db.commit()
print(\"cleared daily-begin for\", today)
"'

# Step 2: 插入今天有课的数据（使 context 非空）
ssh aliyun-root 'docker exec chatbot-backend-1 python3 -c "
import sqlite3, uuid
from datetime import datetime, timezone, timedelta
db = sqlite3.connect(\"/data/chatbot.db\")
now = datetime.now(timezone.utc)
# 今天 CST 8:00 开始的课
local_start = (now + timedelta(hours=8)).replace(hour=8, minute=0, second=0, microsecond=0)
start_utc = (local_start - timedelta(hours=8)).isoformat()
end_utc = (local_start - timedelta(hours=8) + timedelta(hours=2)).isoformat()
db.execute(\"INSERT OR IGNORE INTO server_courses (id, title, calendar_name, start_at, end_at, location, notes, created_at, updated_at) VALUES (?,?,?,?,?,?,?,?,?)\",
    (\"test-f4-course\", \"[TEST] 高等数学A\", \"测试课程\", start_utc, end_utc, \"A101\", None, now.isoformat(), now.isoformat()))
db.commit()
print(\"inserted test course\")
"'

# Step 3: 触发晨报
ssh aliyun-root 'docker exec chatbot-backend-1 python3 -c "
import asyncio, sys
sys.path.insert(0, \"/app\")
from app.main import app
from app.tasks.notification_sender import send_daily_begin

async def run():
    await send_daily_begin(app.state)
    import sqlite3
    db = sqlite3.connect(\"/data/chatbot.db\")
    db.row_factory = sqlite3.Row
    from datetime import datetime, timezone, timedelta
    today = (datetime.now(timezone.utc) + timedelta(hours=8)).strftime(\"%Y-%m-%d\")
    row = db.execute(\"SELECT * FROM notification_log WHERE item_id=?\", (f\"daily-begin-{today}\",)).fetchone()
    if row:
        print(\"PASS - sent:\", dict(row).get(\"push_title\"))
    else:
        print(\"FAIL: daily-begin not logged\")

asyncio.run(run())
"'
```

**PASS 条件**：notification_log 有 `item_id=daily-begin-YYYY-MM-DD`，`push_title` 非空

**如果 FAIL（title/body 为空）**：
- 检查 LLM provider 是否有效（api_key 是否配置）
- fallback 应该生效：检查 `_fallback_daily_begin` 是否返回了有内容的 tuple
- 检查 `has_notified` 是否认为已发过（需要先清理记录）

**F4b：晚报测试**（与 F4a 同结构，改 `send_daily_summary_evening`，清 `daily-evening-{today}` 记录）

---

#### F5：Dashboard Summary 验证

**Step 1：插入足够的测试数据**

```bash
ssh aliyun-root 'docker exec chatbot-backend-1 python3 -c "
import sqlite3, uuid
from datetime import datetime, timezone, timedelta
db = sqlite3.connect(\"/data/chatbot.db\")
now = datetime.now(timezone.utc)

# 2 条 reminders
for i, title in enumerate([\"[TEST] 复习数学\", \"[TEST] 提交作业报告\"]):
    due = (now + timedelta(hours=6 + i * 12)).isoformat()
    db.execute(\"INSERT OR IGNORE INTO server_reminders (id, title, list_name, due_at, is_completed, is_important, created_at, updated_at) VALUES (?,?,?,?,?,?,?,?)\",
        (f\"test-f5-rem-{i}\", title, \"默认\", due, 0, 1, now.isoformat(), now.isoformat()))

db.commit()
print(\"test data inserted\")
"'
```

**Step 2：调用 sidebar API 验证数据返回**

```bash
ssh aliyun-root 'docker exec chatbot-backend-1 python3 -c "
import asyncio, sys
sys.path.insert(0, \"/app\")
import urllib.request, json
r = urllib.request.urlopen(\"http://localhost:8000/api/schedule/sidebar\")
data = json.loads(r.read())
print(\"reminders:\", len(data.get(\"reminders\", [])))
print(\"memory_insights:\", len(data.get(\"memory_insights\", [])))
print(\"local_courses:\", len(data.get(\"local_courses\", [])))
print(\"chaoxing_logged_in:\", data.get(\"chaoxing_logged_in\"))
has_data = len(data.get(\"reminders\", [])) > 0
print(\"PASS\" if has_data else \"FAIL: reminders empty\")
"'
```

**PASS 条件**：`reminders >= 2`，`chaoxing_logged_in` 字段存在

---

#### F6：调课消息 → 课程表更新

> **前提**：E3 的 `get_memory_insights` 工具已实现，且 F2 已创建一个 course_change memory entry

**新功能实现（同步写入 schedule_agent.py）**：

在 `_TOOL_DEFS` 里加 `apply_course_change` 工具：

```python
{
    "name": "apply_course_change",
    "description": "根据学习通调课通知，更新 server_courses 里对应的课程行。先用 get_memory_insights 找到 course_change 条目，再调用此工具。需要确认原课程日期和新课程日期/时间/地点。",
    "input_schema": {
        "type": "object",
        "properties": {
            "memory_entry_id": {"type": "string", "description": "课程变更的 memory entry ID，可从 get_memory_insights 获取"},
            "original_date": {"type": "string", "description": "原课程日期 YYYY-MM-DD"},
            "new_date": {"type": "string", "description": "新课程日期 YYYY-MM-DD"},
            "new_start_time": {"type": "string", "description": "新开始时间 HH:MM，不变则不填"},
            "new_end_time": {"type": "string", "description": "新结束时间 HH:MM，不变则不填"},
            "new_location": {"type": "string", "description": "新地点，不变则不填"},
        },
        "required": ["memory_entry_id", "original_date", "new_date"],
    },
},
```

执行逻辑（加入 `_execute_schedule_tool`）：

```python
elif name == "apply_course_change":
    mem_id = args.get("memory_entry_id")
    orig_date = args.get("original_date")  # YYYY-MM-DD
    new_date = args.get("new_date")
    new_start = args.get("new_start_time")  # HH:MM or None
    new_end = args.get("new_end_time")
    new_location = args.get("new_location")

    async with aiosqlite.connect(db_path) as db:
        # Find the memory entry to get linked_course_key
        mem = await (await db.execute(
            "SELECT title, linked_course_key FROM chaoxing_memory_entries WHERE id=?",
            (mem_id,),
        )).fetchone()
        if not mem:
            return json.dumps({"ok": False, "error": "memory entry not found"})

        course_keyword = (mem[1] or mem[0] or "").strip()

        # Find server_course rows on original_date whose title matches
        rows = await (await db.execute(
            "SELECT id, title, start_at, end_at, location FROM server_courses WHERE start_at LIKE ? AND title LIKE ?",
            (f"{orig_date}%", f"%{course_keyword.split('::')[-1]}%"),
        )).fetchall()

        if not rows:
            return json.dumps({"ok": False, "error": f"未找到 {orig_date} 的 {course_keyword} 课程行"})

        updated_count = 0
        for row in rows:
            row_id, title, old_start, old_end, old_loc = row
            from datetime import datetime as _dt, timezone as _tz
            orig_start = _dt.fromisoformat(old_start.replace("Z", "+00:00"))
            orig_end = _dt.fromisoformat(old_end.replace("Z", "+00:00"))

            # Build new start/end
            if new_start:
                h, m = map(int, new_start.split(":"))
                new_start_dt = orig_start.replace(
                    year=int(new_date[:4]), month=int(new_date[5:7]), day=int(new_date[8:]),
                    hour=h, minute=m,
                )
            else:
                new_start_dt = orig_start.replace(
                    year=int(new_date[:4]), month=int(new_date[5:7]), day=int(new_date[8:]),
                )
            if new_end:
                h2, m2 = map(int, new_end.split(":"))
                new_end_dt = new_start_dt.replace(hour=h2, minute=m2)
            else:
                duration = orig_end - orig_start
                new_end_dt = new_start_dt + duration

            await db.execute(
                "UPDATE server_courses SET start_at=?, end_at=?, location=COALESCE(?,location), updated_at=datetime('now') WHERE id=?",
                (new_start_dt.isoformat(), new_end_dt.isoformat(), new_location, row_id),
            )
            updated_count += 1

        await db.commit()

    return json.dumps({
        "ok": True,
        "updated_rows": updated_count,
        "message": f"已将 {course_keyword} 从 {orig_date} 调整到 {new_date}，共更新 {updated_count} 条课程记录。",
    }, ensure_ascii=False)
```

**Debug 测试**：

```bash
# 先插入一条待调整的课程和对应 memory entry
ssh aliyun-root 'docker exec chatbot-backend-1 python3 -c "
import sqlite3, uuid
from datetime import datetime, timezone, timedelta
db = sqlite3.connect(\"/data/chatbot.db\")
now = datetime.now(timezone.utc)

# 本周四 10:00 的线代课
thu_start = \"2026-05-28T02:00:00+00:00\"  # 周四 10:00 CST
thu_end   = \"2026-05-28T03:35:00+00:00\"
cid = \"test-f6-course\"
db.execute(\"INSERT OR REPLACE INTO server_courses (id, title, calendar_name, start_at, end_at, location, notes, created_at, updated_at) VALUES (?,?,?,?,?,?,?,?,?)\",
    (cid, \"[TEST] 线性代数\", \"导入课程表\", thu_start, thu_end, \"A101\", None, now.isoformat(), now.isoformat()))

# 对应的 memory entry
mid = \"test-f6-mem\"
expires = (now + timedelta(days=7)).isoformat()
db.execute(\"INSERT OR REPLACE INTO chaoxing_memory_entries (id, title, summary, reason, action_hint, importance, category, extracted_at, sent_at, expires_at, archived_at, dedupe_key, confidence, created_at, updated_at, source_ids_json, source_fingerprints_json, conversation_ids_json, conversation_names_json, sender_names_json, linked_course_key) VALUES (?,?,?,?,?,?,?,?,?,?,NULL,?,?,?,?,?,?,?,?,?,?)\",
    (mid, \"[TEST] 线代调课通知\", \"周四10:00线代课调到周五10:00，地点改B202\",
     \"调课通知\", \"周五10:00去B202上线代\", \"medium\", \"course_change\",
     now.isoformat(), now.isoformat(), expires, \"test-f6-course-change\",
     0.90, now.isoformat(), now.isoformat(),
     \"[]\", \"[]\", \"[]\", \"[\\\"线性代数\\\"]\", \"[]\",
     \"test::线性代数\"))
db.commit()
print(\"test data ready, course_id:\", cid, \"memory_id:\", mid)
"'

# 触发 chat 调用 apply_course_change
ssh aliyun-root 'docker exec chatbot-backend-1 python3 -c "
import asyncio, sys
sys.path.insert(0, \"/app\")
from app.services.schedule_agent import run_schedule_agent
from app.main import app
from app.config import settings
from app.services.provider_registry import resolve_provider

async def test():
    provider, api_key = await resolve_provider(\"xiaomimimo\")
    model = (provider.get(\"models\") or [\"mimo-v2.5-pro\"])[0]
    msg = \"帮我把学习通里的线代调课通知应用到课程表，原日期2026-05-28，新日期2026-05-29，地点B202\"
    async for ev in run_schedule_agent(msg, [], provider, model, api_key, app.state.chaoxing_svc, settings.database_path):
        if ev[\"type\"] == \"text\":
            print(ev[\"content\"], end=\"\")
    print()

    # 验证 server_courses 已更新
    import sqlite3
    db = sqlite3.connect(settings.database_path)
    row = db.execute(\"SELECT start_at, location FROM server_courses WHERE id=?\", (\"test-f6-course\",)).fetchone()
    if row:
        updated = \"2026-05-29\" in row[0]
        loc_ok = row[1] == \"B202\"
        print(f\"start_at updated: {updated}, location: {row[1]}\")
        print(\"PASS\" if updated and loc_ok else \"FAIL\")
    else:
        print(\"FAIL: course not found\")

asyncio.run(test())
"'
```

**PASS 条件**：`start_at` 包含 `2026-05-29`，`location = B202`

---

### F0 Cleanup：测试后清理

```bash
ssh aliyun-root 'docker exec chatbot-backend-1 python3 -c "
import sqlite3
db = sqlite3.connect(\"/data/chatbot.db\")
tables = [
    (\"chaoxing_memory_entries\", \"id LIKE \"%test-f%\"\"),
    (\"scheduled_notifications\", \"title LIKE \"%[TEST]%\"\"),
    (\"notification_log\", \"item_id LIKE \"%test-f%\"\"),
    (\"standby_agent_log\", \"push_title LIKE \"%[TEST]%\"\"),
    (\"server_courses\", \"id LIKE \"%test-f%\"\"),
    (\"server_reminders\", \"id LIKE \"%test-f%\"\"),
]
for table, where in tables:
    cur = db.execute(f\"DELETE FROM {table} WHERE {where}\")
    if cur.rowcount: print(f\"{table}: deleted {cur.rowcount}\")
db.commit()
print(\"all clean\")
"'
```

---

## Module G — UI 美化（iOS 26 设计风格）

### 设计原则

iOS 26 "Liquid Glass" 核心特征：
- **浮动元素**：Tab bar 和工具栏不贴边，浮在内容上方
- **玻璃材质**：强 backdrop-blur + 半透明 + 微发光边框
- **层次感**：多层阴影创造深度，卡片有轻微浮起效果
- **圆角**：更大更一致的圆角（squircle 风格）
- **动画**：弹性过渡，状态变化平滑
- **排版**：层次更分明，section header 更细腻

### G1：CSS 变量升级（`frontend/src/index.css`）

在 `:root` 的变量块里添加/更新：

```css
:root {
  /* 现有变量保持不变，新增以下 */

  /* Glass material */
  --glass-bg: rgba(28, 30, 38, 0.72);
  --glass-border: rgba(255, 255, 255, 0.12);
  --glass-border-bright: rgba(255, 255, 255, 0.22);
  --glass-shadow: 0 8px 32px rgba(0, 0, 0, 0.48), 0 1px 0 rgba(255,255,255,0.06) inset;
  --glass-shadow-sm: 0 2px 12px rgba(0, 0, 0, 0.36), 0 1px 0 rgba(255,255,255,0.05) inset;

  /* Floating tab bar */
  --tab-float-bg: rgba(22, 24, 30, 0.88);
  --tab-float-shadow: 0 4px 24px rgba(0,0,0,0.5), 0 1px 0 rgba(255,255,255,0.08) inset;

  /* Radius */
  --radius-card: 20px;
  --radius-btn: 14px;
  --radius-pill: 999px;

  /* Transitions */
  --ease-spring: cubic-bezier(0.34, 1.56, 0.64, 1);
  --ease-smooth: cubic-bezier(0.4, 0, 0.2, 1);
}

@media (prefers-color-scheme: light) {
  :root {
    --glass-bg: rgba(255, 255, 255, 0.70);
    --glass-border: rgba(0, 0, 0, 0.08);
    --glass-border-bright: rgba(0, 0, 0, 0.14);
    --glass-shadow: 0 8px 32px rgba(0,0,0,0.12), 0 1px 0 rgba(255,255,255,0.8) inset;
    --tab-float-bg: rgba(245, 245, 250, 0.88);
    --tab-float-shadow: 0 4px 24px rgba(0,0,0,0.12), 0 1px 0 rgba(255,255,255,0.9) inset;
  }
}
```

---

### G2：浮动 Tab Bar（`frontend/src/components/layout/TabBar.jsx`）

```jsx
import { MessageSquare, Calendar, Settings, Bell, RefreshCw } from "lucide-react";
import { useState } from "react";

const TABS = [
  { id: "overview", label: "总览", icon: Calendar },
  { id: "agent", label: "Agent", icon: MessageSquare },
  { id: "notifications", label: "通知", icon: Bell },
  { id: "settings", label: "设置", icon: Settings },
];

export default function TabBar({ active, onChange, onRefresh }) {
  const [refreshing, setRefreshing] = useState(false);

  const handleRefresh = async () => {
    setRefreshing(true);
    await onRefresh?.();
    setTimeout(() => setRefreshing(false), 600);
  };

  return (
    <nav
      className="md:hidden"
      style={{
        position: "fixed",
        bottom: "calc(env(safe-area-inset-bottom) + 12px)",
        left: "50%",
        transform: "translateX(-50%)",
        zIndex: 50,
        display: "flex",
        alignItems: "center",
        gap: "2px",
        padding: "6px 10px",
        borderRadius: "999px",
        background: "var(--tab-float-bg)",
        boxShadow: "var(--tab-float-shadow)",
        border: "1px solid var(--glass-border)",
        backdropFilter: "blur(24px) saturate(180%)",
        WebkitBackdropFilter: "blur(24px) saturate(180%)",
      }}
    >
      {TABS.map(({ id, label, icon: Icon }) => {
        const isActive = active === id;
        return (
          <button
            key={id}
            onClick={() => onChange(id)}
            style={{ transition: "all 0.22s var(--ease-spring)" }}
            className={`flex items-center gap-1.5 rounded-full px-3 py-2 text-xs font-semibold transition-all ${
              isActive
                ? "bg-[var(--accent)] text-white shadow-md shadow-[var(--accent)]/30"
                : "text-[var(--text-tertiary)] hover:text-white hover:bg-white/10"
            }`}
          >
            <Icon size={18} />
            {isActive && (
              <span
                style={{
                  maxWidth: "4rem",
                  overflow: "hidden",
                  transition: "max-width 0.25s var(--ease-spring)",
                }}
              >
                {label}
              </span>
            )}
          </button>
        );
      })}

      {/* Refresh button */}
      <button
        onClick={handleRefresh}
        disabled={refreshing}
        className="ml-1 grid h-9 w-9 place-items-center rounded-full text-[var(--text-tertiary)] hover:bg-white/10 hover:text-white disabled:opacity-40"
        title="刷新"
      >
        <RefreshCw size={16} className={refreshing ? "animate-spin" : ""} />
      </button>
    </nav>
  );
}
```

在 `App.jsx` 里，给 `TabBar` 传 `onRefresh`：

```jsx
// App.jsx 里加 refresh handler
const handleRefresh = useCallback(() => {
  // dispatch custom event，各 view 监听后自行刷新
  window.dispatchEvent(new CustomEvent("app-refresh"));
}, []);

// 在各 view 里监听
useEffect(() => {
  const handler = () => refresh();
  window.addEventListener("app-refresh", handler);
  return () => window.removeEventListener("app-refresh", handler);
}, []);
```

同时把 App.jsx 的底部 padding 改为给浮动 tab bar 留空间：

```jsx
// 主 content 区域加 pb
<main className="... pb-[calc(env(safe-area-inset-bottom)+80px)] md:pb-0">
```

---

### G3：卡片玻璃材质升级

把所有 `rounded-[18px] border border-[var(--border)] bg-[var(--surface)]` 的卡片改成统一的 `.glass-card` class。

在 `index.css` 里添加：

```css
.glass-card {
  background: var(--glass-bg);
  border: 1px solid var(--glass-border);
  border-radius: var(--radius-card);
  box-shadow: var(--glass-shadow-sm);
  backdrop-filter: blur(12px);
  -webkit-backdrop-filter: blur(12px);
  transition: box-shadow 0.2s var(--ease-smooth),
              border-color 0.2s var(--ease-smooth);
}
.glass-card:hover {
  border-color: var(--glass-border-bright);
  box-shadow: var(--glass-shadow);
}

.glass-header {
  background: var(--tab-float-bg);
  border-bottom: 1px solid var(--glass-border);
  backdrop-filter: blur(20px) saturate(160%);
  -webkit-backdrop-filter: blur(20px) saturate(160%);
}
```

在 `ScheduleOverview.jsx`、`NotificationCenter.jsx`、`SettingsView.jsx` 等组件里，把 header 的 `bg-[var(--bar-bg)]` 改为 `glass-header`，把主卡片的 `bg-[var(--surface)]` 改为 `glass-card`（删掉 border 和 bg Tailwind 类，用 class 替代）。

---

### G4：今日卡片设计升级（ScheduleOverview TodayCard）

```jsx
function TodayCard({ data, attention }) {
  const now = new Date();
  const weekdayName = now.toLocaleDateString("zh-CN", { weekday: "long" });
  const dateStr = now.toLocaleDateString("zh-CN", { month: "long", day: "numeric" });
  const timeStr = now.toLocaleTimeString("zh-CN", { hour: "2-digit", minute: "2-digit" });
  
  const pendingAssignments = (data?.assignments || []).filter(a => a.status !== "已提交").length;
  const urgentCount = attention.primary.length;

  return (
    <div
      className="glass-card overflow-hidden p-5"
      style={{
        background: "linear-gradient(135deg, rgba(10,132,255,0.18) 0%, rgba(10,132,255,0.04) 100%), var(--glass-bg)",
        borderColor: "rgba(10,132,255,0.25)",
      }}
    >
      <div className="flex items-start justify-between">
        <div>
          <p className="text-[11px] font-medium uppercase tracking-widest text-[var(--accent-soft)] opacity-80">
            {weekdayName}
          </p>
          <p className="mt-0.5 text-3xl font-bold tracking-tight text-white">{dateStr}</p>
          <p className="mt-0.5 text-sm tabular-nums text-[var(--text-tertiary)]">{timeStr}</p>
        </div>
        <div className="mt-1 h-10 w-10 rounded-2xl bg-[var(--accent)]/15 grid place-items-center">
          <Sparkles size={20} className="text-[var(--accent-soft)]" />
        </div>
      </div>
      <div className="mt-4 flex flex-wrap gap-2">
        {urgentCount > 0 && (
          <span className="rounded-full bg-red-500/20 px-2.5 py-1 text-xs font-semibold text-red-400 ring-1 ring-red-500/30">
            {urgentCount} 项紧急
          </span>
        )}
        {pendingAssignments > 0 && (
          <span className="rounded-full bg-orange-500/15 px-2.5 py-1 text-xs font-semibold text-orange-400 ring-1 ring-orange-500/25">
            {pendingAssignments} 个作业待交
          </span>
        )}
        {urgentCount === 0 && pendingAssignments === 0 && (
          <span className="text-xs text-[var(--text-tertiary)]">今天轻松</span>
        )}
      </div>
    </div>
  );
}
```

---

### G5：通知中心 StatusPill 和 Item 升级

`NotificationCenter.jsx` 的 `NotificationItem` 调整：
- 图标容器改为 glass-card 小版本
- 状态 pill 加 `ring-1` 外圈效果
- 整体 item 用 `glass-card` 类

```jsx
// 替换 NotificationItem 的外层 div
<div className="glass-card flex gap-3 px-3 py-3 hover:border-[var(--glass-border-bright)]">
  <div className="mt-0.5 flex h-9 w-9 shrink-0 items-center justify-center rounded-2xl bg-white/6 ring-1 ring-white/10">
    {typeIcon(item.notif_type)}
  </div>
  {/* ... 其余不变 ... */}
</div>
```

---

## Module H — iOS PWA 刷新

**问题**：iOS Safari PWA（添加到主屏幕）没有地址栏，无法下拉刷新，用户找不到刷新入口。

**修复**：

1. **浮动 Tab Bar 里的刷新按钮**（已在 G2 实现）
2. **Pull-to-refresh 手势**（iOS Safari PWA 原生下拉已经可以刷新，但 PWA 全屏模式下不行）

在 `App.jsx` 里加一个 pull-to-refresh 实现：

```jsx
// App.jsx 顶部加 hook
function usePullToRefresh(onRefresh) {
  useEffect(() => {
    let startY = 0;
    let pulling = false;

    const onTouchStart = (e) => {
      if (window.scrollY === 0) {
        startY = e.touches[0].clientY;
        pulling = true;
      }
    };
    const onTouchEnd = (e) => {
      if (!pulling) return;
      const dy = e.changedTouches[0].clientY - startY;
      if (dy > 80) {
        onRefresh();
      }
      pulling = false;
    };

    document.addEventListener("touchstart", onTouchStart, { passive: true });
    document.addEventListener("touchend", onTouchEnd, { passive: true });
    return () => {
      document.removeEventListener("touchstart", onTouchStart);
      document.removeEventListener("touchend", onTouchEnd);
    };
  }, [onRefresh]);
}

// 在 App 组件里调用：
usePullToRefresh(handleRefresh);
```

---

## 更新后的实现顺序

| 顺序 | 模块 | 能否并行 | 依赖 |
|------|------|---------|------|
| 1 | E1（standby hash skip） | ✓ 独立 | — |
| 1 | E2（memory context 压缩） | ✓ 独立 | — |
| 1 | H（PWA 刷新） | ✓ 独立 | — |
| 2 | E3（chat 调控工具） | — | E1/E2 完成后验证 |
| 2 | G（UI 美化） | ✓ 独立前端 | — |
| 3 | F（E2E Debug） | 内部分 Phase 并行 | E3 完成 |
| 4 | A/D（导出/Provider） | ✓ 两个独立 | — |
| 4 | C（自动新 Session） | ✓ 独立 | — |
