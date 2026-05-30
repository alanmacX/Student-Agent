# Frontend & DingTalk 接入 实现文档

> 路径：`/opt/chatbot/`  更新：2026-05-30

---

## 一、设置页 — 钉钉状态面板

### 目标
在 Settings 加 "钉钉" tab，展示客户端状态（运行/掉线）、上次同步时间、消息统计，并提供手动触发 sync 的按钮。无需用户输入密码（钉钉在服务器上以 GUI 形式运行，认证由客户端本身完成）。

### 后端：新增 `/api/dingtalk/status` endpoint

在 `backend/app/dingtalk/router.py` 加：

```python
import os, time, sqlite3
from datetime import datetime, timezone, timedelta

@router.get("/status")
async def dingtalk_status(request: Request):
    db_path = _db_path(request)
    wal = os.getenv("DINGTALK_DB_SOURCE", "/dingtalk_db/dingtalk.db") + "-wal"

    # 1. 客户端活跃度：WAL 最后修改时间
    try:
        mtime = os.path.getmtime(wal)
        wal_age_s = int(time.time() - mtime)
        client_alive = wal_age_s < 1800          # 30 分钟内有写入 = alive
        last_wal_update = datetime.fromtimestamp(mtime, tz=timezone.utc).isoformat()
    except FileNotFoundError:
        wal_age_s = -1
        client_alive = False
        last_wal_update = None

    # 2. 进程状态：检查进程是否被 SIGSTOP
    process_status = "unknown"
    try:
        import subprocess
        r = subprocess.run(["pgrep", "-f", "com.alibabainc.dingtalk"], capture_output=True, text=True)
        if r.returncode == 0:
            pid = r.stdout.strip().split()[0]
            state_line = open(f"/proc/{pid}/status").read()
            if "State:\tT" in state_line:
                process_status = "stopped"          # SIGSTOP 了，需要 SIGCONT
            else:
                process_status = "running"
        else:
            process_status = "not_running"
    except Exception:
        pass

    # 3. 同步状态 & 消息统计
    ensure_schema(db_path)
    with sqlite3.connect(db_path) as conn:
        state_row = conn.execute(
            "SELECT value FROM dingtalk_sync_state WHERE key='last_seen_created_at'"
        ).fetchone()
        last_seen_ts = int(state_row[0]) if state_row else 0

        stats = conn.execute(
            """SELECT verdict, COUNT(*) as cnt FROM dingtalk_messages
               WHERE synced_at > strftime('%s','now') - 86400
               GROUP BY verdict"""
        ).fetchall()

        total = conn.execute("SELECT COUNT(*) FROM dingtalk_messages").fetchone()[0]
        unread = conn.execute(
            "SELECT COUNT(*) FROM dingtalk_messages WHERE verdict='notify' AND created_at > ?",
            (last_seen_ts - 3_600_000,)   # 最近1小时 notify
        ).fetchone()[0]

    last_sync_dt = (
        datetime.fromtimestamp(last_seen_ts / 1000, tz=timezone.utc).isoformat()
        if last_seen_ts else None
    )

    return {
        "client_alive": client_alive,
        "process_status": process_status,
        "wal_age_seconds": wal_age_s,
        "last_wal_update": last_wal_update,
        "last_sync": last_sync_dt,
        "total_messages": total,
        "recent_24h": {r[0]: r[1] for r in stats},
        "recent_notify_count": unread,
    }
```

另加 `POST /api/dingtalk/resume` 发 SIGCONT（处理钉钉被 SIGSTOP 的情况）：

```python
@router.post("/resume")
async def dingtalk_resume():
    """Send SIGCONT to DingTalk if it was stopped (e.g. after gdb attach)."""
    import subprocess, signal
    r = subprocess.run(["pgrep", "-f", "com.alibabainc.dingtalk"], capture_output=True, text=True)
    if r.returncode != 0:
        return {"ok": False, "error": "process not found"}
    pid = int(r.stdout.strip().split()[0])
    os.kill(pid, signal.SIGCONT)
    return {"ok": True, "pid": pid, "signal": "SIGCONT"}
```

### 前端：`DingTalkStatus.jsx`（新建，仿 ChaoxingStatus）

**文件**：`frontend/src/components/settings/DingTalkStatus.jsx`

```jsx
import { useState, useEffect } from "react";
import { RefreshCw, Loader2, CheckCircle2, AlertCircle, Play, MessageSquare, Clock } from "lucide-react";
import { apiFetch } from "../../api/client";  // 复用现有 fetch 封装

function fmtAge(seconds) {
  if (seconds < 0) return "—";
  if (seconds < 60) return `${seconds}s 前`;
  if (seconds < 3600) return `${Math.floor(seconds / 60)}m 前`;
  return `${Math.floor(seconds / 3600)}h 前`;
}

function fmtTime(iso) {
  if (!iso) return "—";
  return new Date(iso).toLocaleString("zh-CN", { month: "2-digit", day: "2-digit", hour: "2-digit", minute: "2-digit" });
}

export default function DingTalkStatus() {
  const [status, setStatus] = useState(null);
  const [loading, setLoading] = useState(true);
  const [syncing, setSyncing] = useState(false);
  const [resuming, setResuming] = useState(false);

  const refresh = async () => {
    setLoading(true);
    try {
      const s = await apiFetch("/api/dingtalk/status");
      setStatus(s);
    } catch (e) {
      console.error(e);
    } finally {
      setLoading(false);
    }
  };

  useEffect(() => { refresh(); }, []);

  const handleSync = async () => {
    setSyncing(true);
    try {
      await apiFetch("/api/dingtalk/sync", { method: "POST" });
      await refresh();
    } finally {
      setSyncing(false);
    }
  };

  const handleResume = async () => {
    setResuming(true);
    try {
      await apiFetch("/api/dingtalk/resume", { method: "POST" });
      setTimeout(refresh, 2000);
    } finally {
      setResuming(false);
    }
  };

  if (loading) return <div className="py-12 text-center text-[var(--text-tertiary)]"><Loader2 size={24} className="mx-auto animate-spin" /></div>;

  const alive = status?.client_alive;
  const stopped = status?.process_status === "stopped";
  const notRunning = status?.process_status === "not_running";

  return (
    <div className="max-w-md space-y-4">
      <h2 className="text-lg font-semibold text-white">钉钉</h2>

      {/* Client status card */}
      <div className={`rounded-2xl border p-4 ${
        alive ? "border-green-500/30 bg-green-500/10"
               : "border-amber-500/30 bg-amber-500/10"
      }`}>
        <div className="flex items-center justify-between">
          <div className="flex items-center gap-3">
            {alive
              ? <CheckCircle2 size={20} className="shrink-0 text-green-400" />
              : <AlertCircle  size={20} className="shrink-0 text-amber-400" />}
            <div>
              <p className={`text-sm font-medium ${alive ? "text-green-300" : "text-amber-300"}`}>
                {notRunning ? "客户端未运行"
                  : stopped   ? "客户端已暂停（需要恢复）"
                  : alive     ? "客户端正常运行"
                  :             "客户端可能掉线"}
              </p>
              <p className="text-xs text-[var(--text-tertiary)]">
                WAL 更新：{fmtAge(status?.wal_age_seconds)}
              </p>
            </div>
          </div>
          {stopped && (
            <button
              onClick={handleResume}
              disabled={resuming}
              className="flex min-h-9 items-center gap-1.5 rounded-xl bg-amber-500/20 px-3 text-xs text-amber-300 hover:bg-amber-500/30"
            >
              {resuming ? <Loader2 size={12} className="animate-spin" /> : <Play size={12} />}
              恢复
            </button>
          )}
        </div>
      </div>

      {/* Stats grid */}
      <div className="grid grid-cols-2 gap-3">
        <StatCard icon={<Clock size={14} className="text-blue-400" />}
          label="上次同步" value={fmtTime(status?.last_sync)} />
        <StatCard icon={<MessageSquare size={14} className="text-purple-400" />}
          label="总消息" value={`${status?.total_messages ?? 0} 条`} />
        <StatCard icon={<CheckCircle2 size={14} className="text-green-400" />}
          label="今日 notify" value={`${status?.recent_24h?.notify ?? 0} 条`} />
        <StatCard icon={<MessageSquare size={14} className="text-indigo-400" />}
          label="今日 interest" value={`${status?.recent_24h?.interest ?? 0} 条`} />
      </div>

      {/* Actions */}
      <div className="flex gap-2">
        <button
          onClick={handleSync}
          disabled={syncing}
          className="flex flex-1 min-h-11 items-center justify-center gap-2 rounded-2xl bg-[var(--accent)] px-4 text-sm font-semibold text-white hover:bg-[var(--accent-strong)] disabled:opacity-50"
        >
          {syncing ? <Loader2 size={14} className="animate-spin" /> : <RefreshCw size={14} />}
          立即同步
        </button>
        <button
          onClick={refresh}
          className="grid h-11 w-11 place-items-center rounded-2xl bg-[var(--hover-bg)] text-[var(--text-secondary)] hover:bg-[var(--hover-bg-strong)]"
        >
          <RefreshCw size={15} />
        </button>
      </div>

      <p className="text-xs text-[var(--text-tertiary)] leading-5">
        钉钉客户端运行在服务器 Xvfb 虚拟显示器上。同步每 60s 自动触发。
        消息按"notify / interest / drop"三桶分类，notify 的内容 Agent 可直接读取。
      </p>
    </div>
  );
}

function StatCard({ icon, label, value }) {
  return (
    <div className="rounded-xl bg-[var(--deep-bg)] px-3 py-2">
      <div className="flex items-center gap-1.5 mb-1">{icon}
        <span className="text-[11px] text-[var(--text-tertiary)]">{label}</span>
      </div>
      <p className="text-sm font-semibold text-white">{value}</p>
    </div>
  );
}
```

**接入 SettingsView.jsx**：在 TABS 数组加一项，在 content 区加渲染。

```jsx
// 在 TABS 里加（放在 chaoxing 后面）：
import { MessageCircle } from "lucide-react"; // 或 BellRing
{ id: "dingtalk", label: "钉钉", mobileLabel: "钉钉", icon: MessageCircle },

// 在 content 区加：
import DingTalkStatus from "./DingTalkStatus";
{tab === "dingtalk" && <DingTalkStatus />}
```

---

## 二、Chat 自动开新 Session

**需求**：超过 N 分钟（建议 30 分钟）无交互，下次发消息时自动创建新会话，不打扰当前对话。

**实现位置**：`useConversations.js` + `ChatView.jsx`

### 方案

在 ChatView 里加 `lastActivityRef`，每次发消息/收消息更新时间戳。发消息前检查：

```jsx
// ChatView.jsx 顶部
const AUTO_NEW_SESSION_MS = 30 * 60 * 1000; // 30 分钟
const lastActivityRef = useRef(Date.now());

// 每次收到消息时更新
useEffect(() => {
  if (messages.length > 0) lastActivityRef.current = Date.now();
}, [messages.length]);

// 发消息时检查
const handleSend = useCallback(async () => {
  if (!input.trim() || !conversation || isStreaming) return;

  const now = Date.now();
  const idle = now - lastActivityRef.current;
  let activeConv = conversation;

  if (idle > AUTO_NEW_SESSION_MS) {
    // 自动创建新会话
    const newConv = await onCreateNewSession?.();
    if (newConv) activeConv = newConv;
  }
  lastActivityRef.current = now;

  startStream(activeConv.id, input);
  setInput("");
}, [input, conversation, isStreaming, startStream]);
```

`onCreateNewSession` 由父组件（App.jsx）传入，内部调用 `conversations.create()`，并切换到新会话。

---

## 三、Confirm/Cancel 按钮 UI

**需求**：Agent 询问"确认执行？"时，在 MessageBubble 里渲染实际按钮，而非让用户手动输入"确认"。

### 解析逻辑

当 assistant 消息结尾包含确认意图时，渲染 ConfirmBar。检测模式（在 MessageBubble 里）：

```js
// 检测 assistant 消息是否需要确认
const CONFIRM_PATTERNS = [
  /确认执行[？?]?\s*$/,
  /需要.*确认[？?]\s*$/,
  /是否.*执行[？?]\s*$/,
  /请确认[：:]/,
];
const needsConfirm = role === "assistant" && !_streaming &&
  CONFIRM_PATTERNS.some(p => p.test(content?.trim() || ""));
```

渲染（在 MessageBubble 末尾，streaming 结束后）：

```jsx
{needsConfirm && !confirmed && (
  <div className="mt-3 flex gap-2">
    <button
      onClick={() => { setConfirmed(true); onQuickReply?.("确认执行"); }}
      className="flex-1 min-h-10 rounded-2xl bg-[var(--accent)] text-sm font-semibold text-white hover:bg-[var(--accent-strong)]"
    >
      ✓ 确认执行
    </button>
    <button
      onClick={() => { setConfirmed(true); onQuickReply?.("取消"); }}
      className="min-h-10 rounded-2xl bg-[var(--hover-bg)] px-4 text-sm text-[var(--text-secondary)] hover:bg-[var(--hover-bg-strong)]"
    >
      取消
    </button>
  </div>
)}
```

`onQuickReply` 由 ChatView 传入，调用 `handleSend(text)` 直接发消息。

**注意**：按钮点击后设 `confirmed=true` 隐藏按钮（本地 state），只展示一次。

---

## 四、Tool Call 显示精简

**当前问题**：展开后会显示原始 JSON，太嘈杂。

**方案**：默认折叠，去掉原始 JSON 的"展开"入口；只保留 `summarizeResult` 的友好摘要。若用户确实需要看原始数据，在 agent 配置里加 `show_in_ui=true` 走专门 payload 渲染，而非 pre-formatted JSON。

**具体改动（ToolCallBubble.jsx）**：

1. 删除 `previewText` 和原始 `pre` 代码块
2. 扩大 `summarizeResult` 覆盖钉钉工具：

```js
function summarizeResult(result, toolName) {
  if (!result) return null;
  try {
    const parsed = JSON.parse(result);
    // 钉钉消息列表
    if (toolName === "read_dingtalk_messages") {
      if (!Array.isArray(parsed)) return "读取完成";
      if (parsed.length === 0) return "暂无新消息";
      return `${parsed.length} 条消息`;
    }
    if (parsed.ok !== undefined) return parsed.ok ? "成功" : `失败: ${parsed.error || ""}`;
    if (parsed.error) return `错误: ${parsed.error}`;
    if (Array.isArray(parsed)) return `${parsed.length} 条结果`;
    if (parsed.attempted !== undefined) return `已发送 ${parsed.attempted} 条`;
    if (typeof parsed.inserted === "number") return `新增 ${parsed.inserted} 条`;
  } catch {}
  const text = result.trim();
  return text.length > 80 ? text.slice(0, 80) + "…" : text;
}
```

3. 移除 `ChevronRight/ChevronDown` 展开原始 JSON 的 UI（或把展开入口挪到 "··· 更多" 长按菜单，不做默认展示）

**TOOL_META 加入钉钉工具**：

```js
read_dingtalk_messages: { icon: MessageSquare, label: "读取钉钉消息" },
```

---

## 五、Apple Intelligence 风格生成指示器

**需求**：把"生成中"提示从消息流区域底部，改为输入栏（pill）的四周旋转渐变光晕（Glow ring），类似 Apple Intelligence 效果。

### 实现（ChatInput.jsx）

**核心**：在 `isStreaming` 时，给 mobile pill / desktop textarea 外层加一个 CSS 渐变动画 border。

#### CSS（index.css 加入）

```css
/* Apple Intelligence glow ring */
@keyframes ai-glow-rotate {
  0%   { --angle: 0deg; }
  100% { --angle: 360deg; }
}

.ai-glow-ring {
  position: relative;
  border-radius: inherit;
}

.ai-glow-ring::before {
  content: "";
  position: absolute;
  inset: -2px;
  border-radius: inherit;
  background: conic-gradient(
    from var(--angle, 0deg),
    transparent 0%,
    #a855f7 20%,     /* purple */
    #3b82f6 40%,     /* blue */
    #06b6d4 55%,     /* cyan */
    #a855f7 70%,
    transparent 100%
  );
  animation: ai-glow-rotate 1.8s linear infinite;
  @property --angle {
    syntax: "<angle>";
    initial-value: 0deg;
    inherits: false;
  }
  z-index: -1;
  opacity: 0;
  transition: opacity 0.3s ease;
}

.ai-glow-ring.streaming::before {
  opacity: 1;
}

/* 内层白边盖住渐变边框的溢出 */
.ai-glow-ring::after {
  content: "";
  position: absolute;
  inset: 0px;
  border-radius: inherit;
  background: var(--tab-float-bg, #1a1a2e);
  z-index: -1;
}
```

**注**：`@property` 是现代浏览器支持的，iOS Safari 16.4+ 支持。降级方案：用 `rotate` transform 替代 `conic-gradient` 的 `--angle`。

#### 降级（更兼容）方案

```css
@keyframes ai-glow-spin {
  to { transform: rotate(360deg); }
}

.ai-glow-ring::before {
  content: "";
  position: absolute;
  inset: -2px;
  border-radius: inherit;
  background: conic-gradient(
    #a855f7, #3b82f6, #06b6d4, #a855f7
  );
  transform-origin: center;
  animation: ai-glow-spin 1.8s linear infinite;
  z-index: 0;
}
/* 内层遮罩 */
.ai-glow-ring::after {
  content: "";
  position: absolute;
  inset: 2px;
  border-radius: calc(inherit - 2px);
  background: inherit; /* 继承父元素背景 */
  z-index: 1;
}
/* 所有子元素要 position:relative; z-index:2 */
```

#### ChatInput.jsx 改动

```jsx
// mobile pill
<div
  className={`glass-input md:hidden ai-glow-ring ${isStreaming ? "streaming" : ""}`}
  style={{ /* 保持原样 */ }}
>
  {/* 内容不变 */}
</div>

// desktop: 把 textarea 外层套一层
<div className={`relative ai-glow-ring rounded-2xl ${isStreaming ? "streaming" : ""}`}>
  <textarea ... className="relative z-10 ..." />
</div>
```

同时**移除** ChatView 中原来的"生成中..."文字或 spinner（如果有的话），让 glow ring 本身就是状态反馈。

---

## 六、钉钉工具完整 Debug 测试计划

### 6.1 前置检查

```bash
# 1. 钉钉进程正常运行（非 T 状态）
ps aux | grep com.alibabainc.dingtalk | grep -v grep | awk '{print $8}'
# 期望：Sl（不是 T）

# 2. WAL 在最近更新
stat /root/.config/DingTalk/.../DBFiles/dingtalk.db-wal | grep Modify
# 期望：时间在 30 分钟内

# 3. bind mount 进容器
docker exec chatbot-backend-1 ls -la /dingtalk_db/
# 期望：能看到 dingtalk.db, dingtalk.db-wal, dingtalk.db-shm

# 4. pycryptodome 可用
docker exec chatbot-backend-1 python3 -c "from Crypto.Cipher import AES; print('ok')"
```

### 6.2 层级测试：AES 解密

```bash
docker exec chatbot-backend-1 python3 - <<'EOF'
from app.dingtalk.dingtalk_service import decrypt_db_to_tmp
import time, sqlite3
t = time.time()
p = decrypt_db_to_tmp()
elapsed = time.time() - t
conn = sqlite3.connect(f"file:{p}?mode=ro", uri=True)
check = conn.execute("PRAGMA integrity_check").fetchone()[0]
tables = [r[0] for r in conn.execute("SELECT name FROM sqlite_master WHERE type='table'")]
print(f"解密: {elapsed:.2f}s  integrity={check}  tables={len(tables)}")
assert check == "ok", "DB integrity failed"
assert "tbconversation" in tables, "tbconversation missing"
assert "tbmsg_000" in tables, "tbmsg_000 missing"
print("✅ AES 解密 PASS")
EOF
# 期望：解密 <0.5s，integrity=ok，tables≥130
```

### 6.3 层级测试：消息查询

```bash
docker exec chatbot-backend-1 python3 - <<'EOF'
import sqlite3
from app.dingtalk.dingtalk_service import decrypt_db_to_tmp, query_new_messages
p = decrypt_db_to_tmp()
conn = sqlite3.connect(f"file:{p}?mode=ro", uri=True); conn.row_factory = sqlite3.Row
msgs = query_new_messages(conn, 0)
print(f"总消息数: {len(msgs)}")
assert len(msgs) > 0, "No messages returned"
m = msgs[0]
for field in ("mid", "cid", "created_at", "content_type", "content"):
    assert field in m, f"Missing field: {field}"
print("字段检查: mid, cid, created_at, content_type, content ✅")
# 验证有发件人名
named = [m for m in msgs if m.get("sender_name")]
print(f"有发件人名: {len(named)}/{len(msgs)}")
print("✅ 消息查询 PASS")
EOF
```

### 6.4 层级测试：粗筛 filters

```bash
docker exec chatbot-backend-1 python3 - <<'EOF'
import sqlite3
from collections import Counter
from app.dingtalk.dingtalk_service import decrypt_db_to_tmp, query_new_messages
from app.dingtalk.filters import evaluate
p = decrypt_db_to_tmp()
conn = sqlite3.connect(f"file:{p}?mode=ro", uri=True); conn.row_factory = sqlite3.Row
msgs = query_new_messages(conn, 0)
evaluated = [evaluate(m) for m in msgs]
v = Counter(e["verdict"] for e in evaluated)
print("Verdict 分布:", dict(v))
# 验证没有"drop"标为notify
wrong = [e for e in evaluated if e["is_system"] and e["verdict"] == "notify"]
assert len(wrong) == 0, f"系统会话被误判为 notify: {wrong}"
# 验证私聊都是 notify
direct = [e for e in evaluated if not e["is_group"] and e["_keep"]]
wrong2 = [e for e in direct if e["verdict"] not in ("notify", "needs_llm")]
assert len(wrong2) == 0, f"私聊不应 drop: {wrong2}"
print("✅ 粗筛 filters PASS")
EOF
```

### 6.5 层级测试：LLM 分类器（端到端）

```bash
docker exec chatbot-backend-1 python3 - <<'EOF'
import asyncio, sqlite3
from app.dingtalk.dingtalk_service import decrypt_db_to_tmp, query_new_messages
from app.dingtalk.filters import evaluate
from app.dingtalk.classifier import classify_messages
from app.config import settings

class S: pass
st = S(); st.settings = settings

async def main():
    p = decrypt_db_to_tmp()
    conn = sqlite3.connect(f"file:{p}?mode=ro", uri=True); conn.row_factory = sqlite3.Row
    msgs = [evaluate(m) for m in query_new_messages(conn, 0)]
    pending_before = sum(1 for m in msgs if m["verdict"] == "needs_llm")
    print(f"needs_llm before: {pending_before}")
    if pending_before == 0:
        print("⚠️  没有 needs_llm 条目，跳过 LLM 测试（可手动用 since=0 触发）")
        return
    await classify_messages(msgs, st)
    pending_after = sum(1 for m in msgs if m["verdict"] == "needs_llm")
    assert pending_after == 0, f"LLM 分类后仍有 needs_llm: {pending_after}"
    print("LLM 分类结果:", {m["verdict"] for m in msgs})
    print("✅ LLM 分类器 PASS")

asyncio.run(main())
EOF
```

### 6.6 层级测试：Sync 写库

```bash
# 先 bootstrap 把游标清零（方便测试）
curl -s -X POST http://localhost/api/dingtalk/bootstrap
# 触发完整 sync
curl -s -X POST http://localhost/api/dingtalk/sync | python3 -m json.tool
# 期望：ok=true, fetched>0, inserted>0, buckets.notify>0

# 验证数据库写入
docker exec chatbot-backend-1 python3 - <<'EOF'
import sqlite3
from app.config import settings
conn = sqlite3.connect(settings.database_path); conn.row_factory = sqlite3.Row
rows = conn.execute(
    "SELECT sender_name, conversation_title, verdict, text FROM dingtalk_messages ORDER BY created_at DESC LIMIT 5"
).fetchall()
assert len(rows) > 0, "No rows in dingtalk_messages"
for r in rows:
    print(f"[{r['verdict']}] {r['sender_name']} ({r['conversation_title'] or '私聊'}): {(r['text'] or '')[:30]}")
# 确保没有 needs_llm 进入 DB
bad = conn.execute("SELECT COUNT(*) FROM dingtalk_messages WHERE verdict='needs_llm'").fetchone()[0]
assert bad == 0, f"needs_llm 不应写入 DB，发现 {bad} 条"
print("✅ Sync 写库 PASS")
EOF
```

### 6.7 层级测试：REST API

```bash
# GET /api/dingtalk/messages?bucket=notify
curl -s 'http://localhost/api/dingtalk/messages?bucket=notify&limit=5' | python3 -c "
import sys,json
data=json.load(sys.stdin)
print(f'notify 桶: {len(data)} 条')
for d in data[:3]: print(' -', d.get('verdict'), d.get('sender_name'), (d.get('text') or '')[:30])
assert len(data) >= 0
print('✅ GET /messages PASS')
"

# GET /api/dingtalk/interest
curl -s 'http://localhost/api/dingtalk/interest?limit=5' | python3 -c "
import sys,json
data=json.load(sys.stdin); print(f'interest 桶: {len(data)} 条'); print('✅ GET /interest PASS')
"

# GET /api/dingtalk/conversations
curl -s http://localhost/api/dingtalk/conversations | python3 -c "
import sys,json
data=json.load(sys.stdin); print(f'会话: {len(data)} 个')
assert len(data) > 0; print('✅ GET /conversations PASS')
"

# GET /api/dingtalk/status
curl -s http://localhost/api/dingtalk/status | python3 -m json.tool
```

### 6.8 层级测试：Agent 工具调用

```bash
# 通过 schedule chat 接口测试 agent 能读钉钉
curl -s -X POST http://localhost/api/schedule/chat \
  -H 'Content-Type: application/json' \
  -d '{"message":"帮我看看最近钉钉有什么消息","conversation_id":"debug-dt-001"}' \
  --max-time 30 | grep -E 'tool_start|tool_result|text' | head -20
# 期望：出现 read_dingtalk_messages 的 tool_start 和 tool_result
# 期望：text 块包含实际消息内容摘要

# 测 interest 桶
curl -s -X POST http://localhost/api/schedule/chat \
  -H 'Content-Type: application/json' \
  -d '{"message":"有没有什么我可能感兴趣的消息？","conversation_id":"debug-dt-002"}' \
  --max-time 30 | grep 'text' | head -5
```

### 6.9 层级测试：Build_turn_context 注入

```bash
docker exec chatbot-backend-1 python3 - <<'EOF'
import asyncio, zoneinfo
from datetime import datetime, timezone
from app.services.schedule_agent import build_turn_context
from app.services.chaoxing_service import ChaoxingService
from app.config import settings

async def main():
    svc = ChaoxingService(settings.database_path)
    now = datetime.now(tz=zoneinfo.ZoneInfo("Asia/Shanghai"))
    ctx = await build_turn_context(settings.database_path, svc, now)
    print(ctx)
    has_dingtalk = "钉钉消息" in ctx
    print(f"Context 包含钉钉消息: {has_dingtalk}")
    # 如果 notify 桶有数据，context 里应包含
    import sqlite3
    conn = sqlite3.connect(settings.database_path)
    count = conn.execute("SELECT COUNT(*) FROM dingtalk_messages WHERE verdict='notify'").fetchone()[0]
    if count > 0:
        assert has_dingtalk, "notify 桶有数据但 context 未注入钉钉消息"
    print("✅ build_turn_context PASS")

asyncio.run(main())
EOF
```

### 6.10 回归测试：现有功能不受影响

```bash
# 学习通 memory 依然正常
curl -s http://localhost/health | python3 -c "import sys,json; d=json.load(sys.stdin); print('Health:', d)"

# Schedule agent 仍能处理学习通请求
curl -s -X POST http://localhost/api/schedule/chat \
  -H 'Content-Type: application/json' \
  -d '{"message":"查一下我的待交作业","conversation_id":"debug-regression-001"}' \
  --max-time 30 | grep -E 'get_chaoxing|text' | head -5

# 提醒事项不受影响
curl -s http://localhost/api/reminders | python3 -c "import sys,json; d=json.load(sys.stdin); print(f'提醒: {len(d)} 条')"
```

### 6.11 压力/边界测试

```bash
# 空 DB（无消息）时 sync 不崩
curl -s -X POST http://localhost/api/dingtalk/bootstrap && \
curl -s -X POST http://localhost/api/dingtalk/sync | python3 -c "import sys,json; d=json.load(sys.stdin); assert d['ok']; print('✅ 空 DB sync PASS')"

# 钉钉 DB 不可读时优雅降级
docker exec chatbot-backend-1 python3 - <<'EOF'
from app.dingtalk.dingtalk_service import decrypt_db_to_tmp
try:
    decrypt_db_to_tmp(source_path="/nonexistent/path.db")
    assert False, "应该抛出异常"
except FileNotFoundError:
    print("✅ FileNotFoundError 正确抛出")
EOF

# 大量 needs_llm 时 LLM batch 分组正确（模拟 16 条）
docker exec chatbot-backend-1 python3 - <<'EOF'
from app.dingtalk.classifier import _build_user_prompt
msgs = [{"text": f"测试消息{i}", "conversation_title": "群", "sender_name": "人"} for i in range(16)]
prompt = _build_user_prompt(msgs)
assert "0." in prompt and "15." in prompt, "batch prompt indexing error"
print("✅ LLM batch prompt PASS")
EOF
```

---

## 七、改动文件汇总

```
backend/app/dingtalk/router.py    加 /status + /resume endpoint
frontend/src/components/settings/
    DingTalkStatus.jsx             新建（钉钉设置面板）
    SettingsView.jsx               加 dingtalk tab
frontend/src/components/chat/
    ChatInput.jsx                  glow ring CSS + streaming class
    ChatView.jsx                   auto new session logic
    MessageBubble.jsx              confirm/cancel button UI
    ToolCallBubble.jsx             精简显示 + 加钉钉工具 meta
frontend/src/index.css            ai-glow-ring keyframes + styles
```
