# Student-Agent v2

一个自托管的学生个人 AI 日程管家。它同步学习通、钉钉、本地日程和提醒，把高价值信息沉淀到统一数据库，并通过一个按需查询的 Schedule Agent 帮你调查、整理和执行任务。

v2 的核心变化：不再把 48 小时上下文硬塞进 prompt，也不再用硬编码 intent 决定工具。现在是 **light router 先选工具，主 agent 再按需只读查询数据库**；dashboard 也从独立 briefing 服务改成基于数据库 hash 的轻量刷新。

![Student-Agent v2 architecture](docs/architecture-v2.svg)

## 当前架构

前端是 React + Vite PWA，后端是 FastAPI + SQLite + APScheduler，部署层是 Docker Compose + Nginx。

Agent 链路分成两层：

- **Light Router / Briefing Agent**：便宜、快，只负责两件事：给当前 query 选择最小工具清单；在 dashboard 数据 hash 变化时生成一句 briefing 和最多 5 个行动项。
- **Detailed Schedule Agent**：负责真实回答和执行。它拿到 light router 给的工具清单后，通过工具主动拉取证据，不再依赖预注入的大块 context。

这里不是“两个数据库工具模式”。真正的工具面是：

- `get_current_time`：返回 Asia/Shanghai 与 UTC 的当前时间、今天、本周窗口。
- `get_data_schema`：告诉 agent 哪些表能查、时间字段怎么用、importance/tier 怎么理解。
- `search_database`：只读 SQL 查询。只允许 `SELECT` 和 `PRAGMA table_info`，只允许业务白名单表，屏蔽 token/cookie/key 等敏感字段。
- `get_record_detail`：对某条白名单记录拉更完整字段。
- 领域工具：课程、提醒、日历、学习通、消息、知识库、推送等。写操作仍走确认门，不会让 agent 自由写 SQL。

`search_database` 自带 `detail_level=brief|detailed`，它只控制返回字段截断长度；不是另一个 agent 模式。常规回答用 `brief`，需要核对原文或追问细节时再拉 `detailed`。

## 数据获取策略

旧版：

```text
server 预查 48h 数据 -> 拼进 build_turn_context() -> agent 被动读取
硬编码关键词 intent -> 固定工具清单
dashboard_briefing 服务 -> 独立生成首页文案
```

v2：

```text
用户 query -> light router 选工具 -> detailed agent 按需调用只读查询工具
dashboard /today -> SQL payload builder -> hash 变化才触发 light briefing
时间输入 -> Asia/Shanghai 解析 -> UTC ISO 存储和比较
```

这个改法保留现有数据库结构、importance、hierarchy_tier 和业务工具，只改变数据进入 agent 的方式：从“推”变成“拉”。

## Token 策略

v2 的省 token 点：

- 去掉每轮 `build_turn_context()` 的 48h 全量注入。
- 聊天历史窗口从 40 条缩到 12 条，长期事实必须由数据库工具拉取。
- light router 只输出 JSON 工具名，模型可在 Settings 单独选更便宜的。
- dashboard briefing 只在内容 hash 变化时刷新，普通打开首页不跑 LLM。
- tool result 默认 brief 截断，细节只在必要时二次查询。
- router、dashboard briefing、agent loop 都写入 token 预算表，账不会漏。

可重复跑 token 对比：

```bash
cd server-src
ACCESS_TOKEN=xxx BASE_URL=https://your-domain \
  python3 scripts/token_compare.py --label v2 --out /tmp/v2-tokens.json
```

如果有旧版结果：

```bash
python3 scripts/token_compare.py \
  --base-url https://your-domain \
  --token xxx \
  --baseline-json /tmp/baseline-tokens.json \
  --label v2
```

## 时间口径

统一规则：

- 用户无时区输入按 `Asia/Shanghai` 解释。
- 数据库存储和 SQL 比较统一用 UTC ISO，例如 `2026-06-12T10:30:00+00:00`。
- dashboard、agent schema、查询工具都暴露本地日/周窗口对应的 UTC 边界。
- 钉钉毫秒 epoch 会在查询说明中标注，避免和 ISO 字符串混用。

核心实现位于 `server-src/backend/app/services/time_utils.py`。

## Prompt 清单

当前需要维护的 prompt 有四类：

- `schedule_agent.STATIC_SYSTEM_PROMPT`：主 agent 行为约束。现在保持短 prompt，要求事实来自工具结果，不再塞业务上下文。
- `tool_router.select_tools_for_query()`：light router，只输出工具名 JSON。这里要避免写“回答用户”类指令。
- `dashboard_v2._briefing_system_prompt()`：首页轻 briefing，只基于输入 JSON 输出结构化摘要。
- 同步/过滤类 prompt：学习通 memory 提炼、钉钉过滤、standby push 决策。它们仍是各自模块的局部 prompt，不参与 schedule chat 的 context 注入。

Prompt 维护原则：主 agent 要少背规则，多看证据；router 要少选工具；dashboard briefing 要短、可缓存、可失败回退。

## 快速部署

服务器要求：

- Linux，推荐 Ubuntu 22.04+ 或 Debian 12+
- Docker + Docker Compose v2
- 一个 OpenAI 兼容或内置支持的 LLM Provider

安装：

```bash
git clone https://github.com/alanmacX/Student-Agent.git /opt/chatbot
cd /opt/chatbot/server-src
bash install.sh
```

升级：

```bash
cd /opt/chatbot
bash server-src/upgrade.sh
```

`upgrade.sh` 会自动切到 `server-src`，默认从当前源码构建 backend/frontend，启动容器，并检查：

- `GET /health`
- `GET /api/dashboard/today`

常用参数：

- `--skip-pull`：不拉 git。
- `--skip-build`：不重建镜像，只重启。
- `--pull-images`：优先拉 ghcr 预构建镜像。
- `--no-healthcheck`：跳过部署后健康检查。

## 设置

进入 Settings 后至少确认：

- **Schedule Agent Provider**：主 agent 模型，负责复杂推理和工具调用。
- **Light Router / Briefing Agent**：工具路由和 dashboard briefing 模型，建议选便宜快速模型。
- **Filter Provider**：消息过滤/提炼使用的模型。
- **Token Budget**：每日预算；analytics 会汇总 chat、schedule、standby、router、dashboard briefing。

## 本地验证

```bash
# 后端语法检查
python3 -m compileall server-src/backend/app

# 前端构建
cd server-src/frontend && npm run build

# token 采样
cd ../
BASE_URL=http://localhost ACCESS_TOKEN=xxx python3 scripts/token_compare.py
```

## 目录

```text
.
├── docs/
│   └── architecture-v2.svg
├── server-src/
│   ├── backend/
│   │   └── app/
│   │       ├── routers/
│   │       ├── services/
│   │       ├── memory/
│   │       └── tasks/
│   ├── frontend/
│   ├── scripts/
│   │   └── token_compare.py
│   ├── docker-compose.yml
│   ├── install.sh
│   └── upgrade.sh
└── README.md
```

## 运维排查

```bash
cd /opt/chatbot/server-src
docker compose ps
docker compose logs --tail=160 backend
curl -fsS http://localhost/health
curl -fsS -H "Authorization: Bearer $ACCESS_TOKEN" http://localhost/api/dashboard/today
```

如果 agent 回答短视，优先检查该轮 SSE 里是否出现了 `search_database` / `get_data_schema` 工具调用；如果没有，先看 light router 输出和 fallback 工具清单。
