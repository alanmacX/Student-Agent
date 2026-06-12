# 调试 / 云端运维 / 打磨 实施手册 (给 Codex)

> 接手人:Codex。任务分三层,**按顺序**做:① 所有功能能跑通 → ② 功能逻辑正确(推送/过滤/时间/去重)→ ③ UI(移动端+桌面端)优化与通用易用性。
> 本文是**操作手册 + 审计清单**。架构设计见同目录 [REDESIGN_IMPLEMENTATION.md](REDESIGN_IMPLEMENTATION.md)(权威设计),本文只讲"怎么调、怎么部署、怎么保证三端一致、查什么"。
> 当前三端 HEAD:`8dc26a0`(开始前先 `git rev-parse HEAD` 三端核对,见 §2)。

---

## 0. 关键事实(先背下来,踩过的坑)

| 项 | 值 |
|---|---|
| 仓库 | github.com/alanmacX/Student-Agent,默认分支 `main`,**trunk-based**(不开 PR 分支) |
| 本地权威源 | `server-src/`(`web/` 是废弃旧副本,禁用) |
| 云端 | `ssh aliyun-root:/opt/chatbot/server-src/`,源站阿里云杭州 `121.43.54.204` |
| 容器 | `server-src-backend-1`(FastAPI,uvicorn `app.main:app`,代码在容器内 `/app/app/...`,**非挂载,docker cp 进去**)、`server-src-frontend-1`(nginx,网页根 `/usr/share/nginx/html`)、`server-src-nginx-1`(反代) |
| 公网访问 | **必须走 Cloudflare Tunnel**。`hajiqu.xyz` apex 已在隧道 `writeclaw`(systemd `cloudflared`,`/etc/cloudflared/config.yml`)。源站 80/443 被阿里云 ICP 按 Host 拦截——**任何 DNS 都不能直指源站 IP**。详见 [access-networking 记忆] |
| 访问令牌 | 全 `/api/*` 走 `ACCESS_TOKEN`(在 `.env`)。请求带 `Authorization: Bearer <token>` 或 `?token=<token>`。**公开豁免**:`/health`、`/api/push/{received,clicked,dismissed}`、`/api/push/vapid-public-key`、`/api/notifications/feedback`(见 `main.py PUBLIC_API_PATHS`)。当前令牌问用户取(聊天里出现过,建议先轮换,见 §6.4) |
| LLM | 小米 MiMo(`xiaomimimo` custom provider),`.env` 的 `MIMO_API_KEY` |
| **云端连不上 GitHub** | aliyun → github 443 超时。云端 git **不能 `git pull`**,只能用 **bundle over SSH**(§2.3) |

容器内 env:pydantic 读 `/app/.env`(进程启动时)。改 env 要写 `/app/.env` **且** 宿主 `/opt/chatbot/server-src/.env`,然后 `docker restart`。**禁止 `docker compose up`/recreate**(会丢所有 docker cp 的代码)。

---

## 1. 系统组成(审计时对照)

**入站消息流**:钉钉桌面客户端(宿主 Xvfb)+ 学习通(cookie 会话)→ 过滤 → Reconciler(语义)→ knowledge(entities/facts/items)+ 通知队列。
**Routers**(`app/routers/`):`conversations chat schedule chaoxing providers settings push reminders data analytics dashboard agent_quick ideas zjut`(+`debug` 仅 `DEBUG=true`)。
**定时任务**(`scheduler.py`,进程内 APScheduler):`chaoxing_probe daily_begin daily_summary_evening deadline_check dingtalk_memory dingtalk_sync distill distill_bootstrap health_monitor ladder_audit memory_sweep scheduled_notifications`。
**前端**(`frontend/src/`):React+Vite PWA。Tab:总览(ScheduleOverview)、Agent(ScheduleView,聊天)、Hub(HubView,今日plan/即将/长期/点子库)、通知、设置。SW:`public/sw.js`(push + 离线缓存,**HTML network-first**)。
**ZJUT 教务**:`services/zjut.py`(登录/RSA/抓取/解析)+ `services/zjut_import.py`(展开进 `server_courses`、考试进 `server_events`、AES-GCM 存凭据)+ `routers/zjut.py`(probe/import/refresh/status,**已改为只需学号密码,学年/学期/开学周自动检测**)。

---

## 2. 三端一致(铁律,每个改动都走)

**三端 = 本地 `server-src/` ↔ GitHub `main` ↔ 云端 `/opt/chatbot/server-src/`。内容必须逐字节一致,git HEAD 必须同一个 commit。**

### 2.1 改动前
```bash
# 本地确认干净、与 origin 对齐
git -C ~/Documents/chatbot status --short
git -C ~/Documents/chatbot rev-parse --short HEAD
git ls-remote origin HEAD | cut -c1-7
ssh aliyun-root 'cd /opt/chatbot && git rev-parse --short HEAD'   # 三者必须相同
```
不相同 → 先按 §2.4 收敛,再动手。

### 2.2 部署(改完代码)
**后端 .py**:
```bash
python3 -m py_compile server-src/backend/app/<file>           # 本地编译
scp -q server-src/backend/app/<file> aliyun-root:/opt/chatbot/server-src/backend/app/<file>
ssh aliyun-root "docker cp /opt/chatbot/server-src/backend/app/<file> server-src-backend-1:/app/app/<file> && \
  docker exec server-src-backend-1 python -m py_compile /app/app/<file> && \
  docker restart server-src-backend-1"
sleep 5 && ssh aliyun-root "curl -s http://localhost/health"    # 确认起来
```
**前端**:
```bash
cd server-src/frontend && npm run build
cd dist && tar czf /tmp/dist.tar.gz . && scp -q /tmp/dist.tar.gz aliyun-root:/tmp/dist.tar.gz
ssh aliyun-root "docker exec server-src-frontend-1 sh -c 'rm -rf /usr/share/nginx/html/assets' && \
  docker cp /tmp/dist.tar.gz server-src-frontend-1:/tmp/dist.tar.gz && \
  docker exec server-src-frontend-1 sh -c 'cd /usr/share/nginx/html && tar xzf /tmp/dist.tar.gz && rm /tmp/dist.tar.gz'"
# 核对线上 bundle hash == 本地 dist
```
**.env / schema**:schema 迁移只走 `database.py::run_migrations`(重启自动跑,幂等)。**禁止手工 ssh 改线上 schema**。

### 2.3 提交并同步 git(每个可验收单元)
```bash
git add <files> && git commit   # 信息写清;结尾 Co-Authored-By
git push origin main            # 本地→GitHub OK
# 云端拿不到 GitHub,用 bundle over SSH:
git bundle create /tmp/sync.bundle main
scp -q /tmp/sync.bundle aliyun-root:/tmp/sync.bundle
ssh aliyun-root "cd /opt/chatbot && git fetch /tmp/sync.bundle main && git reset --hard <commit> && rm -f /tmp/sync.bundle"
# 三端 rev-parse 再核对一次,必须同一个 commit
```
> 注意:`git reset --hard` 只动云端 git 元数据;**容器里跑的代码是 docker cp 进去的**,reset 不影响运行时(内容已一致),所以零运行时风险。但顺序必须是**先 push+部署、后 reset**,否则会把刚部署的代码在宿主源里回退。

### 2.4 漂移收敛(发现三端不一致)
1. 用 `rsync -az --exclude=node_modules --exclude=dist --exclude=__pycache__ --exclude=.git --exclude='*.db' aliyun-root:/opt/chatbot/server-src/ /tmp/cloud_snap/` 拉云端快照。
2. `diff -rq /tmp/cloud_snap server-src`(排除 .git/pycache)判断谁是真。**云端运行时是用户在用的版本,通常云端为准**。
3. 内容一致仅 git 漂移 → 直接 §2.3 的 bundle reset 对齐。内容不一致 → 先 rsync 云端→本地,审 `git diff --stat`(防异常大删除,有则 `git checkout HEAD -- <file>` 还原),commit,再 push + bundle。

### 2.5 验收锚点
每完成一阶段打 tag:`git tag polish-p1 && git push origin polish-p1`(并 bundle 同步 tag 到云端)。

---

## 3. 第①层:功能跑通(冒烟测试清单)

逐项 curl(带 `?token=`)+ 真机点。**任一红 → 修到绿再继续。**

```bash
T=<ACCESS_TOKEN>; H="https://hajiqu.xyz"
curl -s $H/health                                   # {"status":"ok",...}
curl -s "$H/api/dashboard/today?token=$T" | jq '{plan:(.plan|length),upcoming:(.upcoming|length),longterm:(.longterm|length)}'
curl -s "$H/api/ideas?token=$T"                     # 点子库
curl -s "$H/api/zjut/status?token=$T"               # 教务配置
curl -s "$H/api/schedule/sessions?token=$T"         # 聊天会话列表
curl -s -X POST "$H/api/agent/ask?token=$T" -H 'Content-Type: application/json' -d '{"text":"今天有什么课","auto_confirm":false}'  # Siri/agent
curl -s "$H/api/providers?token=$T" | jq '.custom[0].api_key'   # 应脱敏(不是完整 key)
curl -s -o /dev/null -w '%{http_code}' "$H/api/ideas"           # 无 token 应 401
```
**真机/浏览器**:① 网页能开(SW network-first,先硬刷)② Agent 聊天能流式回复(SSE 带 token,见教训)③ 待确认操作出按钮 ④ Hub 四个区块都渲染 ⑤ 推送能收到(设置页订阅)。

**后端日志**:`ssh aliyun-root "docker logs server-src-backend-1 --since 20m 2>&1 | grep -iE 'error|traceback|exception'"` 应为空。

**调试接口**(开 `DEBUG=true` 后):`/api/debug/drops`(被过滤消息)、`/api/zjut/probe`(教务登录预览)。

---

## 4. 第②层:逻辑正确(审计 + 已知坑)

### 4.1 过滤逻辑(钉钉/学习通)
- 钉钉三段:`dingtalk/filters.py`(F0/F1 代码)→ `dingtalk/classifier.py`(F2 light-LLM,persona 在 `DINGTALK_PERSONA`)。审:误杀(去 `message_drop_log` 抽样)、漏报(LLM 失败兜底方向——含 ddl/作业/考试关键词应偏 notify 不偏 interest)。
- **作业状态双词表坑(本周修过,务必全局核一遍)**:存在两套状态值——`未交/已完成/待批阅`(JSON) 与 `未提交/已提交/已截止`(HTML `_status_label`)。**"待办"只认 `{未交, 未提交}`,其余(尤其"待批阅"=已提交待批)都算交了**。`memory_sync.py::PENDING_STATUSES` 是权威。已修:`dashboard.py`、`notification_sender.py`(deadline+早晚简报)、`schedule_agent.py`(_get_assignments/上下文)。**审计**:grep 全仓 `fetch_all_pending_assignments` 每个调用点是否都过滤了状态;新代码不得再用 `NOT IN ('已交','已完成')` 这种漏"待批阅"的写法。

### 4.2 推送逻辑
- 链路:`scheduler` → `notification_sender`/`dispatch` → `push_service.send_push_to_all_subscribers`(VAPID)→ SW 显示 + 回执(`/api/push/received|clicked|dismissed`)→ `notification_log`。
- 去重不变量(见 REDESIGN §8):`has_notified(item_id, notif_type)` 按渠道命名空间;跨渠道用 `push_service.entity_recently_notified`。审:同一条目会不会被 deadline / memory_high / daily 多渠道重复推(一天 ≤ 合理次数)。
- 阶梯:`services/ladder.py` 入库即生成 T-3/T-1/当天写 `scheduled_notifications`,`source_id={item_id}:{档位}`;撤销级联按前缀 `DELETE ... WHERE sent_at IS NULL`。审:作业改期/取消时旧阶梯有没有被撤、新阶梯有没有重排;`ladder_audit` 每小时补漏。
- 静默时段、VAPID 配置(`.env` 的 `VAPID_*` 必须有,缺了静默不发)。
- **审计**:订阅保活——SW `pushsubscriptionchange` 是否重订阅;`push_service` 对连续失败 endpoint 是否告警。

### 4.3 时间观念(本周起重点,容易出 bug)
- **统一 UTC 存储**:`server_courses/server_events/server_reminders` 的 `start_at/due_at` 必须是 UTC ISO。dashboard 用 UTC 日界做比较。**坑**:任何写库的新代码若存 `+08:00` 字符串,会和 UTC 边界做**字典序比较**而错位(本周 ZJUT 导入就踩了,已改 `zjut_import._dt` → `.astimezone(utc)`)。**审计**:grep 写 `start_at/end_at/due_at/expires_at` 的地方,确认都是 UTC;`datetime.utcnow()`(naive)与 aware 混用要清掉。
- **过期/已完成不该再出现**:已交作业(§4.1)、过期 memory(`expires_at < now` 应判 REFERENCE/排除)、`compute_tier` 对 `days_left<=0` 判 REFERENCE。
- **未完成的逾期项(待办)**:`server_reminders` 未完成但 `due_at` 已过的,dashboard plan 目前**无下界**会堆在"今天"且不标逾期。**待办 TODO**:接口给逾期项加 `overdue:true` + 逾期天数,前端单独"逾期"分组标红,与"今天"区分(用户已提需求)。

### 4.4 防幻觉不变量(REDESIGN §8)
- Reconciler/agent 只能操作上下文里给过的 id;声称"已创建/已保存"前必须真调用了工具并成功(`schedule_agent` 已加铁律 prompt)。审:聊天里 agent 有没有编造"已完成/已保存"而 DB 无对应行(本周改过 save_memory 幻觉)。

### 4.5 知识库 / 课程数据
- `chaoxing_courses` 仅当前学期(`fetch_courses` 按 beginDate/createtime 过滤);course 实体只从权威课程表生成(别从 memory 候选名造垃圾实体——本周修过)。
- `server_courses` 现由 ZJUT 导入填(`calendar_name='正方教务'`);"今日课程"读它。审:导入后 Hub「今日课程」是否正确显示当天的课(注意 UTC)。

---

## 5. 第③层:UI / 易用性(移动端 + 桌面端)

> 原则:移动端(PWA,iOS 为主)和桌面端分别过一遍。每改一处都真机/窄屏(~390px)和宽屏各看一次。

### 5.1 平台无关的易用性(先扫这些)
- **空状态/加载态/错误态**:每个列表(plan/upcoming/longterm/点子/会话/通知)在空、加载中、请求失败时都要有清楚反馈,别白屏或一直转。
- **401 处理**:任何接口 401 统一弹访问令牌框(SSE 路径本周才补上,核对其它 fetch 路径都走 `apiFetch`/带 token)。
- **时间显示**:统一本地时区展示 + 相对时间("还剩3天"/"逾期2天");逾期标红(配合 §4.3)。
- **操作反馈**:删除/完成/确认要有即时乐观更新 + 失败回滚(点子库已做,核对提醒/事件)。
- **长列表**:课程表一周可能几十节,确认滚动/性能 ok。
- **文案**:错误信息说人话(别暴露 `KeyError`/traceback 给用户)。

### 5.2 课程表网格视图(待建,REDESIGN §课程表)
按用户给的截图做:周一~周日列 × 1-12 节行,课程彩色块(课名+教室+老师),底部「第X周 / ‹ › / 刷新」。数据来自 `server_courses`(`calendar_name='正方教务'`),按 `start_at` 的本地周次/星期/节次反推落格。节次时间表见 `zjut_import.PERIOD_TIMES`(可配置,第5节午休)。**移动端**:横向可滚或压缩列宽;**桌面**:完整网格。

### 5.3 设置页「正方教务」面板(待建)
表单:学号 + 密码 + 「保存凭据」开关 + 「导入」按钮;显示上次导入时间 + 「立即刷新」(调 `/api/zjut/refresh`)。学年/学期/开学周**后端自动检测**,不让用户填。密码框 type=password,不回显。错误用 `{ok:false,error}` 友好展示。

### 5.4 移动端专项
- 安全区(刘海/圆角)、底部 tab 不被手势条遮挡、输入框聚焦不被键盘顶飞、下拉刷新别误触(本周 App.jsx 调过阈值)。
- PWA:角标(setAppBadge,未处理重要数)、离线打开看缓存 dashboard、`apple-touch-icon`/启动屏、manifest `id`。

### 5.5 桌面端专项
- 宽屏布局别拉成一条;Agent 页右侧栏已删(别复活);快捷键(⌘N 新会话等)可选恢复。

---

## 6. 杂项 / 运维注意

1. **内存紧**:backend 限 512m,宿主 1.8G。scheduler 在进程内,OOM 被 kill 后靠 `restart:unless-stopped` 拉起,但 docker cp 的代码在镜像外——**recreate 会全丢**,只能 restart。
2. **备份**:改 DB 相关前 `ssh aliyun-root "docker exec server-src-backend-1 sh -c 'cp /data/chatbot.db /data/pre_<desc>_\$(date +%s).db'"`(/data 里已有几个 pre_* 快照,~1MB each,留着)。
3. **回滚**:docker cp 回旧文件 + restart;git 用 tag 锚点。
4. **令牌轮换**:`openssl rand -hex 24` → 写 `/app/.env` 和宿主 `.env` 的 `ACCESS_TOKEN=` → `docker restart backend` → 网页重输 + Siri 快捷指令 URL 改 `?token=`。聊天里出现过的旧令牌建议先换。
5. **ZJUT 凭据**:AES-GCM,密钥 `.env` 的 `ZJUT_KEY`(base64 32B,不进库/备份/git)。密码不进日志。
6. **cloudflared**:改隧道路由改 `/etc/cloudflared/config.yml` 后 `systemctl restart cloudflared`;别再起第二个手动进程跑同一隧道(路由会飘)。

---

## 7. 建议执行顺序

1. **§2 三端核对** → 确保起点干净。
2. **§3 冒烟全过一遍** → 列出所有挂的功能,逐个修绿(每修一个走 §2 部署+同步+commit)。
3. **§4 逻辑审计** → 重点 4.1 状态过滤全局核、4.2 推送去重/阶梯、4.3 UTC 时间 + 逾期标记。
4. **§5 UI** → 先 5.1 通用易用性,再 5.2 课程表 + 5.3 教务面板,最后 5.4/5.5 移动/桌面专项。
5. 每阶段打 tag(§2.5)。

**每一步改完都问自己**:本地编译了吗?部署到容器了吗?三端 HEAD 一致吗?真机/双端看过吗?

---

# 附录:逐条任务展开(Codex 按编号执行,每条独立可验收)

> 每条格式:**目标 / 涉及文件 / 怎么测 / 期望 / 失败怎么查与修**。做完一条走 §2 部署+同步+commit,commit 信息带任务号(如 `B3`)。
> `T=<ACCESS_TOKEN>`、`H=https://hajiqu.xyz`。`jq` 没有就用 `python3 -c`。

## 附录 A — 冒烟(第①层,逐个修绿)

### A1. 全 API 存活 + 鉴权
- 测:对每个路由各打一条(见 §3 的 curl);再各打一条**不带 token**。
- 期望:带 token → 200/合理 JSON;不带 → 401(除 `PUBLIC_API_PATHS`)。
- 失败:`docker logs server-src-backend-1 --since 10m | grep -iE 'error|traceback'` 定位;路由没注册查 `main.py` 的 `include_router`。

### A2. Agent 聊天(SSE)
- 测:网页 Agent 页发一句;再 `curl -N -X POST "$H/api/schedule/.../chat?token=$T"` 看是否流式返回 `data:`。
- 期望:逐字流式;待确认操作出"确认/取消"按钮(`pending_confirmation` 事件 → `MessageBubble`)。
- 失败:401 看 `hooks/useSSEStream.js` 是否带 `Authorization`(本周修过);按钮不出看事件名 `onPendingConfirmation` 是否对得上(本周修过)。

### A3. Hub 四区块
- 测:网页 Hub;`curl "$H/api/dashboard/today?token=$T"`。
- 期望:今日plan / 即将 / 长期 / 点子库 / 最近执行都渲染;空数据有空状态文案,不白屏。
- 失败:看 `routers/dashboard.py` 查询;前端 `components/hub/HubView.jsx`。

### A4. 点子库 CRUD
- 测:`POST/GET/PATCH/DELETE $H/api/ideas`;网页 Hub 输入框增删。
- 期望:增删改即时反映;agent 能 `list_ideas` 读到。
- 失败:`routers/ideas.py`、`HubView.jsx` 的 `loadIdeas/addNote/deleteNote`。

### A5. ZJUT 教务面板
- 测:设置页「正方教务」(`components/settings/ZjutSettings.jsx`)输学号密码→导入;`curl "$H/api/zjut/status?token=$T"`。
- 期望:导入成功返回写入条数;status 显示学期标签 + 上次导入时间;Hub「今日课程」出现当天的课。
- 失败:`routers/zjut.py`、`services/zjut_import.py`;登录失败看 `services/zjut.py` 的 `_login`(CAS 表单/公钥);课不显示先查 §B5 时区。

### A6. 推送订阅 + 收推送
- 测:设置页 `PushSettings.jsx` 订阅;手动触发一条 `curl -X POST "$H/api/agent/ask?token=$T" -d '{"text":"提醒我5分钟后喝水"}'` 或等 deadline_check。
- 期望:真机收到通知;点击/划掉后 `notification_log` 有 clicked/dismissed 回执。
- 失败:`.env` 的 `VAPID_*` 必须有(缺了静默不发);`services/push_service.py`;SW `public/sw.js`。

## 附录 B — 逻辑审计(第②层)

### B1. 作业状态过滤(双词表,全局核)
- 目标:**只有 `{未交, 未提交}` 算待办**;`待批阅/已批阅/已提交/已完成/已交/已截止` 都算交了,不显示不提醒。
- 涉及:`memory_sync.py::PENDING_STATUSES`(权威)、`routers/dashboard.py`、`tasks/notification_sender.py`、`services/schedule_agent.py`。
- 测:`grep -rn "fetch_all_pending_assignments\|status NOT IN\|status IN" backend/app` —— 每个调用点确认都过滤了状态;线上 `curl "$H/api/dashboard/today?token=$T"` 看 assignment 项 `detail` 是否全是"未交"。
- 失败/修:出现 `NOT IN ('已交','已完成')` 这种(漏"待批阅")→ 改成 `IN ('未交','未提交')` 或 `_is_pending()`。新增显示作业的代码必须复用同一判断。

### B2. 推送去重(不重复轰炸)
- 目标:同一条目一天不被多渠道重复推。
- 涉及:`push_service.py::has_notified`(按 `item_id+notif_type` 分渠道命名空间)、`entity_recently_notified`(跨渠道,按 item_id 查 N 小时内)、`memory/dispatch.py::notify_now/schedule_push`(确定性 id)。
- 测:连续两次跑 `deadline_check` / `distill`,看 `notification_log` 同一 item_id 是否被多次写不同 notif_type;真机一天收几条同一作业的。
- 失败/修:多渠道捞同一条 → 在各渠道 context 里 `entity_recently_notified(item_id, 24)` 抑制,或排除 `notification_log` 已推的。`schedule_push` 必须用确定性 id(非随机 uuid),否则 `INSERT OR IGNORE` 去重失效。

### B3. 提醒阶梯 + 撤销级联
- 目标:item 入库即排 T-3/T-1/当天(`ladder.build_ladder`);改期/取消时旧阶梯撤、新阶梯重排。
- 涉及:`services/ladder.py`(`build_ladder/schedule_ladder_for_item/cancel_ladder_for_item`)、`scheduled_notifications` 表(`source_id={item_id}:{档位}`)、`tasks/ladder_audit.py`(每小时补漏)。
- 测:造一个 item 改 due → 查 `scheduled_notifications` 旧 source_id 行 `sent_at IS NULL` 是否被删、新行是否生成;停 backend 1h 重启看 `ladder_audit` 是否补齐。
- 失败/修:撤销用 `DELETE ... WHERE source_id LIKE '{item_id}%' AND sent_at IS NULL`;确认 reconciler 的 `update_item/cancel_item` 执行后调了 `cancel_ladder_for_item`。

### B4. Reconciler 不变量 + external_update(**含一个 TODO**)
- 目标:① LLM 只能操作上下文给过的 id(校验器拒幻觉 id);② push_now 的 ref 必须真实存在;③ **新增 `external_update` op**:消息语义识别到"教务/正方课表/考试已更新/调课"时,reconciler 输出该 op → 代码推一条"要刷新课表吗"通知(或在确认后调 `/api/zjut/refresh`)。**绝不定时刷新。**
- 涉及:`services/reconciler.py`(现有 op:new_item/update_item/cancel_item/cancel_course_rows/new_fact/push_now/conflict — **无 external_update,需加**)、`routers/zjut.py::refresh`。
- 测:给 `inject_message`(debug)投"老师说下周三的课调到周五,教务系统已更新"→ 期望产出 external_update → 收到刷新提示;投普通消息不触发。
- 失败/修:在 reconciler 输出 schema + 执行器里加 external_update 分支(参考 push_now/conflict 的写法);执行 = `notify_now` 一条带 deep_link 到刷新动作。

### B5. 时间一致性(UTC)
- 目标:所有 `start_at/end_at/due_at/expires_at` 存 **UTC ISO**;比较用 UTC;展示转本地。
- 测:`grep -rn "utcnow\|+08:00\|astimezone\|isoformat" backend/app | grep -iE 'start_at|end_at|due_at|expires'`;`sqlite3` 抽查 `server_courses/server_events` 的时间是否带 `+00:00`。
- 失败/修:写库存了 `+08:00` 字符串 → `.astimezone(timezone.utc)`(本周 `zjut_import._dt` 已修);naive `datetime.utcnow()` → `datetime.now(timezone.utc)`。

### B6. 逾期项标记(**TODO,用户已提**)
- 目标:未完成但已过期的 `server_reminders` 不混进"今天",接口给 `overdue:true` + 逾期天数,前端单独"逾期"分组标红。
- 涉及:`routers/dashboard.py`(plan 的 reminders 查询无下界)、`components/hub/HubView.jsx`。
- 测:造一条 due 在 3 天前未完成的提醒 → 期望出现在"逾期"组标"逾期3天",不在"今天"。

### B7. 防幻觉(口头 vs 真落库)
- 目标:agent 声称"已创建/已保存/已完成"前必须真调了工具且成功。
- 测:聊天让 agent "记住X" / "建个提醒",然后查 `user_memory`/`server_reminders` 是否真有行;agent 别在没调工具时说"已保存"。
- 失败/修:`schedule_agent.py` 的铁律 prompt(已加)+ 确认写操作走待确认队列。

### B8. 过滤误杀/漏报
- 测:`curl "$H/api/debug/drops?token=$T"`(需 `DEBUG=true`)抽样被丢消息,看有无该 notify 的被误杀;LLM 故障注入看含 ddl/作业/考试关键词的是否兜底为 notify(不是 interest)。
- 涉及:`dingtalk/filters.py`、`dingtalk/classifier.py`(persona=`DINGTALK_PERSONA`)。

## 附录 C — UI / 易用性(第③层,移动端 + 桌面端各过一遍)

> 每条:窄屏(~390px,真机或 DevTools iPhone)+ 宽屏各验收一次。

### C1. 全局态(每个列表/页面)
- 空态有文案、加载有骨架/转圈、错误有友好提示(不露 traceback/KeyError);401 统一弹令牌框。
- 涉及组件:`HubView/ScheduleView/NotificationCenter/ScheduleOverview` 及各 `settings/*`。

### C2. 课程表网格视图(**待建**,照用户截图)
- 周一~周日列 × 1-12 节行,课程彩色块(课名+教室+老师首字),跨节次合并;底部「第X周 ‹ › 刷新」。
- 数据:`server_courses` where `calendar_name='正方教务'`,按 `start_at`(转本地)算周次/星期/节次落格;节次时间 `zjut_import.PERIOD_TIMES`。
- 移动端:列宽压缩或横向滚;桌面:完整网格。放在总览或单独 tab。

### C3. 教务设置面板打磨(`ZjutSettings.jsx` 已存在)
- 密码 type=password 不回显;导入中 loading + 禁用按钮;成功/失败友好提示;显示上次导入时间 + 「立即刷新」;「保存凭据」开关有说明(加密存储)。

### C4. 时间显示统一
- 全站本地时区 + 相对时间("还剩3天"/"逾期2天"/"18:30");临期/逾期配色(≤1天红、≤3天橙)。

### C5. 操作反馈
- 删除/完成/确认乐观更新 + 失败回滚(点子库已做,推广到提醒/事件/通知)。

### C6. 移动端专项
- 安全区(刘海/底部手势条);输入聚焦不被键盘顶飞;下拉刷新阈值别误触(`App.jsx usePullToRefresh`);底部 TabBar 不被遮。
- PWA:`setAppBadge`(未处理重要数)、离线开能看缓存 dashboard、`apple-touch-icon`/启动屏、manifest `id`。

### C7. 桌面端专项
- 宽屏别拉成一条单列;Agent 右侧栏**保持删除**(别复活);可选恢复 ⌘N 等快捷键;MaiMBot **保持移除**(别再 import)。

### C8. 通用难用点排查(自由发挥但记录)
- 通知点击 deep-link 是否落到正确页;课程/考试详情可点开;长文本截断 + 省略;深色背景对比度;按钮可点区域 ≥44px。

## 附录 D — 验收门槛(每层做完对照)

- **①功能**:附录 A 全绿;后端日志 20 分钟无 traceback;无 token 全 401。
- **②逻辑**:B1 全局无漏"待批阅";B2 同一条目一天不重复推;B3 改期撤旧排新;B5 时间全 UTC;B4 external_update 通(或明确标注未做);B6 逾期分组。
- **③UI**:C1 全局态齐;C2 课程表网格上线;移动+桌面各过一遍无明显难用点。
- 每层完打 tag(`polish-p1/p2/p3`)并 bundle 同步到云端。
