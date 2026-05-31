# Student-Agent

一个面向大学生的智能助手系统。集成学习通（Chaoxing）、钉钉（DingTalk）消息监控，配备 26 个工具的 LLM 日程代理、后台自主决策引擎、以及基于 PWA 的 Web Push 推送通知。

---

## 目录

- [快速部署](#快速部署)
- [启用 Push 通知（PWA）](#启用-push-通知pwa)
- [架构总览](#架构总览)
- [系统架构图](#系统架构图)
- [核心设计优势](#核心设计优势)
- [后端模块详解](#后端模块详解)
- [前端结构](#前端结构)
- [环境变量](#环境变量)
- [日常运维](#日常运维)

---

## 快速部署

### 前置条件

- Linux 服务器（推荐 Ubuntu 22.04+ / Debian 12+）
- Docker + Docker Compose v2
- 一个 LLM API Key（支持 OpenAI / Anthropic / Gemini / MiMo 或任何 OpenAI 兼容 API）

### 一键安装

```bash
git clone https://github.com/alanmacX/Student-Agent.git
cd Student-Agent/server-src
chmod +x install.sh
./install.sh
```

安装脚本会自动完成：

1. 检测 Docker 环境，配置国内镜像加速
2. 交互式创建 `.env` 配置文件（LLM 提供商、模型选择）
3. 可选生成 VAPID 密钥对（用于 Web Push 通知）
4. 可选安装钉钉桌面客户端 + Xvfb 虚拟显示（`--no-dingtalk` 跳过）
5. 构建并启动三个 Docker 容器
6. 等待健康检查通过，输出访问地址

### 手动部署

```bash
# 1. 复制并编辑配置
cp .env.example .env
vim .env

# 2. 构建并启动
docker compose up -d --build

# 3. 验证
curl http://localhost/health
# => {"status":"ok","chaoxing_logged_in":false}
```

### 升级

```bash
chmod +x upgrade.sh
./upgrade.sh
```

---

## 启用 Push 通知（PWA）

> **重要：必须通过 PWA 安装才能收到推送通知。** 直接在浏览器中访问网页无法接收后台推送。

### 为什么是 PWA？

Web Push Notification 是浏览器标准 API，但**只在 PWA（Progressive Web App）模式下才完整支持后台推送**。普通网页标签页在关闭后无法接收通知，而 PWA 安装到桌面后拥有独立的 Service Worker 生命周期，即使应用未打开也能收到推送。

### 安装步骤

1. 用 HTTPS 访问你的部署地址（PWA 要求安全上下文，localhost 除外）
2. 浏览器会提示"添加到主屏幕"或显示安装图标：
   - **iOS Safari**：分享按钮 → "添加到主屏幕"
   - **Android Chrome**：地址栏右侧安装图标，或菜单 → "添加到主屏幕"
   - **桌面 Chrome/Edge**：地址栏右侧安装图标
3. 安装后从主屏幕/桌面打开应用
4. 进入 **设置 → 推送通知**，点击"启用推送通知"
5. 允许通知权限

### 推送通知工作流

```
Standby Agent（每15分钟）
    │
    ├─ 读取：待办提醒、记忆条目、系统健康
    ├─ 决策：LLM 判断是否需要推送
    │
    └─ 推送 ──→ Web Push API ──→ Service Worker ──→ 系统通知
                                                    ├─ 点击 → 打开应用
                                                    ├─ 关闭 → 回执上报
                                                    └─ 投递 → 回执上报
```

推送支持：
- 高紧急振动模式 `[200, 100, 200]`
- 作业类通知 `requireInteraction`（需用户手动关闭）
- 投递/点击/关闭全链路追踪

---

## 架构总览

```
┌─────────────────────────────────────────────────────────────────┐
│                        用户设备（PWA）                            │
│  ┌──────────────────────────────────────────────────────────┐   │
│  │  React SPA (Vite)                                        │   │
│  │  ├─ Schedule Agent 聊天（26 个工具）                       │   │
│  │  ├─ Hub 仪表盘（提醒、记忆、便签）                         │   │
│  │  ├─ Settings（提供商、推送、用量统计）                      │   │
│  │  └─ Service Worker（Web Push 接收 + 离线缓存）             │   │
│  └──────────────────────────────────────────────────────────┘   │
└────────────────────────┬────────────────────────────────────────┘
                         │ HTTPS / SSE
┌────────────────────────▼────────────────────────────────────────┐
│                     Nginx 反向代理                                │
│  /          → frontend:80   （静态资源）                          │
│  /api/      → backend:8000  （REST API）                         │
│  /api/chat  → backend:8000  （SSE 流式，禁用缓冲）                │
└────────────────────────┬────────────────────────────────────────┘
                         │
┌────────────────────────▼────────────────────────────────────────┐
│                 FastAPI 后端 (Python 3.12)                        │
│                                                                  │
│  ┌─────────────┐  ┌──────────────┐  ┌────────────────────┐      │
│  │ Chat Agent   │  │ Schedule     │  │ Standby Agent      │      │
│  │ (通用对话)    │  │ Agent        │  │ (后台决策引擎)       │      │
│  │              │  │ (26个工具)    │  │ 每15分钟自主判断     │      │
│  └──────┬───────┘  └──────┬───────┘  └──────┬─────────────┘      │
│         │                 │                  │                    │
│  ┌──────▼─────────────────▼──────────────────▼─────────────┐     │
│  │              Universal Memory Engine                      │     │
│  │  process_message() → Intent Extract → Effect Execute     │     │
│  └──────────────────────┬───────────────────────────────────┘     │
│                         │                                        │
│  ┌──────────────────────▼───────────────────────────────────┐     │
│  │  SQLite (WAL mode)  ─  25+ 张表                          │     │
│  │  reminders │ events │ courses │ memory │ notifications   │     │
│  └──────────────────────────────────────────────────────────┘     │
│                                                                  │
│  ┌────────────────┐  ┌─────────────────┐  ┌─────────────────┐   │
│  │ Chaoxing 同步   │  │ DingTalk 解密    │  │ LLM Provider    │   │
│  │ (学习通 API)    │  │ + 三级过滤       │  │ Router          │   │
│  │ 5分钟轮询       │  │ AES-128-ECB     │  │ 多提供商支持     │   │
│  └────────────────┘  └─────────────────┘  └─────────────────┘   │
└──────────────────────────────────────────────────────────────────┘
                         │
          ┌──────────────┼──────────────┐
          ▼              ▼              ▼
   ┌────────────┐ ┌────────────┐ ┌────────────┐
   │ 学习通 API  │ │ 钉钉桌面端  │ │ LLM API    │
   │ (Chaoxing)  │ │ (Xvfb)     │ │ OpenAI/... │
   └────────────┘ └────────────┘ └────────────┘
```

---

## 系统架构图

### Agent 工具调用流程

```
用户消息: "帮我建一个明天下午3点的提醒"
    │
    ▼
┌─────────────────────────────────────────────┐
│  Keyword Router（中文关键词匹配）             │
│  "提醒" → 匹配 create_reminder 工具          │
│  仅将相关工具传给 LLM（节省 token）           │
└────────────────────┬────────────────────────┘
                     ▼
┌─────────────────────────────────────────────┐
│  build_turn_context()                        │
│  注入压缩上下文：                              │
│  ├─ 未来48h 提醒/日程/课程                    │
│  ├─ 高重要度记忆条目                          │
│  ├─ 用户偏好（user_memory）                   │
│  └─ 学习通登录状态                            │
└────────────────────┬────────────────────────┘
                     ▼
┌─────────────────────────────────────────────┐
│  LLM 推理 → 输出 tool_call                   │
│  create_reminder({title: "...", due_at: ...})│
└────────────────────┬────────────────────────┘
                     ▼
┌─────────────────────────────────────────────┐
│  Confirmation Pattern（写操作确认）            │
│  "确认创建这个提醒吗？" → 等待用户确认        │
│  用户回复 "确认" → 执行写入                   │
└────────────────────┬────────────────────────┘
                     ▼
               SQLite 写入成功
```

### Standby Agent 决策流程

```
┌──────────────────────────────────────────────┐
│  APScheduler 每 15 分钟触发                    │
└────────────────────┬─────────────────────────┘
                     ▼
┌──────────────────────────────────────────────┐
│  Context Hash 计算                            │
│  hash = MD5(MAX(updated_at) × 3表 + psutil)  │
│  与上次 no_action 的 hash 比较                 │
│  相同 → 跳过 LLM 调用（省 token）              │
└────────────────────┬─────────────────────────┘
                     ▼ (hash 不同)
┌──────────────────────────────────────────────┐
│  _build_context() 聚合数据源                   │
│  ├─ 待办提醒（未完成、未过期）                  │
│  ├─ 高重要度记忆（有 action_hint）              │
│  ├─ 未送达通知                                 │
│  ├─ 系统健康（CPU/RAM/Disk）                   │
│  └─ 用户偏好                                   │
└────────────────────┬─────────────────────────┘
                     ▼
┌──────────────────────────────────────────────┐
│  LLM 决策（仅 2 个工具：push / no_action）     │
│  决策标准：                                    │
│  ├─ 截止时间 < 3h → 高紧急推送                 │
│  ├─ 截止时间 < 24h 且未通知 → 普通推送          │
│  ├─ 高重要度未处理消息 → 考虑推送               │
│  ├─ 系统指标异常 → 高紧急推送                   │
│  └─ 无事 → no_action                          │
└────────────────────┬─────────────────────────┘
                     ▼
┌──────────────────────────────────────────────┐
│  推送执行 → Web Push API → PWA Service Worker │
│  记录到 standby_agent_log（决策+token+耗时）   │
│  记录到 notification_log（去重）               │
└──────────────────────────────────────────────┘
```

### Universal Memory Engine 管道

```
消息来源                    Universal Memory Engine
─────────                  ─────────────────────────
Chaoxing 消息  ──┐
                 ├──→  NormalisedMessage  ──→  process_message()
DingTalk 消息  ──┘          │
                            ▼
                    ┌───────────────┐
                    │ 噪声过滤       │  "好的"/"谢谢"/"收到" → 跳过
                    └───────┬───────┘
                            ▼
                    ┌───────────────┐
                    │ 意图提取       │  1 次 LLM 调用 → IntentGraph
                    │ (IntentGraph) │  每个 intent: type + entity + confidence
                    └───────┬───────┘
                            ▼
                    ┌───────────────┐
                    │ 并行子代理     │  asyncio.gather: 纯 SQL 验证
                    │ (无 LLM)      │  实体存在性 + 时间冲突检测
                    └───────┬───────┘
                            ▼
                    ┌───────────────┐
                    │ 效果合并+去重  │  按 (type, entity_key) 去重
                    │               │  多个 push_now 合并为单条通知
                    └───────┬───────┘
                            ▼
                    ┌───────────────┐
                    │ SQL 事务执行   │  upsert_memory / push_now
                    │               │  schedule_push / archive
                    └───────┬───────┘
                            ▼
                    memory_entries + notifications
```

---

## 核心设计优势

### 1. Universal Memory Engine — 一个入口处理所有消息源

传统做法是每接一个平台就写一套独立的消息处理逻辑。本系统用一个 `process_message()` 函数统一处理所有来源（学习通、钉钉、以及未来任何新平台），内部管道：

- **单次 LLM 调用**提取意图（IntentGraph），其余全部是纯 SQL 操作
- **置信度阈值 0.7** 过滤低质量意图
- **模糊实体匹配**：CJK 二元组 + ASCII 子串生成 topic index，O(1) 查找
- **五级记忆层次**：CRITICAL → ACTIONABLE → CONTEXT → REFERENCE → HISTORICAL，自动计算层级

新增消息源只需写一个 `_normalise()` 适配函数，无需改动引擎核心。

### 2. 关键词路由 — 省 token 的工具过滤

Schedule Agent 拥有 26 个工具，但每次调用不需要全部传给 LLM。系统用中文关键词预匹配：

```python
"create_reminder": ["提醒", "新建提醒", "remind", "设个提醒", "别忘了"],
"get_chaoxing_assignments": ["作业", "assignment", "任务", "截止"],
```

用户说"帮我建个提醒"，只有提醒相关工具被传入 LLM，其他 20+ 个工具不占 token。始终包含 `get_schedule_context` 作为基础上下文。

### 3. Context Hash 优化 — 无变化时跳过 LLM

Standby Agent 每 15 分钟运行一次，但大多数时候没有新数据。通过计算三个表的 `MAX(updated_at)` + 系统指标的 MD5 哈希，与上次 `no_action` 记录的哈希比较：

- **哈希相同** → 跳过整个 LLM 调用，记录为 `skipped_no_change`
- **哈希不同** → 执行 LLM 决策

这将空转时的 API 成本降为零。

### 4. Confirmation Pattern — 写操作不可逆保护

所有 create/update/delete 操作不会直接执行。流程：

1. Agent 输出 tool_call → 系统存储 pending mutation 到数据库
2. 向用户展示确认信息："确认创建这个提醒吗？"
3. 用户回复含"确认"/"确定"/"ok"/"yes" → 执行
4. 否则 → 丢弃

防止 LLM 幻觉导致的数据误操作。

### 5. 钉钉本地数据库解密 — 无需官方 API

直接读取钉钉桌面客户端的本地 SQLite 数据库，通过 AES-128-ECB 解密（密钥来自 `libsync.so`），包括 WAL 帧的实时解密。配合三级过滤管道：

| 阶段 | 方法 | 作用 |
|------|------|------|
| Stage 0 | 用户配置 | 白名单/黑名单会话 + 自定义关键词 |
| Stage 1 | 正则匹配 | 确定性粗筛（CS 关键词、课程模式） |
| Stage 2 | LLM 分类 | 人格感知分类器，输出 notify/interest/drop |

分类后的消息自动流入 Universal Memory Engine，参与记忆提取和推送决策。

### 6. 多 LLM 提供商支持

- 内置提供商：小米 MiMo
- 支持任何 OpenAI 兼容 API（通过 Settings → 提供商配置自定义）
- Agent 层自动适配 OpenAI / Anthropic / Gemini 协议差异
- Token 用量追踪 + OpenRouter 实时定价（24h 缓存）→ 精确成本统计

### 7. SSE 流式响应

Chat 和 Schedule Agent 的响应通过 Server-Sent Events 流式传输，nginx 配置了专用的 SSE 路由（禁用缓冲、300s 超时、chunked transfer），实现打字机效果的实时对话体验。

---

## 后端模块详解

### 目录结构

```
backend/app/
├── main.py                    # FastAPI 入口，lifespan 管理
├── config.py                  # pydantic-settings 配置
├── database.py                # SQLite schema + 迁移
├── models.py                  # Pydantic 数据模型
│
├── routers/                   # REST API 端点
│   ├── analytics.py           # /api/analytics — 用量统计 + 定价管理
│   ├── chaoxing.py            # /api/chaoxing — 学习通操作
│   ├── chat.py                # /api/conversations — 聊天（SSE）
│   ├── conversations.py       # /api/conversations — CRUD
│   ├── data.py                # /api/data — 数据导入导出
│   ├── providers.py           # /api/providers — LLM 提供商管理
│   ├── push.py                # /api/push — Web Push 订阅
│   ├── reminders.py           # /api/reminders — 提醒 CRUD
│   ├── schedule.py            # /api/schedule — 日程代理（SSE）
│   └── settings.py            # /api/settings — 应用设置
│
├── services/                  # 业务逻辑层
│   ├── agent_service.py       # 通用 Agent 循环（tool call 执行）
│   ├── api_service.py         # LLM API 客户端（OpenAI/Anthropic/Gemini）
│   ├── schedule_agent.py      # Schedule Agent（26 个工具 + 关键词路由）
│   ├── provider_registry.py   # 提供商注册 + 解析
│   ├── pricing_service.py     # OpenRouter 定价获取（24h 缓存）
│   ├── chaoxing_service.py    # 学习通 API 客户端
│   ├── push_service.py        # Web Push 发送
│   └── ...
│
├── tasks/                     # 后台定时任务
│   ├── scheduler.py           # APScheduler 调度器
│   ├── standby_agent.py       # Standby Agent（15分钟轮询）
│   ├── chaoxing_sync.py       # 学习通同步（5分钟）
│   ├── health_monitor.py      # 系统健康监控
│   └── notification_sender.py # 定时通知发送
│
├── memory/                    # Universal Memory Engine
│   ├── engine.py              # 核心管道（意图提取 → 效果执行）
│   └── base.py                # MemoryRepository + 五级层次
│
├── dingtalk/                  # 钉钉集成
│   ├── dingtalk_service.py    # AES 解密 + 数据库读取
│   ├── filters.py             # 三级过滤管道
│   ├── classifier.py          # LLM 分类器（人格感知）
│   ├── task.py                # 定时同步调度
│   ├── memory_provider.py     # 消息 → Memory Engine 适配
│   ├── router.py              # /api/dingtalk 端点
│   └── schema.py              # 钉钉相关表定义
│
└── chaoxing/                  # 学习通适配
    └── memory_provider.py     # 消息 → Memory Engine 适配
```

### 数据库表一览（25+ 张表）

| 分类 | 表名 | 用途 |
|------|------|------|
| 核心 | `settings` | 键值配置存储 |
| 对话 | `conversations`, `messages` | 普通聊天 |
| 对话 | `schedule_sessions`, `schedule_messages` | 日程代理对话 |
| 日程 | `server_reminders`, `server_events`, `server_courses` | 提醒/日程/课程 |
| 学习通 | `chaoxing_session`, `chaoxing_courses`, `chaoxing_assignments` | 学习通数据 |
| 记忆 | `chaoxing_memory_entries` | 通用记忆存储（多源） |
| 记忆 | `memory_topic_index` | O(1) 实体查找索引 |
| 记忆 | `memory_sync_state` | 各源同步游标 |
| 钉钉 | `dingtalk_messages`, `dingtalk_sync_state`, `dingtalk_filter_config` | 钉钉消息+配置 |
| 推送 | `push_subscriptions`, `notification_log`, `scheduled_notifications` | 推送订阅+日志 |
| Agent | `standby_agent_log`, `user_memory` | 决策日志+用户偏好 |
| 计费 | `model_pricing` | 模型定价覆盖 |
| 提供商 | `custom_providers` | 自定义 LLM 提供商 |

---

## 前端结构

```
frontend/src/
├── api/                       # API 客户端层
│   ├── client.js              # 基础 HTTP 客户端（apiFetch / apiStream）
│   ├── schedule.js, chat.js, chaoxing.js, ...
│
├── components/
│   ├── chat/                  # 通用聊天界面
│   │   ├── ChatView.jsx       # 主聊天视图
│   │   ├── ChatInput.jsx      # 输入框 + 斜杠命令面板
│   │   ├── commands.js        # /remind /note /status /clear
│   │   └── MessageBubble.jsx  # 消息气泡 + 工具调用渲染
│   │
│   ├── schedule/              # 日程代理界面（最丰富的模块）
│   │   ├── ScheduleView.jsx   # 日程代理聊天
│   │   ├── ScheduleOverview.jsx # 概览卡片（今日摘要+待办）
│   │   ├── StatusStrip.jsx    # 系统健康指示器
│   │   ├── TokenSummary.jsx   # Token 用量摘要
│   │   └── ImportModal.jsx    # 课表导入
│   │
│   ├── hub/                   # Hub 仪表盘
│   │   └── HubView.jsx        # 提醒面板 + 便签
│   │
│   ├── settings/              # 设置面板
│   │   ├── ProviderSettings.jsx   # LLM 提供商配置
│   │   ├── DingTalkStatus.jsx     # 钉钉状态 + QR 登录
│   │   ├── PushSettings.jsx       # 推送通知设置
│   │   └── RemindersPanel.jsx     # 提醒管理
│   │
│   ├── notifications/         # 通知组件
│   │   ├── NotificationCenter.jsx # 通知历史
│   │   └── DailyPopup.jsx         # 每日摘要弹窗
│   │
│   └── layout/                # 布局组件
│       ├── Sidebar.jsx        # 侧边栏导航
│       └── TabBar.jsx         # 底部标签栏
│
├── hooks/                     # 自定义 Hooks
├── stores/                    # Zustand 状态管理
└── lib/                       # 工具函数
```

---

## 环境变量

| 变量 | 默认值 | 说明 |
|------|--------|------|
| `DATABASE_PATH` | `/data/chatbot.db` | SQLite 数据库路径 |
| `STANDBY_AGENT_PROVIDER` | `openai` | Standby Agent 的 LLM 提供商 |
| `STANDBY_AGENT_MODEL` | `gpt-4o-mini` | Standby Agent 的模型 |
| `VAPID_PRIVATE_KEY` | — | Web Push VAPID 私钥 |
| `VAPID_PUBLIC_KEY` | — | Web Push VAPID 公钥 |
| `VAPID_MAILTO` | `mailto:admin@example.com` | VAPID 联系邮箱 |
| `DINGTALK_AES_KEY` | `9f6ac1b97a9021bd` | 钉钉数据库解密密钥 |
| `DINGTALK_SELF_UID` | — | 你自己的钉钉 UID |
| `CHAOXING_SYNC_INTERVAL` | `300` | 学习通同步间隔（秒） |
| `DEBUG` | `false` | 调试模式 |

---

## 日常运维

```bash
# 查看容器状态
docker compose ps

# 查看后端日志
docker compose logs -f backend

# 重启单个服务
docker compose restart backend

# 进入后端容器调试
docker compose exec backend python -c "from app.database import *; ..."

# 数据库备份
docker compose exec backend cp /data/chatbot.db /data/chatbot.db.bak

# 钉钉状态（如已启用）
ssh your-server "systemctl status dingtalk dingtalk-xvfb dingtalk-qr"
```
