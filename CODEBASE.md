# Codebase Guide

**任何 agent 改动代码前必须先读本文件。** 本文描述项目的真实结构、部署方式、代码同步规则以及各模块的设计约定。

---

## 1. 项目组成

本仓库包含两个独立产品，共享同一个 git repo：

| 产品 | 路径 | 技术栈 |
|---|---|---|
| **iOS 应用** (macOS/iPhone) | `ChatBot/` | Swift / SwiftUI |
| **Web 应用** (服务端 + 前端) | `server-src/` | Python FastAPI + React/Vite |

---

## 2. Web 应用：唯一权威源

### 2.1 源码位置

**本地权威源码：`server-src/`**

```
server-src/
├── backend/              ← Python 后端（FastAPI）
│   ├── app/
│   ├── Dockerfile
│   └── requirements.txt  ← 含 pycryptodome（钉钉解密依赖）
├── frontend/             ← React 前端（Vite 构建）
│   ├── src/              ← 唯一的前端源码，Vite 从这里 build
│   ├── package.json
│   └── Dockerfile
├── .env.example          ← 配置模板，复制为 .env 填写
├── docker-compose.yml
└── nginx.conf
```

> ⚠️ **`web/` 目录是旧副本，已废弃，不要读、不要改、不要用它 build。**
>
> ⚠️ `server-src/frontend/src/` 是 Vite 实际构建的源码。服务器 `/opt/chatbot/` 根目录有一个
> 平铺的 `components/` 目录（历史遗留），与 `frontend/src/components/` 是两套独立副本，已于
> 2026-05-30 合并，不要再向平铺目录写入内容。

### 2.2 服务器部署

生产环境在 **`aliyun-root:/opt/chatbot/`**，结构与 `server-src/` 完全对应：

```
/opt/chatbot/
├── backend/app/          ← 与 server-src/backend/app/ 对应
├── frontend/src/         ← 与 server-src/frontend/src/ 对应
└── docker-compose.yml
```

三个 Docker 容器：
- `chatbot-backend-1` — FastAPI，Python，端口 8000
- `chatbot-frontend-1` — Nginx 服务静态 dist，端口 80
- `chatbot-nginx-1` — 反向代理

### 2.3 代码同步规则（最重要）

**本地 `server-src/` 与服务器 `/opt/chatbot/` 必须保持同步。**

每次改动的标准流程：

```
1. 在 server-src/ 改代码
2. py_compile 或 npm run build 验证
3. scp 上传到服务器对应路径
4. docker cp 注入容器（或 docker restart）
5. 验证服务器日志正常
```

**拉取服务器最新状态（改动前先同步）：**
```bash
rsync -az --exclude='node_modules' --exclude='dist' --exclude='__pycache__' \
  aliyun-root:/opt/chatbot/ /Users/macalan/Documents/chatbot/server-src/
```

**绝对禁止：**
- 用 `web/` 里的代码 build 或部署
- `docker build` 重建前端镜像（会冲掉服务器上比本地更新的代码）
- `docker compose up --build`（同上）
- 用 `rm -rf html/*` + 旧代码覆盖前端容器（2026-05-30 的教训：这样会把只在服务器存在的 DingTalkStatus.jsx 等组件删掉）

**前端部署方式：**
```bash
# 在 server-src/frontend/ build
cd server-src/frontend && npm run build

# 打包 dist 上传，不要 rm -rf 整个目录再替换
tar czf /tmp/dist.tar.gz -C dist .
scp /tmp/dist.tar.gz aliyun-root:/tmp/
ssh aliyun-root "
  docker exec chatbot-frontend-1 sh -c 'rm -rf /usr/share/nginx/html/*'
  docker cp /tmp/dist.tar.gz chatbot-frontend-1:/tmp/dist.tar.gz
  docker exec chatbot-frontend-1 sh -c 'cd /usr/share/nginx/html && tar xzf /tmp/dist.tar.gz'
"
```

**后端部署方式（单文件）：**
```bash
scp server-src/backend/app/foo/bar.py aliyun-root:/tmp/bar.py
ssh aliyun-root "docker cp /tmp/bar.py chatbot-backend-1:/app/app/foo/bar.py"
# 验证编译后再 restart
ssh aliyun-root "docker exec chatbot-backend-1 python3 -m py_compile /app/app/foo/bar.py && docker restart chatbot-backend-1"
```

---

## 3. 后端架构

### 3.1 目录说明

```
backend/app/
├── main.py               ← FastAPI app 入口，挂载所有 router
├── config.py             ← Settings（database_path, 各服务配置）
├── database.py           ← SQLite async 连接池（aiosqlite）
├── models.py             ← DB schema 定义
│
├── routers/              ← HTTP 路由层（薄，只做请求解析/响应）
│   ├── chat.py           ← /api/conversations — 通用对话
│   ├── schedule.py       ← /api/schedule — 日程 Agent 对话 + confirm
│   ├── chaoxing.py       ← /api/chaoxing — 学习通状态/登录
│   ├── reminders.py      ← /api/reminders — macOS Reminders 同步
│   ├── providers.py      ← /api/providers — LLM provider 管理
│   ├── push.py           ← /api/push — Web Push 订阅
│   ├── settings.py       ← /api/settings — 用户设置
│   ├── data.py           ← /api/data — 数据导出
│   └── debug.py          ← /api/debug — 调试工具
│
├── services/             ← 业务逻辑层
│   ├── schedule_agent.py     ← 日程 Agent（工具调用、pending_mutation、确认流程）
│   ├── agent_service.py      ← 通用 agentic loop（run_agentic_loop）
│   ├── chaoxing_service.py   ← 学习通 API 客户端
│   ├── chaoxing_message_filter.py ← 消息去重/分类（notify/interest/drop）
│   ├── memory_sync.py        ← 结构化数据写入 memory（作业/课程/提醒）→ MemoryRepository
│   ├── memory_agent.py       ← 旧版 LLM 提取（已被 chaoxing/memory_provider.py 取代）
│   ├── memory_reducer.py     ← 旧版 sweep/reduce（已被 MemoryRepository.sweep() 取代）
│   ├── memory_models.py      ← 共享的辅助函数（key_text, parse_iso 等）
│   ├── push_service.py       ← Web Push 发送
│   ├── provider_registry.py  ← LLM provider 解析
│   ├── notification_scheduler.py ← 定时通知调度
│   ├── dashboard_briefing.py ← 每日摘要生成
│   ├── schedule_store.py     ← Reminders/Calendar CRUD（macOS Shortcuts 桥接）
│   ├── api_service.py        ← HTTP 客户端（httpx）
│   └── time_context.py       ← 时间注入到 system prompt
│
├── memory/               ← 新统一 Memory 层（权威，所有来源共用）
│   ├── base.py               ← MemoryRepository：upsert_entry / query_for_agent / query_for_automation / sweep
│   └── engine.py             ← process_message()：消息 → IntentGraph → Effects → 执行
│
├── chaoxing/             ← 学习通 Memory 集成（新）
│   └── memory_provider.py    ← run_chaoxing_memory_sync()：消息 → engine.process_message()
│
├── dingtalk/             ← 钉钉集成
│   ├── dingtalk_service.py   ← DB 解密（需要 pycryptodome）、消息读取
│   ├── memory_provider.py    ← run_dingtalk_memory_sync()：消息 → engine.process_message()
│   ├── router.py             ← /api/dingtalk 路由
│   ├── task.py               ← 定时同步任务
│   ├── classifier.py         ← 消息分类
│   └── filters.py            ← 消息过滤
│
└── tasks/                ← APScheduler 定时任务
    ├── chaoxing_sync.py      ← 主探针（adaptive 间隔）
    ├── memory_sweep.py       ← 每小时 → MemoryRepository.sweep()
    ├── notification_sender.py← 推送发送
    ├── standby_agent.py      ← 待机 Agent
    ├── health_monitor.py     ← 健康检查
    └── scheduler.py          ← APScheduler 初始化
```

### 3.2 Memory 架构（2026-05-30 迁移后）

所有来源**必须通过 `MemoryRepository`** 读写，禁止直接写 `chaoxing_memory_entries` 表。

```
数据来源                    写入路径
──────────────────────────────────────────────────────
学习通消息（LLM）           chaoxing/memory_provider → engine.process_message()
钉钉消息（LLM）             dingtalk/memory_provider → engine.process_message()
作业/课程/提醒（结构化）    services/memory_sync → MemoryRepository.upsert_entry()
维护/清理                   tasks/memory_sweep → MemoryRepository.sweep()

读取路径
──────────────────────────────────────────────────────
日程 Agent 对话上下文       services/schedule_agent → MemoryRepository.query_for_agent()
自动化/通知                 tasks/standby_agent → MemoryRepository.query_for_automation()
```

**旧文件说明（保留但不再是主路径）：**
- `services/memory_agent.py` — 旧版 LLM 提取，现在只有 `run_memory_maintenance` 还被少量调用（已废弃）
- `services/memory_reducer.py` — 旧版 sweep，已被 `MemoryRepository.sweep()` 取代

### 3.3 日程 Agent 确认流程

```
用户消息
  → schedule.py 检查 execute_confirmed_pending_mutation（如果是"确认"类文字）
  → 或走 schedule_agent agentic loop
      → LLM 调用工具（create_reminder 等）
      → _require_confirmation() 拦截写操作
      → _store_pending_mutation() 存 DB
      → SSE 发 pending_confirmation 事件
  → 前端 onPendingConfirm 显示按钮（存 pendingConfirmRef + 消息字段）
  → 用户点"确认执行" → POST /api/schedule/confirm
  → execute_confirmed_pending_mutation() 执行真实写操作
```

**注意**：`_require_confirmation` 里 `is_confirmation_text` 只认以下词：`确认 确定 可以执行 执行吧 就这样 yes confirm ok`。

### 3.4 依赖

钉钉解密依赖 `pycryptodome`，**容器镜像里没有**（未写入 requirements.txt）。每次 `docker build` 重建镜像后需要手动：
```bash
ssh aliyun-root "docker exec chatbot-backend-1 pip install --no-cache-dir pycryptodome"
```
永久修复：把 `pycryptodome` 加入 `backend/requirements.txt` 并重建镜像。

---

## 4. 前端架构

### 4.1 目录说明

```
frontend/src/
├── App.jsx                   ← 路由根，Sidebar + Tab 切换
├── main.jsx
├── index.css                 ← CSS variables（design tokens）
│
├── components/
│   ├── chat/                 ← 通用对话界面（ChatView, MessageBubble, ChatInput）
│   ├── schedule/             ← 日程 Agent 界面
│   │   ├── ScheduleView.jsx  ← 主界面（SSE 流、确认按钮、会话管理）
│   │   ├── ScheduleSidebar.jsx
│   │   ├── ScheduleOverview.jsx
│   │   ├── SchedulePayloadView.jsx
│   │   ├── ChaoxingStatus.jsx
│   │   ├── MemoryDetailDrawer.jsx
│   │   └── ImportModal.jsx
│   ├── settings/             ← 设置页各面板
│   │   ├── SettingsView.jsx  ← Tab 路由（provider / push / reminders / dingtalk / data）
│   │   ├── DingTalkStatus.jsx← 钉钉状态 + 手动同步
│   │   ├── ProviderSettings.jsx
│   │   ├── PushSettings.jsx
│   │   ├── RemindersPanel.jsx
│   │   └── DataPanel.jsx
│   ├── layout/               ← Sidebar, TabBar
│   └── notifications/        ← DailyPopup, NotificationCenter
│
├── hooks/
│   ├── useSSEStream.js       ← SSE 事件解析（text/tool/pending_confirmation/done）
│   └── useScheduleSessions.js← 会话 CRUD
│
├── api/                      ← fetch 封装
└── stores/                   ← Zustand stores
```

### 4.2 SSE 事件类型

`useSSEStream` 处理的事件 type：
- `text` — 流式文本
- `reasoning` — 思考内容
- `tool_start / tool_result` — 工具调用
- `schedule_payload` — 结构化日程数据（卡片）
- `pending_confirmation` — 需要用户确认（触发确认按钮）
- `done / cancelled / error`

### 4.3 确认按钮生命周期（ScheduleView.jsx）

```
onPendingConfirm → pendingConfirmRef.current = pending
                 → 消息附加 pendingConfirmation 字段
onDone (async)   → await loadMessages()  ← 必须 await，否则 DB reload 覆盖按钮
                 → 重新附加 pendingConfirmRef.current 到最后一条 assistant 消息
handleConfirm    → pendingConfirmRef.current = null → POST /api/schedule/confirm
handleCancel     → pendingConfirmRef.current = null
```

---

## 5. iOS 应用

路径：`ChatBot/`（SwiftUI，Xcode 项目）

与 Web 后端无直接代码依赖，通过 HTTP API 调用。改动 iOS 不影响 Web，反之亦然。

---

## 6. 改动规则

### 改前核查

1. **确认源码位置**：Web 相关改动只在 `server-src/`，iOS 只在 `ChatBot/`
2. **先同步**：如果不确定本地是否最新，先 `rsync` 从服务器拉一次
3. **不要 rebuild 镜像**：除非你明确知道 Dockerfile 和 requirements 都是对的

### 改后部署

1. Python 文件：`py_compile` → `docker cp` → 服务器再次 `py_compile` → `docker restart`
2. 前端文件：`npm run build`（在 `server-src/frontend/`）→ 打包 tar → `docker cp` 解压进容器

### 不要碰的东西

- `web/` 目录下的任何文件（废弃）
- `plan.md / plan_round3.md / plan_round4.md`（已删除）
- `deploy_round3.sh / verify_round3.sh`（已废弃，手动部署流程见上）

---

## 7. 数据库

SQLite，路径由 `config.py` 的 `database_path` 决定，容器内挂载到：
```
/var/lib/docker/volumes/chatbot_chatbot_data/_data/chatbot.db
```

主要表：

| 表名 | 用途 |
|---|---|
| `chaoxing_memory_entries` | 统一 Memory 存储（所有来源） |
| `memory_sync_state` | 各来源的同步位点（last_synced_ts） |
| `memory_topic_index` | 实体关键词索引（供 engine 检索） |
| `chaoxing_session` | 学习通登录态 |
| `chaoxing_processed_ids` | 消息去重 |
| `conversations / messages` | 通用对话历史 |
| `schedule_sessions / schedule_messages` | 日程 Agent 对话历史 |
| `server_reminders / server_courses` | macOS Reminders/Calendar 镜像 |
| `settings` | KV 配置（含 schedule_pending_mutation） |
| `scheduled_notifications` | 待发推送 |
| `push_subscriptions` | Web Push 订阅 |

---

## 8. 已知问题 / 技术债

- `pycryptodome` 未写入 `requirements.txt`，容器重建后钉钉解密失效
- `services/memory_agent.py` 和 `services/memory_reducer.py` 是旧实现，未删除，仍有少量调用
- `schedule_agent.py` 里 `_parse_create_reminder` / `detect_and_store_pending_mutation` 是规则式预解析，和 LLM 工具调用并行，容易产生歧义（已修复误判，但两套机制并存仍是潜在问题）
