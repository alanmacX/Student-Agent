# Student-Agent 重构实现文稿（给 coding agent）

> 状态：设计已与用户确认，按本文实施。单用户系统（只有一个学生用户），部署在公网阿里云，走 API 计费。
> 三大目标：**不漏不假**（无幻觉消息、无漏提醒）、**省 token**、**用着省心**。
> 本文是唯一权威设计文档。与现状冲突时以本文为准，但**禁止删除本文未明确判死刑的现有功能**。

## 三端同步铁律（每个改动都适用）

系统已在 `ssh aliyun-root:/opt/chatbot/` 生产运行。**任何改动必须三端同步：本地 `server-src/` ↔ 云端 `/opt/chatbot/` ↔ GitHub（alanmacX/Student-Agent, main）**，三者不一致即视为事故。

每个改动单元的固定流程：
1. **改前**：`rsync -az --exclude='node_modules' --exclude='dist' aliyun-root:/opt/chatbot/ server-src/` 拉平云端 → `git diff --stat` 检查未编辑文件有无异常大删除（git 漂移坑），有则 `git checkout HEAD --` 还原后再开工。
2. **本地改**：在 `server-src/` 编辑（唯一权威源；`web/` 是废弃副本禁止使用），`py_compile` 自检。
3. **上云**：Python → `scp` 到 `/opt/chatbot/` 对应路径 → `docker cp` 进 `chatbot-backend-1` → 容器内 `py_compile` → `docker restart chatbot-backend-1`；前端 → 本地 `npm run build` → tar → `docker cp` 解压进 `chatbot-frontend-1`。**禁止 `docker build` / `docker compose up --build`**（会冲掉容器内代码）。
4. **进 git**：每完成一个可验收的改动单元就 commit（信息写清阶段号），push 到 GitHub。禁止云端先行不落 git、禁止本地堆积多阶段不 push。
5. 阶段验收（§9/§11）通过后打 tag（如 `redesign-p1`），作为回滚锚点。

数据库 schema 迁移只走 `database.py::run_migrations`（容器重启自动执行），禁止手工 ssh 改线上 schema —— 保证三端代码一致即 schema 一致。

---

## 0. 总架构（目标态）

```
钉钉/学习通消息 → [F0/F1 代码粗筛] → [F2 light-LLM×筛查卡] → 值得入库?
   → [Reconciler 主模型×上下文包] → 结构化操作(作用于具体id)
   → [代码执行器] items/entities/facts 增删改 + 提醒阶梯生成/撤销
   → scheduled_notifications 队列 → 每分钟纯代码发送 → PWA push
夜间蒸馏(1次LLM/天)：归档items → 实体卡片notes + facts + 筛查卡再生成
用户对话/反馈 → watches/facts 写入 → 反哺筛查卡
```

LLM 调用全表（除此之外任何地方不得调 LLM）：
| 调用点 | 模型档 | 频率 | 上下文 |
|---|---|---|---|
| F2 筛查 | light（独立 filter_model 配置） | 每批15条不确定消息 | 固定prompt+筛查卡（字节级一天不变，吃prompt cache） |
| Reconciler | 主力模型 | 每条过筛消息1次，封顶2轮 | 上下文包≤600 token |
| 夜间蒸馏 | 主力模型 | 1次/天 | 当日归档items+反馈 |
| 早晚简报文案 | light | 2次/天 | 现有机制，保留纯代码fallback |
| 用户对话 agent | 主力模型 | 用户主动发起 | 预组装上下文包 |

**被判死刑的（删除）**：standby_agent 的 15 分钟 LLM 决策循环、`services/memory_agent.py`、`services/memory_reducer.py`、根目录 `web/` 旧副本、engine.py 的 IntentGraph/Effect/merger 泛化机制（被 Reconciler 取代）。
**明确保留的**：F0/F1 过滤代码、MemoryRepository 及两层去重、canonical keys（keys.py）、dispatch.py 确定性推送id、deadline_check、scheduled_notifications 发送器、health_monitor、早晚简报、message_drop_log、日程 agent 的课表/提醒/日历工具、import_timetable、PWA 推送全链路、数据导入导出、token analytics。

---

## 1. 数据模型（迁移在 database.py 的 run_migrations 中追加，禁止破坏现有表）

### 1.1 新表 `entities`
```sql
CREATE TABLE IF NOT EXISTS entities (
  id          TEXT PRIMARY KEY,            -- 'ent_' + uuid8
  etype       TEXT NOT NULL,               -- course|person|competition|project|org|watch|self
  name        TEXT NOT NULL,               -- 规范名："数据结构"
  aliases     TEXT NOT NULL DEFAULT '[]',  -- JSON 数组，别名/缩写/英文名
  attrs       TEXT NOT NULL DEFAULT '{}',  -- JSON：course→{teacher,location,weekday,...}
  notes       TEXT NOT NULL DEFAULT '',    -- 蒸馏维护的自由文本卡片（≤500字，蒸馏负责截断）
  status      TEXT NOT NULL DEFAULT 'active',  -- active|archived
  created_at  TEXT NOT NULL,
  updated_at  TEXT NOT NULL
);
CREATE INDEX IF NOT EXISTS idx_entities_name ON entities(name);
```
初始化：迁移时从 `server_courses` 去重课程名自动建 course 实体（teacher/location 进 attrs）。watches 即 `etype='watch'` 的实体，attrs 存 `{keywords:[], until:iso, note}` —— **不建独立 watches 表**。

### 1.2 items = 现有 `chaoxing_memory_entries` 改造（不重建表，加列）
```sql
ALTER TABLE chaoxing_memory_entries ADD COLUMN entity_id TEXT;        -- 可空，挂靠实体
ALTER TABLE chaoxing_memory_entries ADD COLUMN raw_ref   TEXT;        -- 溯源：来源消息id（防幻觉审计用）
ALTER TABLE chaoxing_memory_entries ADD COLUMN status    TEXT NOT NULL DEFAULT 'active'; -- active|done|superseded|expired
```
**sweep 改归档**：`MemoryRepository.sweep()` 不再 DELETE，改为 `status='expired', archived_at=now`。容量上限改为只对 `status='active'` 计数。归档行永久保留（蒸馏的原料）。topic_index 孤儿清理逻辑保留但只清指向不存在行的。

### 1.3 新表 `facts`
```sql
CREATE TABLE IF NOT EXISTS facts (
  id         TEXT PRIMARY KEY,
  entity_id  TEXT,                 -- 可空（关于用户自己的 fact 挂 self 实体）
  text       TEXT NOT NULL,        -- 一句话陈述："张老师常周五调课"
  source     TEXT NOT NULL,        -- user_told|distilled|feedback
  confidence REAL NOT NULL DEFAULT 0.8,
  created_at TEXT NOT NULL,
  updated_at TEXT NOT NULL,
  archived_at TEXT
);
```
迁移：现有 `user_memory` 表（source='user_told'）的行复制进 facts，旧表保留只读不再写。

### 1.4 FTS5 全文索引
```sql
CREATE VIRTUAL TABLE IF NOT EXISTS kb_fts USING fts5(
  doc_id UNINDEXED, doc_type UNINDEXED, content, tokenize='unicode61'
);
```
- 写入钩子：items upsert / entities 更新 / facts 写入时同步 REPLACE 进 kb_fts（doc_type: item|entity|fact）。
- 中文无分词器：除整句入索引外，content 额外附加空格分隔的 2-gram（写入时由代码生成，仅入索引列，不污染原数据）。
- 迁移时对存量 active items 全量回填。
- `memory_topic_index` 保留（去重对账还用它），但检索路径换成 FTS5。

### 1.5 新表 `notification_feedback`（反馈回路）
```sql
CREATE TABLE IF NOT EXISTS notification_feedback (
  id TEXT PRIMARY KEY, notif_tag TEXT, item_id TEXT,
  action TEXT NOT NULL,   -- clicked|dismissed|done|mute_kind
  created_at TEXT NOT NULL
);
```
现有 SW 回执（/received /clicked /dismissed）已落 notification_log；新增轻量端点 `POST /api/notifications/feedback` 供 SW 的 action button 调用（见 §6.3）。

---

## 2. 过滤层（dingtalk/filters.py + classifier.py 改造）

### 2.1 F0/F1 保持现状
群黑白名单、自定义关键词、噪音正则、明显课程内容直通（verdict=notify）、群聊不确定 → needs_llm。**不动**。

### 2.2 F2：light LLM × 筛查卡（classifier.py 重写内部，对外接口 classify_messages 签名不变）
- 新增 settings 键 `filter_provider` / `filter_model`（settings 表，UI 在设置页加两个输入框）；为空时回退主力模型。
- **筛查卡**：存 settings 键 `screening_card`，由蒸馏任务每日再生成（§5），结构固定：
```
【我的课】<course实体名/老师/上课日 一行一条，≤20条>
【我在追】<watch实体 name(until) 列表>
【判例】<facts中 source='feedback'|'distilled' 且标记为filter_rule的，≤15条>
```
- 系统 prompt 固定（写死在代码常量，不含日期等易变内容）；user 消息 = 筛查卡 + 待筛批。**筛查卡放 user 消息开头且当天字节不变**，保证 prompt cache 前缀命中。
- 输出固定编码：`[{"i":0,"v":2}]`，v: 0=drop 1=interest 2=notify。解析失败/LLM异常的兜底**改向**：含 `截止|考试|作业|调课|ddl|提交|报名` 或命中课程实体名的 → notify，其余 → interest（现状是全部→interest，会漏报，必须改）。
- drop 不入主库，写 message_drop_log（现有机制，保留 cap）。

---

## 3. Reconciler（新文件 app/services/reconciler.py，取代 engine.process_message）

### 3.1 入口
```python
async def reconcile_message(msg: dict, db_path, provider, model, api_key, now) -> ReconcileResult
```
调用方：`dingtalk/task.py::run_dingtalk_memory_task` 和 `chaoxing/memory_provider.py` 把现在调 `engine.process_message` 的地方换掉。engine.py 文件保留到验收完成后再删（见 §9 阶段4）。

### 3.2 上下文包（纯 SQL，≤600 token，这是防幻觉的根基）
1. 实体召回：消息文本对 entities.name+aliases 做包含匹配 + kb_fts MATCH，取 top3 实体。
2. 对每个命中实体取：卡片（name/attrs/notes前200字）+ 该实体 active items（**带 id**，≤8条，含 due）。
3. 加：未来7天课表切片（标题+时间+**行id**）、相关 facts ≤5 条、当前时间戳。
4. 没命中任何实体 → 给"实体目录"（全部 active 实体的 name+etype 单行列表）让 LLM 选择挂靠或新建。

### 3.3 输出 schema（固定编码，严格校验）
```json
{"ops":[
 {"op":"new_item","kind":"assignment|exam|course_change|notice|signup",
  "entity":"ent_xx|new:课程名","title":"...","due":"ISO|null","importance":2},
 {"op":"update_item","id":"<必须来自上下文包>","due":"ISO","note":"..."},
 {"op":"cancel_item","id":"<同上>","scope_note":"本周三次课"},
 {"op":"cancel_course_rows","ids":["<server_courses行id，来自切片>"]},
 {"op":"new_fact","entity":"ent_xx","text":"..."},
 {"op":"push_now","title":"≤15字","body":"≤50字","ref_item":"id|null"},
 {"op":"conflict","a":"...","b":"...","question":"≤40字"}
],"need_more":false}
```
- `need_more=true` 时允许**一次**追加工具调用（`lookup_entity(name)` 返回该实体完整卡片+items），然后必须收敛。总轮数硬上限 2。
- **校验器（代码，防幻觉核心）**：update/cancel 的 id 必须存在于本次上下文包给出的 id 集合，否则丢弃该 op 并 WARN 入日志；due 必须可解析且（新建时）≥ now-1h；push_now 的 ref_item 若给出必须真实存在。**LLM 永远不能凭空操作它没见过的 id。**
- `conflict` op → 不改数据，推一条带两个 action 按钮的确认推送（§6.3），用户点选后由回调端点执行真正的 update。

### 3.4 执行器（代码，事务内）
- new_item → MemoryRepository.upsert（现有两层去重原样走）→ 成功后**生成提醒阶梯**（§4.1）→ 同步 kb_fts。
- update_item（due 变化）→ 改行 → **撤销旧阶梯 + 重排新阶梯** → 推一条"变更通知"。
- cancel_item / cancel_course_rows → status='superseded' / server_courses 行 notes 标记 cancelled → **撤销其阶梯** → 推"取消通知"。
- 撤销 = `DELETE FROM scheduled_notifications WHERE source_id LIKE '<item_id>%' AND sent_at IS NULL`（source_id 规范见 §4.1）。
- 每个 item 写 raw_ref=消息id，溯源可审计。

---

## 4. 通知系统（事件驱动 + 队列）

### 4.1 提醒阶梯（新文件 app/services/ladder.py，纯代码）
```python
def build_ladder(kind, due, importance, now) -> list[(trigger_iso, title_tpl, body_tpl)]
```
| kind | 阶梯 |
|---|---|
| assignment | T-3天20:00, T-1天20:00, 当天-2h（已过的档位跳过） |
| exam | T-7天, T-1天20:00, 当天-3h |
| course_change/cancel | 立即 + 事发当天07:30 |
| signup(报名/比赛) | T-3天, 截止当天09:00 |
| notice(无due) | 不排队（importance≥high 时仅立即推一条） |
写入 `scheduled_notifications` 用 dispatch.schedule_push（确定性 id），**source_id 统一为 `{item_id}:{档位名}`** —— 撤销级联靠这个前缀匹配，是硬约束。

### 4.2 定时任务表（scheduler.py 目标态）
| job | 周期 | 性质 |
|---|---|---|
| scheduled_notifications 发送 | 1min | 纯代码，保留 |
| deadline_check | 5min | 保留（学习通直抓的保险层），其 memory_high 推送**移除**（与 push_now 重叠，二选一收敛到 Reconciler 的 push_now） |
| dingtalk_sync / dingtalk_memory / chaoxing probe | 现状 | 保留 |
| **ladder_audit（新）** | 1h | 纯 SQL：找 `status='active' AND due>now` 但队列中无未发阶梯行的 item → 补排并 WARN（这是 standby 的替身：对账员，不是巡逻员） |
| health_monitor | 10min | 保留；**新增**：学习通会话从 alive→dead 沿，立即推送"⚠️ 学习通已掉线，点开重新扫码"（带 URL），每 12h 重复直至恢复 |
| memory_sweep | 1h | 保留但行为改归档（§1.2） |
| 早晚简报 | 7:30/22:00 | 保留 |
| **distill（新）** | 每日 02:30 | §5 |
| ~~standby_agent~~ | — | **删除 job**；tasks/standby_agent.py 整文件删除，main/scheduler 摘引用 |

### 4.3 静默时段
settings 键 `quiet_hours`（默认 "23:30-07:00"）。发送器对 urgency<high 的到点通知顺延到静默期结束；deadline_1h 这类不顺延。

---

## 5. 夜间蒸馏（新文件 app/tasks/distill.py，每日一次 LLM）

输入（一次调用打包）：当日 archived/superseded items、当日 notification_feedback、当日 drop_log 随机抽样 ≤10 条、现有筛查卡。
输出（固定 JSON）：
1. `entity_updates`: [{entity_id, notes}] —— 重写实体卡片 notes（合并旧 notes，≤500字）
2. `new_facts`: [{entity, text, is_filter_rule}] —— is_filter_rule=true 的进筛查卡判例区
3. `screening_card`: 完整新卡文本（按 §2.2 固定格式；课程/watch 区由**代码**从表里生成拼接，LLM 只产判例区 —— 防止它幻觉出不存在的课）
4. `misdrop_alert`: drop 抽样里疑似误杀的 → 推一条低优先级通知给用户复核
执行器逐条校验 entity_id 存在性后写库，更新 settings.screening_card。失败不影响主流程，次日重试。

---

## 6. Dashboard 与交互

### 6.1 新端点 `GET /api/dashboard/today`（routers/schedule.py 或新 router）
```json
{"plan":[...], "upcoming":[...], "generated_at": "..."}
```
- **plan（今日）**，纯 SQL：今天的课（server_courses）+ 今天 due 的 active items + 今天的 server_events + 今天到点的已排提醒去重后的事项。按时间排序。
- **upcoming（未来14天重要事件）**：active items where due in (明天, +14d) and (importance high 或 kind in assignment/exam/signup) + 未来 events。
- **去重规则（硬性）**：两个列表共用 `dedupe_key = item_id（无 item 的课/event 用 kind+title+date）`；**今日优先** —— 出现在 plan 的 key 一律从 upcoming 排除。接口层做，不靠前端。
- 每条带：title, time, kind, entity_name, source, item_id（前端可跳详情/标记完成）。
- 不调 LLM。dashboard_briefing.py 的文案功能保留为 plan 顶部一句话（可缓存当天首次生成）。

### 6.2 前端（components/hub）
首页改为两区块：「今日安排」（plan，时间轴样式）+「即将到来」（upcoming，按天分组，DDL 倒计时高亮 ≤3 天）。原 hub 中与此重复的旧区块移除，**学习通登录态/钉钉状态卡片保留**。每条 item 提供两个轻操作：✅ 已完成（→ status='done'，撤销其阶梯）、🔕 别再提醒（→ 撤销阶梯但保留条目）。

### 6.3 通知交互（PWA SW）
推送 payload 增加 actions：`[完成✅] [知道了]`，及 conflict 类的 `[选A] [选B]`。SW 把点击回传 `POST /api/notifications/feedback`；"完成" 同 6.2 的完成语义；conflict 的选择回调到 `POST /api/items/{id}/resolve_conflict`。这是反馈回路的数据源，必须实现。
**⚠️ iOS 不渲染 web push 的 action 按钮**（主力客户端是 iOS PWA）：payload 必须同时带 `data.deep_link`（如 `/confirm?item=xx`），iOS 上点通知 → SW notificationclick 打开确认页一键裁决；Android/桌面才用 actions。两条路径都打同一个 feedback 端点。

### 6.5 PWA 增强（iOS 16.4+ 实测支持的才做）
1. **App Badge**：SW 收到 push 时 `setAppBadge(payload.badge_count)`（后端在 payload 里带"当前未处理重要事项数"，纯 SQL 算）；前端打开/标记完成时 `clearAppBadge` 或更新。
2. **离线 shell + 数据缓存**：SW 预缓存构建产物（Vite manifest 注入版本号做 cache key），`/api/dashboard/today` 等只读接口 stale-while-revalidate；dashboard 数据落 IndexedDB，离线时展示并标注"缓存于 X 分钟前"。
3. **订阅保活（防静默漏推，必做）**：SW 监听 `pushsubscriptionchange` 自动重订阅并上报新 endpoint；前端每次启动校验 `pushManager.getSubscription()` 与后端记录一致；push_service 对同一 endpoint 连续失败≥3 次 → health_monitor 告警（提示去 app 里重新订阅）。
4. manifest 补全：`id`、maskable 图标、apple-touch-icon 与启动屏 meta。
5. **禁止依赖** Background Sync / Periodic Sync / manifest shortcuts / Share Target —— iOS 均不支持，相关需求一律走服务端推送解决。

### 6.4 Agent 页：全权系统 agent（合并现有 chat/schedule 双入口）

**定位**：对话 agent 拥有对整个系统的**完整 access** —— 数据库、通知推送、scheduled 队列、items/entities/facts、watches、课表、设置、定时任务，无禁区。同时必须省 token。

**省 token 的关键决策：用少量"宽工具"取代现在的 31 个窄工具。** 工具定义本身每轮都进 prompt，是对话 token 的大头；宽工具把定义压到 10 个以内，能力反而是全集：

| 工具 | 说明 |
|---|---|
| `db_query(sql)` | 只读 SELECT，任意表。返回行数硬上限 50，超出提示加 LIMIT |
| `db_execute(sql)` | 写操作。**一律进待确认队列**（复用现有机制，改为按 conversation_id 隔离），UI 出确认按钮后才执行；含 DROP/ALTER 直接拒绝 |
| `get_schema(table?)` | 返回表结构+关键表说明。**schema 不进系统 prompt，按需懒加载** —— 这是省钱第二刀 |
| `queue_ops(action, ...)` | scheduled_notifications 的 list / cancel / create（走 dispatch 确定性 id 与 §4.1 source_id 规范） |
| `notify(title, body, urgency)` | 立即推送 |
| `kb_ops(action, ...)` | items/entities/facts/watches 的结构化 CRUD（写也过确认队列；比裸 SQL 安全，agent 优先用它） |
| `kb_search(query)` | FTS5 检索，返回紧凑行 |
| `run_job(name)` | 手动触发 ladder_audit / distill / dingtalk_sync / chaoxing_probe |
| `system_status()` | health detail + 今日 token 用量 + 队列摘要 |
| `fetch_url / search_web` | 保留现有两个（fetch_url 用 §7.3 修复后的版本） |

**实现要点**：
- 系统 prompt 固定且短（≤300 token，不含 schema、不含工具使用长篇教程），开头注入 §1 风格的预组装上下文包（今日 plan 摘要 + 命中实体卡），多数问题**一轮直答**，工具只在确实需要时用 —— 这是省钱第一刀。
- 现有 schedule_agent 的课表/提醒/日历专用工具（import_timetable、create_reminder 等）**映射为 kb_ops/db_execute 的内部实现复用**，对外工具面收敛；`_filter_schedule_tools` 关键词预筛机制删除（工具就 10 个，不需要预筛，还消除了"换个说法漏工具"的毛病）。
- 普通聊天页与日程页合并为一个 agent 入口（同一工具集、同一 prompt），前端保留两个 tab 也只是 UI 视图差异。
- **审计不变量**：db_execute/kb_ops 的每次实际执行写入新表 `agent_audit_log(id, conversation_id, sql_or_op, result_summary, created_at)`，dashboard 可查。agent 改了什么必须可追溯。
- 安全边界：宽权限的前提是 §7.1 的 ACCESS_TOKEN —— 只有你能对话，所以 agent 权限=你的权限；待确认队列防误操作而不是防恶意。

---

## 7. 安全与费用（公网 + API 计费，必须做）

1. **访问令牌**：`.env` 增加 `ACCESS_TOKEN`。FastAPI 全局中间件：除 `/health`、SW 必需的静态资源外，所有 `/api/*` 校验 `Authorization: Bearer` 或 `?token=`（PWA 首次输入后存 localStorage，前端 api 层统一带上）。比 nginx basic auth 好，因为 SW 的 push 回执也能带。
2. **providers 接口脱敏**：GET /api/providers 返回的 api_key 改为 `sk-***末4位`；PATCH 更新时空值表示不修改。前端对应适配。
3. **fetch_url SSRF 修复**：改白名单策略——解析 URL host，`socket.getaddrinfo` 后判定 IP：拒绝私网段、loopback、链路本地（含 **169.254.169.254**）、`[::1]`；仅允许 http/https 与 80/443。
4. **费用护栏**：复用 analytics 的 usage 记录，新增表 `llm_budget_log`（按天按调用点累计 tokens）；settings 键 `daily_token_budget`（默认 50万）。超限时：F2 回退纯关键词兜底（§2.2 兜底规则）、Reconciler 只处理 notify 级消息、蒸馏跳过 —— 并推一条"今日预算已用尽"。晚间简报文案附一行今日 token/估算费用。
5. debug router 维持 settings.debug 开关，且同样过 token 中间件。

---

## 8. 防幻觉/防漏的系统不变量（写进代码注释与测试）

1. **推送内容必须可溯源**：每条推送要么来自 DB 行（带 item_id/source_id），要么是简报/简讯类（有纯代码 fallback）。LLM 自由文本**永远不直接成为独立事实**进推送 —— push_now 的 ref_item 校验存在性。
2. **id 白名单**：Reconciler 只能操作上下文包里给过的 id（§3.3 校验器）。
3. **失败必须显形**：任何 LLM 调用失败走"宁多勿漏"兜底并计数；连续失败 ≥3 次推告警（health_monitor 已有 API 连败机制，接入新调用点）。
4. **去重单一权威**：dedupe 只发生在 keys.py 规范键 + MemoryRepository 两层去重 + dashboard 接口层；任何新代码不得自造去重逻辑。
5. **删除禁令**：业务数据只归档不物理删（除 scheduled_notifications 未发行的撤销、drop_log 的 cap 裁剪）。
6. **时间统一**：所有新代码写库一律 aware UTC ISO，展示层转 Asia/Shanghai。禁止 `datetime.utcnow()`。

---

## 9. 实施顺序（每阶段独立可部署、可回滚；遵守 CODEBASE.md 部署规则：py_compile→scp→docker cp→restart，禁止 rebuild）

**阶段1 — 止血与队列化（先做）**
1. sweep 改归档 + items 加列（§1.2）
2. ladder.py + 入库即排阶梯 + 撤销级联函数（§4.1）
3. ladder_audit job + 删 standby job（standby 文件此阶段先保留不调用）
4. 学习通掉线推送（§4.2）
5. deadline_check 移除 memory_high 段
验收：人为改一个作业 due → 队列中旧阶梯消失、新阶梯出现；停后端 1h 重启 → audit 补齐；学习通登出 → 收到掉线推送；全天无 standby LLM 调用记录。

**阶段2 — 知识库**
entities/facts/kb_fts 建表回填（§1.1/1.3/1.4）、course 实体初始化、Reconciler 替换 engine 调用点（§3）、watches 对话入口（日程 agent 加 create_watch/list_watches/delete_watch 三工具）。
验收：发一条"张老师这周的课不上了"测试消息 → 对应三个课表实例标记取消、阶梯撤销、收到一条取消通知；update/cancel 操作的 id 100% 来自上下文包（日志审计）。

**阶段3 — 过滤与蒸馏**
F2 重写（筛查卡+light模型+固定编码+兜底改向）、distill job、notification_feedback 端点 + SW actions、筛查卡判例回路。
验收：连续两天观察 — 筛查卡字节级日内不变；故意 dismiss 同类通知两次 → 次日判例区出现对应规则；LLM 故障注入 → 含 ddl 关键词消息仍入库为 notify。

**阶段2.5 — 全权 agent（§6.4）**
宽工具集实现、待确认队列改 per-conversation、agent_audit_log、双入口合并、删除工具关键词预筛。
验收：问"我下周有什么安排"一轮直答（无工具调用，靠预装上下文包）；"把数据库里XX删掉"→ 出确认按钮且未确认前数据不变；audit_log 记录每次写操作；单轮对话工具定义总 token ≤1500。

**阶段4 — Dashboard + PWA + 安全 + 清理**
/api/dashboard/today + 前端 hub 改版（§6.1/6.2）、PWA 增强（§6.5：badge、离线缓存、订阅保活、manifest；§6.3 的 iOS 深链路径）、token 中间件 + providers 脱敏 + SSRF 修复 + 预算护栏（§7）、删除 engine.py 旧机制/standby_agent.py/memory_agent.py/memory_reducer.py/web/、schedule_agent.py 按 工具定义/执行/上下文 拆为 ≤500 行的三个模块（纯移动不改逻辑）。
验收：无 token 的请求 4 路全拒；GET providers 无完整 key；plan 与 upcoming 无重复 key；iOS 真机：图标角标随未处理数变化、飞行模式下能打开并看到缓存 dashboard、点通知深链到确认页；`grep -r "process_message\|standby_agent"` 无残留引用。

**阶段5 — 分享入口 + 性能（阶段4 验收后做）**

*5a. iOS 分享入口（替代 Share Target，iOS PWA 不支持该 API）*
1. 新端点 `POST /api/inbox {text, url?, note?}`（过 token 中间件）：内容包装成 NormalisedMessage（source_type='inbox'，conversation_title='手动转发'），**直接走 Reconciler 管线**（跳过 F0-F2 过滤 —— 用户亲手转发的默认值得入库）。
2. 写一个 iOS 快捷指令模板（分享表单 → POST /api/inbox，Header 带 token），导出 .shortcut 链接放进 README 和设置页说明。
3. Android/桌面顺手加 manifest `share_target`（指向同一端点的前端确认页），几行配置。
4. 前端剪贴板辅助（可选，最后做）：app 获得焦点且剪贴板有新文本时，顶部出现"转发给 agent？"条。

*5b. 性能（只做以下五项，其余微优化明令不做）*
1. SQLite：`PRAGMA journal_mode=WAL`（database.py 连接初始化处）+ 补索引：`chaoxing_memory_entries(status, expires_at)`、`scheduled_notifications(sent_at, trigger_at)`、`messages(conversation_id, position)`。
2. nginx（frontend 容器配置）：静态资源 `Cache-Control: max-age=31536000, immutable`（Vite 产物带 hash，安全）+ gzip on；index.html 和 sw.js 设 no-cache。
3. 路由级代码分割：设置页、analytics、notifications 历史页改 `React.lazy` + Suspense。
4. SSE 渲染节流：流式 text 事件累积 50ms 批量 flush 到 state（chat 组件层，不动后端）。
5. dashboard 缓存先行：复用 §6.5.2 的 IndexedDB，打开先渲染缓存 + 角落"缓存于X分钟前"，后台刷新替换。

验收：iOS 分享表单一次操作后，inbox 内容出现在 items 且（含时间的）生成了阶梯；Lighthouse PWA 跑分前后对比留档；冷启动到 dashboard 可见 <1s（缓存路径）；docker stats 确认 WAL 后 backend 内存无显著上涨。

---

## 10. 测试要求

backend 新增 `tests/`（pytest + aiosqlite 内存库）。最低覆盖：keys 规范键字节一致性（拿现网真实键样本回归）、ladder 生成与撤销级联、Reconciler 校验器拒绝幻觉 id、dashboard 去重、F2 兜底分类、sweep 归档不删数据、token 中间件、agent 待确认队列隔离与 db_execute 守卫。CI（.github/workflows/build.yml）加 pytest 步骤。

---

## 11. 后续 Debug 环节（每阶段部署后执行，用云端现有 API 跑真链路）

原则：**单元测试在本地跑，集成/端到端 debug 一律打真环境** —— 阿里云上的现网后端 + 已配置的真实 LLM provider（custom_providers 表里现有的），不搭本地 mock LLM。部署遵守 CODEBASE.md 规则（py_compile→scp→docker cp→restart，禁 rebuild）。

**11.1 通用流程（每阶段验收时走一遍）**
1. 部署前：`ssh aliyun-root "sqlite3 /opt/chatbot/...db '.backup /tmp/pre_deploy.db'"` 备份；记录当前 scheduled_notifications / active items 计数作为基线。
2. 部署后冒烟：`curl /health`、`/api/health/detail`、`/api/dashboard/today`（阶段4起带 token）；`docker logs chatbot-backend-1 --since 5m` 无 traceback。
3. **注入式端到端**：用 debug 端点投递构造消息走真实管线（真 LLM 调用），新增 `POST /api/debug/inject_message {source, text, conversation_title}`（仅 settings.debug 开启时存在），用例集：
   - "数据结构作业截止周五23:59" → 期望：item 入库挂对实体 + 阶梯3档入队
   - "上条作业延期到下周一" → 旧阶梯撤销、新阶梯入队、收到变更推送
   - "张老师这周的课不上了" → 本周该课实例取消、阶梯撤销
   - 互相矛盾的两条 → 收到 conflict 确认推送，点选后数据正确
   - 纯水群消息 ×5 → 全部进 drop_log，零 LLM 主模型调用（看 llm_budget_log 调用点计数）
4. 验证渠道：`/api/debug/drops`、queue_ops list、真机收推送（PWA）、`agent_audit_log`、token analytics 当日曲线。
5. 回滚预案：docker cp 回旧 .py + restart + `.backup` 还原（仅 schema 加列类迁移可不还原库）。

**11.2 费用监控即 debug 工具**
每阶段上线后观察 48h 的 llm_budget_log 按调用点分布，异常判据：F2 日调用数 > 钉钉 needs_llm 消息数的 1.1 倍（说明重复分类）；Reconciler 平均轮数 >1.3（说明 need_more 滥用）；出现 standby/engine 旧调用点（说明摘除不净）。任一触发 → 修复后再进下一阶段。

**11.3 全权 agent 的 debug 用法**
阶段2.5 之后，agent 本身就是 debug 终端：直接在对话里 `system_status()`、`db_query` 查队列、`run_job("ladder_audit")` 复现问题，替代大部分 ssh 排查。文档化三条常用排查口令进 README（"查今天为什么没推XX"、"看队列里XX的阶梯"、"昨晚蒸馏改了什么"）。
