# 刷新逻辑 & 信息处理架构 重设计方案

> 目标：把"写死的阶梯/关键词字典/全量重扫"换成**信号驱动**的弹性结构。
> 原则：小步、可回滚、不破坏现有去重和通知链路。每阶段都能独立上线。

---

## 一、现状的死板点（定位）

| # | 问题 | 位置 | 表现 |
|---|------|------|------|
| R1 | 轮询频率写死成阶梯 | `chaoxing_service._next_interval` | 只看 `consecutive_no_change`，无视时间段；凌晨空转猛刷 |
| R2 | 加速触发只认作业截止 | `chaoxing_service._in_important_window` | 老师紧急通知、钉钉活跃、考试/会议临近都不加速 |
| R3 | 只能全量重扫 | `refresh_message_memory` / `trigger_memory_scan` | 每次重处理所有会话，成本+延迟大 |
| R4 | 手动刷新太粗 | schedule_agent 工具 | agent 不能选"刷什么"，只能一把全刷 |
| A1 | 上下文注入 bug | `build_turn_context` → `query_for_agent(user_message="")` | tier2 关键词上下文(Layer B)**永远被跳过** |
| A2 | 编排器纯关键词 | `orchestrator_plan` / `_filter_schedule_tools` | 固定字典，无同义词/上下文推理 |
| A3 | 管线僵硬 | `run_chaoxing_probe_adaptive` | probe→sync→LLM→通知→briefing 一条直线，无优先级/事件驱动 |

---

## 二、目标架构：信号驱动的刷新

引入一个轻量 **SyncSignals** 概念：每次 probe 收集"信号"，由一个纯函数算出下次间隔，取代写死阶梯。

```
signals = {
  changed_conversations: int,      # 本轮变化的会话数
  consecutive_no_change: int,      # 连续无变化次数
  now_local: datetime,             # 用于时间段判断
  imminent_deadline_min: int|None, # 最近作业/考试截止还剩几分钟
  urgent_keyword_hit: bool,        # 新消息命中紧急词(紧急/截止/今晚/马上)
  dingtalk_active: bool,           # 钉钉 WAL 近 N 分钟有新消息
  user_active_min: int|None,       # 用户上次交互距今几分钟
}
next_interval = compute_interval(signals)
```

`compute_interval` 取代 `_next_interval` + `_in_important_window` + `_next_interval_from_activity`，集中决策：

- **夜间衰减**：`23:00–07:00` 且无 imminent_deadline → 下限抬到 600s（不再凌晨猛刷）。
- **多源加速**：imminent_deadline<60min / urgent_keyword_hit / dingtalk_active 任一命中 → 45s。
- **活跃跟随**：changed_conversations>0 或 user_active<10min → 60–120s。
- **空闲退避**：consecutive_no_change 越大越慢，但保留现有上限。

> 全是纯函数，便于写单测，参数(阈值)走 settings 表可调，不再硬编码在分支里。

---

## 三、增量 / 定向刷新（R3、R4）

把"刷新"拆成范围参数，而非全量：

```
refresh_message_memory(scope="changed"|"all"|"conversation", conversation_id=?)
```

- `scope="changed"`（默认）：只处理 probe 标记为变化的会话（复用 `_filter_changed_probes` 的结果）。
- `scope="conversation"`：用户/agent 指定某个群或私聊。
- `scope="all"`：保留旧行为，显式才走。

agent 工具描述里说明三种 scope，让模型按用户意图选。trigger_memory_scan 同理加 scope。

---

## 四、上下文注入修复（A1，**最低风险、先做**）

`build_turn_context` 增加 `user_message` 参数并透传给 `query_for_agent`，Layer B 立即生效：

```python
turn_context = await build_turn_context(db_path, chaoxing_svc, now, user_message=user_message)
...
mem_entries = await repo.query_for_agent(now, user_message=user_message, max_tier=2, limit=8)
```

零结构改动，单测可验证 Layer B 命中。

---

## 五、关键词 → 意图推理（A2）

分两步走，先不上 LLM：

1. **同义词归一 + 评分**：把 `orchestrator_plan` / `_filter_schedule_tools` 的关键词字典抽到一个 `intent.py`，做同义词归并 + 模糊评分（而非命中即全有），低分时再 fallback。
2. （可选）**LLM 路由**：用一次小模型分类（已有 standby 用的 mimo）输出 sub_agents + 工具子集，命中缓存避免每轮调用。先做 1，验证收益再决定 2。

---

## 六、管线再设计（A3，最大改动、最后做）

把 `run_chaoxing_probe_adaptive` 里直线串联的 5 段，改成**事件 + 优先级队列**：

- probe 产出 `ChangeEvent`（哪个会话/作业变了）。
- 处理器订阅事件：memory_sync / LLM 抽取 / 通知 / briefing 各自声明触发条件（数据变化才跑），避免无变化时空跑 LLM。
- briefing/通知按优先级出队，受 quiet_until、内存预算约束。

> 这步收益最大但风险也最大，建议前 4 步落地、观察线上后再动。

---

## 七、建议实施顺序

| 阶段 | 内容 | 风险 | 收益 | 状态 |
|------|------|------|------|------|
| **P0** | A1 上下文注入修复 | 极低 | 动态信息立即进 agent | ✅ 已上线+验证 |
| **P1** | R1+R2 `compute_sync_interval` 信号驱动 | 低 | 夜间不空转、多源加速 | ✅ 已上线+验证 |
| **P2** | R3+R4 增量/定向刷新 | 中 | 降成本降延迟 | ✅ 已上线 |
| **P3** | A2 意图归一(非LLM) | 中 | 路由更准 | ⬜ 待做 |
| **P4** | A3 管线事件化 | 高 | 架构弹性 | ⬜ 待做 |

### P0 实现（已上线）
`build_turn_context(..., user_message=user_message)` 透传，`query_for_agent` 收到真实消息，
Layer B(tier2 关键词上下文)生效。线上实测：空消息只注入 1 条 tier1，
带"作业/截止/大创/提交"时额外浮现 3 条 tier2 命中条目。

### P1 实现（已上线）
- 新增纯函数 `compute_sync_interval(changed, consecutive_no_change, now_local,
  imminent_deadline_min, dingtalk_active, urgent_recent_memory)`，取代
  `_next_interval` + `_in_important_window` + `_next_interval_from_activity`。
- 决策优先级：硬加速(截止≤60min / 15min 内新增 high 记忆 → 45s) > 夜间退避
  (23:00–07:00 无近截止 → 900s) > 活跃跟随(有变化 45–90s / 钉钉活跃 60–120s) >
  空闲退避阶梯。
- 辅助：`_min_minutes_to_due`、`_dingtalk_active`(WAL 10min 内有写)、
  `_has_urgent_recent_memory`。
- `chaoxing_sync.py` 外层 cap 由 `chaoxing_sync_interval`(300) 放宽到硬上界 900，
  否则夜间退避会被砍回 5 分钟。
- 旧的 `_next_interval` / `_in_important_window` / `_next_interval_from_activity`
  已无调用方（dead code），保留未删，可在后续清理时移除。

### P2 实现（已上线）
- `run_memory_agent` 新增 `scope`(all/changed/conversation) + `conversation_ids`，
  由新辅助函数 `_fetch_for_scope` 收窄 *抓取* 范围（LLM 抽取不变）：
  - `changed`(默认)：先 probe，只抓签名变化的会话，并持久化签名。
  - `conversation`：只抓指定会话。
  - `all`：旧的全量 12×20。
- `refresh_message_memory` 工具暴露 scope/conversation_id，默认 changed。
- 修复 `trigger_memory_scan` 的 latent bug：原先 `run_memory_sweep(db_path)`
  传错函数+错参类型(期望 app_state)，后台任务静默 AttributeError，从不扫描。
  现改为后台跑 `run_memory_agent(scope="changed")`，是真正的增量扫描。

---

## 八、部署注意（来自 CLAUDE.md）

- 改 Python：`py_compile` → `scp` → `docker cp` → 服务器 `py_compile` → `docker restart`。
- **禁止** `docker build` / `compose up --build`。
- push 前 `git diff --stat`，确认没有未编辑文件被 rsync 漂移成旧版。
