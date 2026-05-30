# DingTalk 消息提取接入 — 实现文档

> 服务器：`aliyun-root`  
> 项目路径：`/opt/chatbot/`  
> 最后更新：2026-05-30

---

## 一、整体架构

```
钉钉 Linux 客户端 (DISPLAY=:99)
    ↓  写入加密 SQLite DB (AES-128-ECB, key=9f6ac1b97a9021bd)
/root/.config/DingTalk/.../DBFiles/dingtalk.db + dingtalk.db-wal
    ↓  只读 bind mount → /dingtalk_db/
chatbot-backend 容器 (FastAPI + APScheduler)
    ↓  每 60s: 解密→粗筛→LLM精筛→入库
/data/chatbot.db  (volume chatbot_chatbot_data)
    ├── dingtalk_messages   (verdict: notify / interest / drop)
    └── dingtalk_sync_state (last_seen_created_at 游标)
```

**三桶分流：**
- `notify` — 课程/作业/考试/ddl/私聊，直接推送
- `interest` — CS相关竞赛/技术讲座/实习，归档"你可能感兴趣"，不打扰
- `drop` — 噪音（招聘/行政通报/群杂事/考勤/非CS活动）

---

## 二、已完成的工作

### 2.1 核心逆向（AES 密钥提取）

**路径**：从进程内存暴力扫描 heap，在 `0x55aadbd55000+0x759450` 找到明文密钥。

- 钉钉 `libsync.so` 内嵌 SQLite + 自定义 AES-128-ECB codec
- 函数链：`sqlite3_key` → `AES_Encryption_Create` → `genKey(password, nKey)` → `aes_decrypt_key128`
- `genKey`：把 password 截取/填充到 44 字节（不足补 `0x7b`），取前 16 字节作 AES-128 key
- **KEY（ASCII）**：`9f6ac1b97a9021bd`  **（HEX）**：`39663661633162393761393032316264`
- 加密模式：**AES-128-ECB**，每 4096 字节一页，按 16 字节块解密
- WAL 文件：前 32 字节是标准 SQLite WAL header，后续每帧 = 24B frame header + 4096B 加密页
  - frame header `[0:4]` 大端 = `page_no`（1-based）
  - 同样 AES-ECB 解密，按 page_no 覆盖对应页

**验证**：`AES.new(KEY, ECB).decrypt(file[0:16])` == `b"SQLite format 3\x00"` ✓

**性能优化**（已应用）：
- 原实现：逐 16 字节调用 cipher，2.66s / 11MB WAL
- 优化后：`cipher.decrypt(full_page)` 整块，**0.074s**，36× 提速
- 内存峰值：18MB RSS，对 2核/1.8G 服务器无压力

---

### 2.2 DB 表结构（dingtalk.db 解密后）

```
tbconversation    — cid, title, lastMid, unreadCount, lastModify
tbmsg_000 ~ 127  — 消息按 cid hash 分 128 张表
    primaryKey, cid, mid, senderId, contentType, content (JSON), createdAt
    content JSON: {"contentType":1, "text":"..."} (type=1 文本)
tbuser_profile_v2 — uid, nick (发件人姓名)
```

**发件人名字查询**：`JOIN tbuser_profile_v2 ON CAST(uid AS TEXT) = CAST(senderId AS TEXT)`

**contentType 已知映射**：
| type | 含义 | 保留 |
|------|------|------|
| 1 | 文本 | ✓ |
| 2 | 图片 | ✓ (OCR) |
| 3 | 音频 | ✓ |
| 5 | 视频 | ✓ |
| 102/500 | 文件 | ✓ (OCR if pdf/image) |
| 501 | 卡片 | ✗ |
| 1201 | 链接卡片 | ✗ |
| 2950 | 互动卡片（系统通知等）| ✗ |

---

### 2.3 模块文件（`/opt/chatbot/backend/app/dingtalk/`）

| 文件 | 状态 | 说明 |
|------|------|------|
| `dingtalk_service.py` | ✅ 完成 | 解密DB、WAL、query_new_messages |
| `filters.py` | ✅ 完成 | 两级关键词粗筛，输出 verdict + 各字段 |
| `classifier.py` | ✅ 完成 | LLM精筛（async，batch=15，复用MiMo） |
| `task.py` | ✅ 完成 | async编排入口 run_dingtalk_sync() |
| `schema.py` | ✅ 完成 | ensure_schema + COLUMN_MIGRATIONS |
| `router.py` | ✅ 完成 | REST API endpoints |
| `sync.py` | ⚠️ 旧版 | 早期同步版本，已被 task.py 替代，可删除 |

**接入状态**：
- `main.py` — dingtalk router 已 include ✅
- `scheduler.py` — dingtalk_sync job 已注册（60s interval）✅
- `docker-compose.yml` — bind mount + 环境变量已配置 ✅
- `requirements.txt` — `pycryptodome==3.21.0` 已添加 ✅
- Dockerfile — aliyun pip mirror 已添加 ✅

---

### 2.4 当前阻塞的 BUG

**错误**：`sqlite3.OperationalError: no such column: verdict`

**原因**：  
`ensure_schema()` 内的 `executescript(DINGTALK_SCHEMA)` 在 SQLite 里 **无法给已存在的表添加新列**（`CREATE TABLE IF NOT EXISTS` 不会修改现有结构）。  
`dingtalk_messages` 表早期已在宿主机测试时建好（只有旧列），容器启动后 `CREATE TABLE IF NOT EXISTS` 直接跳过，`COLUMN_MIGRATIONS` 里的 `ALTER TABLE` 理论上应该补列——但 `executescript()` 会在整个 SCHEMA 中因遇到表已存在而行为异常。

**修复方法**（直接在容器外操作宿主机上的 chatbot.db）：

```bash
DB=/var/lib/docker/volumes/chatbot_chatbot_data/_data/chatbot.db
sqlite3 $DB "
  ALTER TABLE dingtalk_messages ADD COLUMN media_type TEXT;
  ALTER TABLE dingtalk_messages ADD COLUMN category TEXT;
  ALTER TABLE dingtalk_messages ADD COLUMN attachments TEXT;
  ALTER TABLE dingtalk_messages ADD COLUMN is_system INTEGER DEFAULT 0;
  ALTER TABLE dingtalk_messages ADD COLUMN is_group INTEGER DEFAULT 0;
  ALTER TABLE dingtalk_messages ADD COLUMN has_link INTEGER DEFAULT 0;
  ALTER TABLE dingtalk_messages ADD COLUMN needs_ocr INTEGER DEFAULT 0;
  ALTER TABLE dingtalk_messages ADD COLUMN ocr_status TEXT DEFAULT 'none';
  ALTER TABLE dingtalk_messages ADD COLUMN ocr_text TEXT;
  ALTER TABLE dingtalk_messages ADD COLUMN verdict TEXT DEFAULT 'notify';
  ALTER TABLE dingtalk_messages ADD COLUMN verdict_reason TEXT;
" 2>/dev/null; echo done
# 验证
sqlite3 $DB 'PRAGMA table_info(dingtalk_messages);'
```

同时修复 `ensure_schema()` 本身——让 `COLUMN_MIGRATIONS` 在 `executescript` **之后** 单独 try/except 运行（已在代码里，但需确认 `executescript` 不会中途 abort）：

在 `schema.py` 的 `ensure_schema` 改为：
```python
def ensure_schema(db_path: str) -> None:
    with sqlite3.connect(db_path) as conn:
        # CREATE TABLE IF NOT EXISTS — 只建表不改列
        conn.executescript(DINGTALK_SCHEMA)
        # 逐条 ALTER，忽略"duplicate column"
        for stmt in COLUMN_MIGRATIONS:
            try:
                conn.execute(stmt)
                conn.commit()
            except sqlite3.OperationalError:
                pass
```

---

## 三、待实现功能

### 3.1 钉钉设置项（Settings UI）

**需求**：钉钉功能作为可开关的设置项，支持：
- 配置是否启用 dingtalk 同步
- 配置钉钉账号 userId（用于过滤自己发的消息）
- 配置 DB 路径（万一账号切换）
- 登录状态监控 + 失效通知

**实现位置**：`app/routers/settings.py` + `app/config.py`

**需添加的配置字段**（写入 `settings` KV 表，不改 config.py）：

| key | 默认值 | 说明 |
|-----|--------|------|
| `dingtalk_enabled` | `true` | 全局开关 |
| `dingtalk_db_path` | `/dingtalk_db/dingtalk.db` | DB mount 路径 |
| `dingtalk_self_uid` | `2679549222` | 自己的钉钉 uid（过滤自发消息） |
| `dingtalk_persona` | "浙江工业大学CS 2024本科生..." | LLM分类用的人设 |
| `dingtalk_sync_interval` | `60` | 轮询秒数 |
| `dingtalk_llm_filter` | `true` | 是否启用 LLM 精筛 |
| `dingtalk_pdf_max_mb` | `5` | PDF OCR 大小上限 |

**登录状态检测**（每次 sync 顺带检查）：

钉钉客户端是 GUI 进程，没有 session API 可查。检测方法：
1. 检查进程是否在跑：`/proc/<pid>/status` 或 `pgrep com.alibabainc.dingtalk`
2. 检查 WAL 文件最后修改时间：`stat dingtalk.db-wal`，如果超过 N 分钟无更新，说明客户端可能挂了
3. DB 可正常解密且能查到数据 → 认为正常

**登录失效判定逻辑** (`task.py` 里加)：
```python
import os, time

WAL_PATH = "/dingtalk_db/dingtalk.db-wal"
WAL_STALE_SECONDS = 1800  # 30分钟无更新认为客户端挂了

def check_dingtalk_alive() -> tuple[bool, str]:
    # 1. WAL 存在且不太旧
    try:
        mtime = os.path.getmtime(WAL_PATH)
        age = time.time() - mtime
        if age > WAL_STALE_SECONDS:
            return False, f"WAL 未更新 {int(age//60)} 分钟，钉钉可能已掉线"
    except FileNotFoundError:
        return False, "WAL 文件不存在，钉钉未运行"
    # 2. 能成功解密 page 1
    try:
        decrypt_db_to_tmp()
        return True, "ok"
    except Exception as e:
        return False, f"解密失败: {e}"
```

---

### 3.2 登录失效通知（钉钉 + 学习通）

**需求**：检测到以下情况时，发送 Web Push 通知给用户：
1. 钉钉 WAL 长时间无更新（客户端掉线/崩溃）
2. 钉钉 DB 解密失败
3. 学习通 session 失效（`chaoxing_svc.is_logged_in == False`）
4. API provider 不可达（standby agent 调用失败）

**实现位置**：`app/tasks/health_monitor.py`（新建）

```python
# app/tasks/health_monitor.py
"""每 10 分钟检查一次关键服务状态，失效时推送通知（同类通知去重）。"""
import time, os, logging
from app.services.push_service import send_push_to_all_subscribers, has_notified, log_notification_sent

logger = logging.getLogger("health_monitor")

COOLDOWN = 3600  # 同类告警 1 小时内只推一次

async def run_health_check(app_state):
    db_path = app_state.settings.database_path
    alerts = []

    # 1. 钉钉状态
    wal = "/dingtalk_db/dingtalk.db-wal"
    try:
        age = time.time() - os.path.getmtime(wal)
        if age > 1800:
            alerts.append(("dingtalk_stale", "钉钉可能掉线", f"WAL {int(age//60)} 分钟无更新，请检查服务器钉钉客户端"))
    except FileNotFoundError:
        alerts.append(("dingtalk_missing", "钉钉未运行", "钉钉客户端进程不存在，DB 无法读取"))

    # 2. 学习通登录状态
    chaoxing_svc = getattr(app_state, "chaoxing_svc", None)
    if chaoxing_svc and not chaoxing_svc.is_logged_in:
        alerts.append(("chaoxing_logout", "学习通登录已失效", "请重新登录超星学习通"))

    # 3. 发推送（带去重，COOLDOWN 内同 tag 只发一次）
    for tag, title, body in alerts:
        if not await has_notified(db_path, tag, "health"):
            await send_push_to_all_subscribers(db_path, title, body, tag=tag)
            await log_notification_sent(db_path, tag, "health", title)
            logger.warning("Health alert sent: %s", tag)
```

**注册到 scheduler**：
```python
scheduler.add_job(
    run_health_check,
    IntervalTrigger(minutes=10),
    args=[app_state],
    id="health_monitor",
    max_instances=1,
    misfire_grace_time=120,
    replace_existing=True,
)
```

---

### 3.3 API 不可达通知

在 `standby_agent.py` 和 `dingtalk/classifier.py` 的 `agent_complete` 调用处，捕获连续失败并推送：

```python
# 在 classifier.py _classify_batch 的 except 里
from app.tasks.health_monitor import _alert_api_failure
await _alert_api_failure(app_state, provider_id)
```

```python
# health_monitor.py 里
_api_fail_count = {}

async def _alert_api_failure(app_state, provider_id: str):
    key = f"api_fail_{provider_id}"
    _api_fail_count[key] = _api_fail_count.get(key, 0) + 1
    if _api_fail_count[key] >= 3:  # 连续 3 次才告警
        db_path = app_state.settings.database_path
        if not await has_notified(db_path, key, "health"):
            await send_push_to_all_subscribers(
                db_path, "AI 接口不可达",
                f"{provider_id} 连续 {_api_fail_count[key]} 次调用失败",
                tag=key
            )
            await log_notification_sent(db_path, key, "health", key)
        _api_fail_count[key] = 0  # 推完重置
```

---

### 3.4 消息过滤规则细化（"计算机学院2024级本科生"群）

当前 `filters.py` 已有两级粗筛，需在 LLM 精筛的 prompt 里强化人设判断：

**已有人设**（`classifier.py` 的 `PERSONA` 变量）：
```
浙江工业大学计算机学院2024级本科生，关注：课程/作业/考试/ddl、
与计算机相关的竞赛(ACM/蓝桥/算法/AI/CTF等)、技术讲座、计算机方向的实习与科研机会。
对非计算机相关的招聘、文体志愿活动、行政考勤通报、转专业等不感兴趣。
```

**过滤边界确认（已与用户确认）**：

| 类型 | 示例 | 处理 |
|------|------|------|
| 课程讨论/作业/考试/ddl | "明天交实验报告" | `notify` |
| 私聊（1:1） | 所有内容 | `notify` |
| CS竞赛（ACM/蓝桥/算法/AI） | "蓝桥杯报名" | `interest` |
| CS技术讲座/实习/科研 | "XX公司AI方向实习" | `interest` |
| 非CS竞赛/招聘 | "文体志愿者招募" | `drop` |
| 招聘宣讲（非CS方向） | "校园招聘会" | `drop` |
| 行政通报 | "考勤学风通报" | `drop` |
| 群系统事件 | "XXX加入了群聊" | `drop` |
| 失物招领/闲聊 | "学生卡掉了" | 交LLM→通常`drop` |
| 大创/结题（非本人参与） | "大创提醒" | 交LLM→通常`interest/drop` |
| 转专业/学籍等行政 | "转专业通知" | `drop` |
| 链接（需判断内容） | 课程相关链接 | LLM判断 |

**PDF 大小限制**：超过 `dingtalk_pdf_max_mb`（默认 5MB）的附件跳过 OCR，标记 `ocr_status='too_large'`。

---

### 3.5 OCR 工作队列（未实现）

数据库里 `ocr_status='pending'` 的消息（图片/PDF）需要一个独立 worker：

**实现位置**：`app/tasks/ocr_worker.py`（待建）

**思路**：
1. 定时（每 5 分钟）查 `dingtalk_messages WHERE ocr_status='pending'`
2. 解析 `attachments` JSON 取 `url` / `media_id`
3. 钉钉文件 URL 需要用 session cookie 下载（dingtalk客户端凭据）
4. 下载完用本地 OCR（`pytesseract` 或 调 LLM vision）
5. 结果写入 `ocr_text`，更新 `ocr_status='done'`
6. 如果是图片且 OCR 后内容课程相关，重新走 classifier 并可能升级 `verdict` 为 `notify`

**注意**：下载钉钉附件需要 `authMediaId` + 有效 session，目前 DB 里记录了 `media_id`，但 session cookie 需要从钉钉客户端进程获取（复杂）。**建议暂缓**，先标记 `pending` 积累，后续有完整方案再处理。

---

## 四、立即需要执行的步骤（按顺序）

### Step 1：修复当前 BUG（`verdict` 列缺失）

```bash
# 宿主机上执行
DB=/var/lib/docker/volumes/chatbot_chatbot_data/_data/chatbot.db
for col in \
  "media_type TEXT" \
  "category TEXT" \
  "attachments TEXT" \
  "is_system INTEGER DEFAULT 0" \
  "is_group INTEGER DEFAULT 0" \
  "has_link INTEGER DEFAULT 0" \
  "needs_ocr INTEGER DEFAULT 0" \
  "ocr_status TEXT DEFAULT 'none'" \
  "ocr_text TEXT" \
  "verdict TEXT DEFAULT 'notify'" \
  "verdict_reason TEXT"
do
  sqlite3 "$DB" "ALTER TABLE dingtalk_messages ADD COLUMN $col" 2>/dev/null
done
echo "migration done"
sqlite3 "$DB" 'PRAGMA table_info(dingtalk_messages);' | grep verdict
```

然后验证：
```bash
curl -s -X POST http://localhost:80/api/dingtalk/sync | python3 -m json.tool
```

### Step 2：验证三桶分流效果

```bash
# notify 桶（课程/私聊）
curl 'http://localhost/api/dingtalk/messages?bucket=notify&limit=10'
# interest 桶（CS相关）
curl 'http://localhost/api/dingtalk/interest?limit=10'
```

### Step 3：建 health_monitor.py

新建 `app/tasks/health_monitor.py`，按上文 3.2 节实现，注册到 scheduler。

### Step 4：钉钉启用开关

在 `task.py` 的 `run_dingtalk_sync` 开头加：
```python
# 读 settings 表的开关
async with aiosqlite.connect(db_path) as adb:
    row = await (await adb.execute("SELECT value FROM settings WHERE key='dingtalk_enabled'")).fetchone()
    if row and str(row[0]).lower() in ('false', '0', 'no'):
        return {"ok": True, "skipped": "disabled"}
```

### Step 5：rebuild 并验证

```bash
cd /opt/chatbot
docker compose build backend && docker compose up -d backend
# 等健康检查通过
watch docker compose ps
# 看日志
docker logs -f chatbot-backend-1 2>&1 | grep -E 'dingtalk|ERROR'
```

---

## 五、文件变更清单

```
backend/app/dingtalk/
    dingtalk_service.py   ✅ 完成（AES整块解密已优化）
    filters.py            ✅ 完成（三桶粗筛）
    classifier.py         ✅ 完成（LLM精筛，人设已配置）
    task.py               ✅ 完成（async编排）
    schema.py             ✅ 完成（需修复ensure_schema的commit时序）
    router.py             ✅ 完成（/messages?bucket= /interest /sync /bootstrap）
    sync.py               ⚠️  旧版，可删除
    __init__.py           ✅ 完成

backend/app/tasks/
    scheduler.py          ✅ dingtalk_sync job已注册
    health_monitor.py     ❌ 待建（钉钉+学习通掉线通知，API不可达通知）

backend/app/main.py       ✅ dingtalk router已include
backend/app/config.py     ⚠️  dingtalk 设置项用 settings KV表，无需改
backend/requirements.txt  ✅ pycryptodome已添加
backend/Dockerfile        ✅ aliyun pip mirror已添加
docker-compose.yml        ✅ bind mount + DINGTALK_DB_SOURCE已配置
```

---

## 六、前端展示（暂未实现）

如果要在 chatbot web 界面展示钉钉消息，建议：

1. **"钉钉消息"标签页** — 复用 `/api/dingtalk/messages?bucket=notify` 展示 notify 桶
2. **"你可能感兴趣"浮条** — 轮询 `/api/dingtalk/interest`，收起展开 accordion
3. **设置页** — `dingtalk_enabled` 开关、`dingtalk_persona` 文本域（改变人设）

---

## 七、关键参数速查

| 参数 | 值 |
|------|----|
| AES Key (hex) | `39663661633162393761393032316264` |
| AES Key (ASCII) | `9f6ac1b97a9021bd` |
| AES Mode | ECB，页内整块解密 |
| Page Size | 4096 字节 |
| WAL Header | 32 字节（标准SQLite WAL header） |
| WAL Frame Header | 24 字节，[0:4] 大端 = page_no（1-based） |
| 钉钉UID（自己） | `2679549222` |
| 系统号阈值 | uid < 10,000,000 视为系统服务号 |
| DB mount路径 | `/dingtalk_db/dingtalk.db` |
| Sync间隔 | 60s（容器内APScheduler） |
| LLM Provider | xiaomimimo / mimo-v2.5-pro |
| LLM Batch大小 | 15条/次 |
| WAL失活阈值 | 30分钟无更新 → 钉钉掉线告警 |
