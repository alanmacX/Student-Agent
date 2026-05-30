# Web Backend Migration Spec
## 从 Swift macOS App 完整迁移到 Python/FastAPI 后端

> **目的**：这份文档是给 coding agent 的施工图。Agent 必须逐文件对照 Swift 源码，在 Python 后端实现完全等价的逻辑。不允许猜测，不允许简化，有不确定的地方必须读源码再写。

---

## 目录

1. [项目结构 & 文件映射](#1-项目结构--文件映射)
2. [数据库 Schema 补全](#2-数据库-schema-补全)
3. [ChaoxingService — HTTP 客户端完整迁移](#3-chaoxingservice--http-客户端完整迁移)
4. [ChaoxingMessageFilter — 消息过滤管道](#4-chaoxingmessagefilter--消息过滤管道)
5. [ChaoxingMemoryReducer — Memory 文档管理](#5-chaoxingmemoryreducer--memory-文档管理)
6. [ChaoxingMemoryAgent — LLM 提取管道](#6-chaoxingmemoryagent--llm-提取管道)
7. [Schedule Agent Harness — 工具循环与 Orchestrator](#7-schedule-agent-harness--工具循环与-orchestrator)
8. [Standby Agent — 已有，需要对照补全](#8-standby-agent--已有需要对照补全)
9. [工作流程 & 施工顺序](#9-工作流程--施工顺序)

---

## 1. 项目结构 & 文件映射

| Swift 文件 | Python 目标文件 | 状态 |
|---|---|---|
| `ChaoxingService.swift` | `app/services/chaoxing_service.py` | ❌ 大量错误，需完整重写 |
| `ChaoxingMessageFilter.swift` | `app/services/chaoxing_service.py` (内嵌) | ❌ 缺失 |
| `ChaoxingMemoryModels.swift` | `app/services/memory_models.py` (新建) | ❌ 缺失 |
| `ChaoxingMemoryReducer.swift` | `app/services/memory_reducer.py` (新建) | ❌ 缺失 |
| `ChaoxingMemoryAgent.swift` | `app/services/memory_agent.py` | ❌ 严重简化，需重写 |
| `ScheduleHarness.swift` | `app/services/schedule_agent.py` | ⚠️ 部分完成，需对照补全 |
| `ScheduleAgentCore.swift` (Orchestrator) | `app/services/schedule_agent.py` | ❌ Orchestrator 逻辑缺失 |
| `CompanionEngine.swift` | 不需要迁移（macOS UI 专用） | — |
| `RemindersService.swift` | `app/routers/reminders.py` | ⚠️ 部分 |

**Swift 源码目录**：`/Users/macalan/Documents/chatbot/ChatBot/`
**Python 后端目录**：`/Users/macalan/Documents/chatbot/web/backend/app/`

---

## 2. 数据库 Schema 补全

在 `app/database.py` 的 `_SCHEMA` 中添加以下缺失的表，并通过 `_COLUMN_MIGRATIONS` 补全现有表的 timestamp 列（已实现，见 `database.py`）：

**新增列到现有表（通过 `_COLUMN_MIGRATIONS`，try/except 安全）**：
- `chaoxing_session`: `last_active_at TEXT`（每次成功同步后更新）、`updated_at TEXT`
- `chaoxing_memory_entries`: `dedupe_key`, `category`, `confidence`, `content_time`, `created_at`, `updated_at`, `source_ids_json`, `source_fingerprints_json`, `conversation_ids_json`, `conversation_names_json`, `sender_names_json`, `linked_assignment_key`, `linked_course_key`

**新建表**：

```sql
-- 替代 ChaoxingSyncState: 跟踪已处理的消息 fingerprint（当前只有 processed_ids，缺 fingerprints）
CREATE TABLE IF NOT EXISTS chaoxing_processed_fingerprints (
    fingerprint  TEXT PRIMARY KEY,
    processed_at TEXT NOT NULL
);

-- 对话级别同步状态（对应 ChaoxingConversationSyncState）
CREATE TABLE IF NOT EXISTS chaoxing_conversation_sync (
    conversation_id      TEXT PRIMARY KEY,
    last_seen_sent_at    TEXT,
    last_seen_message_id TEXT,
    seen_count           INTEGER NOT NULL DEFAULT 0,
    created_at           TEXT NOT NULL,   -- 首次见到该对话的时间
    updated_at           TEXT NOT NULL    -- 最后一次 save_sync_state 写入的时间
);

-- Memory 条目需要的额外字段（扩展现有 chaoxing_memory_entries 表）
-- 当前 schema 缺少: dedupe_key, category, confidence, source_fingerprints,
--   source_ids(多条), conversation_ids(多条), sender_names(多条),
--   linked_assignment_key, linked_course_key, content_time, created_at
-- 方案：删除旧表，用完整 schema 重建（migration 里用 IF NOT EXISTS + ALTER TABLE）
```

**完整目标 chaoxing_memory_entries schema**（替换当前的）：

```sql
CREATE TABLE IF NOT EXISTS chaoxing_memory_entries (
    id                   TEXT PRIMARY KEY,
    dedupe_key           TEXT NOT NULL DEFAULT '',
    category             TEXT NOT NULL DEFAULT 'notice',
    importance           TEXT NOT NULL DEFAULT 'medium',
    title                TEXT NOT NULL,
    summary              TEXT NOT NULL,
    reason               TEXT NOT NULL DEFAULT '',
    action_hint          TEXT,
    content_time         TEXT,
    expires_at           TEXT NOT NULL,
    source_ids_json      TEXT NOT NULL DEFAULT '[]',   -- JSON array of message IDs
    source_fingerprints_json TEXT NOT NULL DEFAULT '[]',
    conversation_ids_json TEXT NOT NULL DEFAULT '[]',
    conversation_names_json TEXT NOT NULL DEFAULT '[]',
    sender_names_json    TEXT NOT NULL DEFAULT '[]',
    linked_assignment_key TEXT,
    linked_course_key    TEXT,
    confidence           REAL NOT NULL DEFAULT 0.75,
    source_text_preview  TEXT NOT NULL DEFAULT '',
    created_at           TEXT NOT NULL,
    updated_at           TEXT NOT NULL,
    archived_at          TEXT
);
CREATE UNIQUE INDEX IF NOT EXISTS idx_memory_dedupe ON chaoxing_memory_entries(dedupe_key)
    WHERE dedupe_key != '';
```

**Migration 策略**：在 `run_migrations()` 里用 `ALTER TABLE ADD COLUMN IF NOT EXISTS` 逐列补全现有表，不要 DROP（保留已有数据）。新列默认值见上面的 schema。

---

## 3. ChaoxingService — HTTP 客户端完整迁移

**Swift 源码**：`ChaoxingService.swift`（1341 行，全文读完再写）

### 3.1 常量

```python
CHAOXING_MOBILE_UA = (
    "Mozilla/5.0 (Linux; Android 12; MI10) AppleWebKit/537.36 "
    "(KHTML, like Gecko) Chrome/108.0.0.0 Mobile Safari/537.36 "
    "com.chaoxing.mobile/ChaoXingStudy_3_6.7.2_android_phone_10831_263"
)
CHAOXING_DESKTOP_UA = (
    "Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/537.36 "
    "(KHTML, like Gecko) Chrome/120.0.0.0 Safari/537.36"
)
```

### 3.2 Session 管理（持久化）

- **`init()`**：从 DB `chaoxing_session WHERE id=1` 读取 cookies_json、uid、username，调用 `_probe_session()`
- **`_probe_session()`**（宽松策略）：
  - GET `https://passport2.chaoxing.com/api/check?islogin=1`
  - 返回 `json["isLogin"] == True` → True
  - `httpx.NetworkError` 或 `TimeoutException` → **不清除 session，返回 `uid is not None`**（网络问题不等于未登录）
  - 其他异常 → False
- **`_persist_session(cookies, uid, username)`**：写入 `chaoxing_session` 表

### 3.3 QR 登录（对照 Swift 第 90–164 行）

1. `create_qr_session()`:
   - 新建 desktop UA 的 `httpx.AsyncClient`（存为 `self._qr_client`）
   - GET `https://passport2.chaoxing.com/login`（初始化 session cookie）
   - POST `https://passport2.chaoxing.com/refreshQRCode`，Referer=login URL
   - 解析 `uuid`、`enc`
   - GET `https://passport2.chaoxing.com/createqr?uuid={}&fid=-1`，取图片二进制
   - 返回 `{uuid, enc, image_data_url: "data:image/png;base64,..."}`

2. `poll_qr(uuid, enc)`:
   - POST `https://passport2.chaoxing.com/getauthstatus/v2`，data: `{uuid, enc, doubleFactorLogin:"0", forbidotherlogin:"0"}`
   - `json["status"] is True` → 调用 `_finalize_qr_login()`，返回 `{"status":"confirmed"}`
   - `json["type"] == 4` → `{"status":"scanned"}`
   - `json["type"] in (6,7)` → `{"status":"expired"}`
   - 其他 → `{"status":"waiting"}`

3. `_finalize_qr_login()`:
   - GET `http://i.mooc.chaoxing.com/space/index`（跟随重定向，收集 auth cookies）
   - GET `https://sso.chaoxing.com/apis/login/userLogin4Uname.do`
   - 尝试从响应 `json["msg"]["name"]` 取 username
   - 合并 `_qr_client` 的全部 cookies，取 `_uid` 或 `UID` 作为 uid
   - 创建新的 main `_client`（desktop UA + 这批 cookies）
   - 设置 `self.is_logged_in = True`, `self.uid`, `self.username`
   - 调用 `_persist_session()`

### 3.4 课程列表（对照 Swift 第 168–201 行）

```
GET https://mooc1-api.chaoxing.com/mycourse/backclazzdata?view=json&mcode=&rss=1
Headers:
  User-Agent: {MOBILE_UA}
  X-Requested-With: com.chaoxing.mobile
  Accept-Language: zh_CN
  Referer: https://i.chaoxing.com
```

**解析**（对照 Swift `parseCourses`，第 810–826 行）：
- `json["channelList"]` → 过滤 `channel["cataid"] == "100000002"`（其他 cataid 是文件夹）
- `classId = str(channel["key"])`
- `cpi = str(channel["cpi"])`
- `content = channel["content"]`
- `courseId = str(content["course"]["data"][0]["id"])`
- `name = content["name"]`（或 `"(未知课程)"`）
- `teacher = content["course"]["data"][0].get("teacherfactor", "")`
- 跳过 courseId 或 classId 为空的条目

返回 `list[dict]`，每条含：`{id, classId, cpi, name, teacher, image}`

### 3.5 作业列表（对照 Swift 第 175–201 行 + 第 835–878 行）

```
GET https://mooc1-api.chaoxing.com/work/task-list?courseId={}&classId={}&cpi={}
Headers: 同课程列表（mobile UA + X-Requested-With）
Referer: https://mooc1.chaoxing.com
```

**HTML 解析**（对照 Swift `parseAssignmentsFromHTML`）：
- 检查 `"暂无作业"` 或 `class="empty"` → 直接返回 `[]`
- 正则：`<li onclick="goTask\(this\);" [^>]*data1="(\d+)"[^>]*>([\s\S]*?)</li>`（DOTALL）
- 每个 `<li>` 块内：
  - `<p>([^<]+)</p>` → title
  - 第一个 `<span>([^<]+)</span>`（无 class）→ status_raw
  - `<span class="fr">([^<]+)</span>` → remaining_time
- `statusLabel(status_raw)`: `"0"/"未做"→"未提交"`, `"1"/"已做"→"已提交"`, `"2"/"已截止"→"已截止"`, 其他原样
- `parseRelativeTimeString(remaining_time)`:
  - `"已过期"/"已截止"/"已超时"` → `datetime.now(utc).isoformat()`
  - 解析 `(\d+)天`、`(\d+)小时`、`(\d+)分钟` 累加秒数 → `(now + seconds).isoformat()`
  - 否则 None

`fetch_all_pending_assignments()`: 先 `fetch_courses()`，然后 `asyncio.gather(*[fetch_assignments(...) for c in courses])`，结果排序 by dueDate ASC。

### 3.6 IM 参数（对照 Swift 第 652–663 行）

```
GET https://im.chaoxing.com/webim/me
Headers: Referer: https://i.chaoxing.com
```

解析 HTML，用正则 `id="myTuid"[^>]*>([^<]*)` 分别提取 `myTuid`、`myPuid`、`myToken`。
若任意一个为空 → raise ValueError（未登录或页面结构变化）。

### 3.7 对话列表（对照 Swift 第 665–704 行）

```
POST https://im.chaoxing.com/webim/message/list/getMessageList
Headers:
  X-Requested-With: XMLHttpRequest
  Content-Type: application/x-www-form-urlencoded; charset=UTF-8
  Referer: https://im.chaoxing.com/webim/me
Body (form): tuid={}, puid={}, token={}
```

**解析**：
- `json["status"] == "success"`，否则返回 `[]`
- 遍历 `json["data"]`，跳过 `str(item["folder"]).lower() == "true"`
- `chat_id = str(item["chatId"])`，为空跳过
- `is_group = item.get("chatType") == "groupchat"`
- `updated_at`：`item["updateTime"]` 或 `item["createTime"]`（毫秒时间戳）→ UTC ISO
- `name = urllib.parse.unquote(item.get("chatName") or "学习通消息")`
- `msg_id = str(item.get("msgId", ""))`
- 返回结果按 `updated_at` 倒序排列

### 3.8 漫游消息（EaseMob）（对照 Swift 第 706–741 行）

```
POST https://a1-vip6.easecdn.com/cx-dev/cxstudy/users/{tuid}/messageroaming
Headers:
  Authorization: Bearer {token}
  Content-Type: application/json
  User-Agent: {DESKTOP_UA}
Body JSON: {"queue": "{chatId}@conference.easemob.com", "start": -1, "end": -1}
```

**后缀逻辑**：
- Group → 先试 `@conference.easemob.com`，再试 `@easemob.com`
- 1-to-1 → 先试 `@easemob.com`，再试 `@conference.easemob.com`
- 哪个后缀返回非空消息就用哪个（fallback 机制）
- `effective_is_group = suffix == "@conference.easemob.com"`

**解析**：`json["data"]["msgs"]` 列表，每条 raw：
- `encoded = raw["msg"]`（base64 编码的 Protobuf）
- `from_user = raw.get("fromUser") or {}`
- `raw_sender_name`: 按优先级 `from_user["nickname/name/realName/showName"]` → `raw["fromName/fromNickName"]`
- `raw_sender_uid`: `raw["from"]` → `from_user["uid/puid/id"]` → `raw["fromUid/fromPuid"]`
- `raw_msg_time_ms = float(raw["msgTime"])` if present

每条调用 `decode_roaming_message()` 解码。

### 3.9 Protobuf 解码器（对照 Swift 第 960–1285 行）

**必须完整逐行移植 Swift ProtoReader**，不能用第三方库：

```python
class _ProtoReader:
    """Port of Swift ProtoReader. Reads varint, length-delimited, skip by wire type."""
    # Wire types: 0=varint, 1=64bit(skip 8), 2=length-delimited, 5=32bit(skip 4)
    # next_field() → (field_number, wire_type) | None
    # read_varint() → int
    # read_length_delimited() → bytes
    # read_string() → str  # try utf-8, gb18030, gbk, big5, latin-1 in order
    # skip(wire_type)
```

**decode_meta(data: bytes)**（Swift 第 1135–1148 行）：
- field 1 → `id = str(read_varint())`
- field 2 → `from_ = decode_jid(read_length_delimited())`
- field 4 → `timestamp = read_varint()`（毫秒）
- field 6 → `payload = read_length_delimited()`

**decode_jid(data: bytes)**：field 2 → `name = read_string()`

**decode_body(data: bytes)**（Swift 第 1162–1177 行）：
- field 1 → `raw_type = read_varint()`
- field 2 → `from_ = decode_jid(...)`
- field 4（repeated）→ `contents.append(decode_content(...))`
- field 5（repeated）→ `k, v = decode_kv(...)；if k and v: ext[k] = v`

**decode_content(data: bytes)**（Swift 第 1179–1194 行）：
- field 1=raw_type, 2=text, 6=display_name, 7=remote_path, 10=action, 19=custom_event

**decode_kv(data: bytes)**：field 1=key, field 6=value

**content_display_text(c)**（Swift 第 1119–1132 行）：
- `text.strip()` 非空 → 直接返回
- raw_type 1 → `[图片] {display_name}` 或 `[图片]`
- raw_type 2 → `[视频]`，4 → `[语音]`，5 → `[文件]`
- raw_type 6 → `[命令] {action}`，7 → `[自定义] {custom_event}`
- 其他 → `""`

**decode_roaming_message(encoded, conversation, raw_sender_uid, raw_sender_name, raw_msg_time_ms)**（Swift 第 960–1055 行）：

1. **Fast path**（`len(encoded) < 256`）：
   - 尝试 base64 解码 → 若解码结果是合法 UTF-8 可打印文本（所有字符 `>=0x20` 或 `\t\n\r`）→ 存为 `plain_text`
   - base64 解码失败 → 把 raw string 本身当 `plain_text`
2. **Normal path**：
   - `meta_bytes = base64.b64decode(encoded)`
   - `meta = decode_meta(meta_bytes)`
   - `payload = meta["payload"]`：先尝试把 payload 当 UTF-8 字符串再 base64 解码（double-base64）；失败就直接用
   - `body = decode_body(payload)`
   - 拼接所有 content 的 `display_text`，过滤空，join with `\n`
   - text 为空 → return None
3. **回退**：normal path 的任何步骤抛异常 → 如果有 `plain_text` 且有 `raw_sender_uid` → 合成最小 message dict
4. **Sender 优先级**（Swift 第 1015–1024 行）：
   - `sender_id`: `body.from_.name` > `meta.from_.name` > `raw_sender_uid` > `"unknown"`
   - `sender_name`: `raw_sender_name` > `ext["fromName"]` > `ext["fromNickName"]` > `ext["nickname"]` > `ext["realName"]`
5. **Timestamp 优先级**：`meta.timestamp > 0` > `raw_msg_time_ms` > now
6. 返回 dict，字段见 §3.11

### 3.10 收件箱通知（对照 Swift 第 297–354 行）

```
GET https://notice.chaoxing.com/pc/notice/getNoticeList?pnum=1&count={limit}&type=0
Headers: Referer: https://i.chaoxing.com
```

**解析**：
- `json["notices"]["list"]`
- `id = item["idCode"]`（优先）或 `str(item["id"])`
- `text = f"{title}\n{content}"` 或单独 title/content，两者都空跳过
- `sender_name = item["createrName"]` 或 `"系统通知"`
- `sender_uid = str(item["createrId"]` 或 `item["createrPuid"]` 或 `"system")`
- `sent_at = item["insertTime"]` 或 `createTime` 或 `sendTime`（毫秒 → UTC ISO）
- 返回 message dict，`conversation_id="inbox"`, `conversation_name="收件箱"`

### 3.11 消息 dict 格式（所有 callers 依赖此格式）

```python
{
    "id":                str,   # 唯一消息 ID
    "conversation_id":   str,
    "conversation_name": str,
    "is_group":          bool,
    "sender_id":         str,
    "sender_name":       str | None,
    "sent_at":           str,   # ISO 8601 with timezone
    "type":              str,   # "TEXT", "IMAGE", etc.
    "text":              str,
    "image_urls":        list[str] | None,
}
```

### 3.12 公开 API（供外部调用）

```python
async def fetch_courses() -> list[dict]
async def fetch_assignments(course_id, class_id, cpi, course_name) -> list[dict]
async def fetch_all_pending_assignments() -> list[dict]
async def fetch_conversation_probes(limit=12) -> list[dict]
    # Returns: [{conversation_id, name, signature: f"{msg_id}:{updated_at}"}]
async def fetch_recent_messages(max_conversations=12, per_conversation=20,
                                 changed_conversation_ids=None) -> list[dict]
    # im_params → conversations → roaming per conv → inbox → deduplicate → sort desc
async def adaptive_sync_pass(db_path) -> float  # 返回下次同步间隔秒数
```

---

## 4. ChaoxingMessageFilter — 消息过滤管道

**Swift 源码**：`ChaoxingMessageFilter.swift`（128 行）

**目标文件**：`app/services/chaoxing_message_filter.py`（新建）

### 4.1 文本规范化（对照 Swift `ChaoxingTextNormalizer`，`ChaoxingMemoryModels.swift` 第 224–245 行）

```python
class ChaoxingTextNormalizer:
    @staticmethod
    def display_text(value: str) -> str:
        # 替换   → 空格，\r → \n
        # split on whitespace/newline，join with 单空格
        # strip

    @staticmethod
    def key_text(value: str) -> str:
        # display_text().lower()，过滤掉空白和标点（Python: unicodedata category P* + Z*）

    @staticmethod
    def preview(value: str, limit: int) -> str:
        # display_text()，若超出 limit 截断加 "..."
```

### 4.2 消息指纹（对照 Swift `ChaoxingMessageFilter.normalize` 第 69–93 行）

```python
def normalize_message(msg: dict) -> dict:
    text = ChaoxingTextNormalizer.display_text(msg["text"])
    fingerprint_base = "|".join([
        msg["conversation_id"],
        msg["sender_id"],
        str(int(msg_sent_at_epoch / 60)),  # 分钟级别精度
        ChaoxingTextNormalizer.key_text(text),
        ",".join(msg.get("image_urls") or []),
    ])
    return {
        "source_id": msg["id"],
        "fingerprint": sha256_hex(fingerprint_base),
        "conversation_id": msg["conversation_id"],
        "conversation_name": ChaoxingTextNormalizer.display_text(msg["conversation_name"]),
        "is_group": msg["is_group"],
        "sender_id": msg["sender_id"] or "unknown",
        "sender_name": msg.get("sender_name"),
        "sent_at": msg["sent_at"],  # 保持 ISO 字符串
        "type": msg["type"],
        "text": text,
        "normalized_text": ChaoxingTextNormalizer.key_text(text),
        "image_urls": msg.get("image_urls") or [],
        "_raw": msg,  # 保留原始用于 OCR 等扩展
    }
```

### 4.3 过滤规则（对照 Swift `ChaoxingMessageFilter.run` 第 11–67 行）

噪声类型（直接丢弃）：`{"READ_ACK", "DELIVER_ACK", "RECALL"}`

纯闲聊集合（直接丢弃）：
```python
SHORT_CHATTER = {"好", "好的", "收到", "收到了", "ok", "OK", "嗯", "嗯嗯",
                 "是", "不是", "谢谢", "辛苦了", "+1", "晚安", "哈哈", "强强", "666"}
```

**过滤顺序**（每条消息按顺序检查，命中第一个就标记 reason 并跳过）：

1. `source_id in processed_source_ids` 或 `fingerprint in processed_fingerprints` → `"already_processed"`
2. `conversation_name.lower() in muted_names` → `"muted_conversation"`
3. `msg["type"] in NOISE_TYPES` → `"noise_type"`
4. `text == "" and image_urls == []` → `"empty_message"`
5. **Bootstrap 模式**（`initialized_at is None`）且 `sent_at < now - 7天` 且无 future cue → `"bootstrap_old_without_future_cue"`
6. `sent_at < now - 30天` 且无 future cue → `"stale_without_future_cue"`
7. `is_pure_chatter(text)` → `"pure_chatter"`
8. `is_duplicate_assignment_notice(text, assignments)` → `"duplicate_assignment_notice"`
9. 否则 → 保留为 candidate

**`contains_future_cue(text)`**：
```python
FUTURE_CUES = ["今天","明天","后天","本周","下周","周一","周二","周三","周四","周五",
               "周六","周日","截止","考试","上课","调课","停课","补课","教室","DDL","ddl"]
# 包含任一词，或匹配 r"\d{1,2}[月/-]\d{1,2}" → True
```

**`is_pure_chatter(text)`**（对照 Swift 第 110–116 行）：
- `normalized.strip() == ""` → True
- `normalized in SHORT_CHATTER` → True
- `len(normalized) <= 3 and not contains_future_cue(normalized)` → True
- 否则 False

**`is_duplicate_assignment_notice(msg, assignments)`**（对照 Swift 第 95–108 行）：
- text 不含 `"作业"/"任务"/"截止"/"ddl"` → False（快速跳过）
- assignments 中有任何一条：`title_key` 非空 且 normalized_text 包含 `title_key` → True

**结果**：
```python
{
    "candidates": list[dict],         # 最多取末尾 40 条（.suffix(40)）
    "processed_source_ids": set[str],
    "processed_fingerprints": set[str],
    "dropped_reasons": dict[str, str],
}
```

### 4.5 时间感知增强（Time-Aware Filtering）

过滤规则的步骤 5 & 6 需要根据消息时间戳做分级处理，替换当前的二值 bootstrap/stale 逻辑：

| 消息 age（`now - sent_at`） | 处理策略 |
|---|---|
| `≤ 1 小时` | **最高优先级**：跳过所有时间相关检查，直接进入候选队列 |
| `≤ 24 小时` | **高优先级**：跳过 bootstrap 和 stale 检查（步骤 5 & 6）；仍经过噪声/闲聊/重复过滤 |
| `1 天 < age ≤ 7 天` | **正常处理**：全部过滤规则生效 |
| `7 天 < age ≤ 30 天` | 只保留含 future cue 的消息（原步骤 6，保持不变） |
| `> 30 天` | 直接丢弃（原硬截断，保持不变） |

**实现方式**（在 `run()` 的主循环里，`normalize_message()` 之后立即计算）：

```python
from datetime import timedelta

ONE_HOUR    = timedelta(hours=1)
ONE_DAY     = timedelta(days=1)
SEVEN_DAYS  = timedelta(days=7)
THIRTY_DAYS = timedelta(days=30)

# 计算消息年龄
sent_dt = parse_iso(normalized["sent_at"])   # returns timezone-aware datetime
msg_age = now - sent_dt

# ① 最近 1 小时：完全跳过时间检查
if msg_age <= ONE_HOUR:
    candidates.append(normalized)
    continue

# ② 24 小时内：只跳过时间检查，其他过滤照常
skip_time_checks = msg_age <= ONE_DAY

# ③ 超过 30 天：硬截断
if msg_age > THIRTY_DAYS and not contains_future_cue(normalized["text"]):
    dropped_reasons[normalized["source_id"]] = "stale_30d"
    continue

# ④ Bootstrap 检查（initialized_at is None）：age > 7天 且无 future cue
if not skip_time_checks and sync_state.get("initialized_at") is None:
    if msg_age > SEVEN_DAYS and not contains_future_cue(normalized["text"]):
        dropped_reasons[normalized["source_id"]] = "bootstrap_old_without_future_cue"
        continue

# ⑤ 常规 stale 检查：age > 30天（已在 ③ 处理）

# 其余过滤规则（noise_type, pure_chatter 等）继续正常执行…
```

**时间戳写回约定**：

- `chaoxing_session.last_active_at`：每次 `adaptive_sync_pass()` 成功完成后写入 `now.isoformat()`；同时更新 `updated_at`
- `chaoxing_conversation_sync.updated_at`：每次 `save_sync_state()` 更新该对话时写入 `now.isoformat()`；`created_at` 仅在 INSERT 时写入
- `chaoxing_processed_fingerprints.processed_at` & `chaoxing_processed_ids.processed_at`：insert 时写入 `now.isoformat()`，之后不变

**调度器利用时间戳**（`adaptive_sync_pass()` 动态间隔逻辑）：
```python
# 读 chaoxing_session.last_active_at
# 读 MAX(chaoxing_conversation_sync.updated_at) over all conversations
# 若最近 1 小时内有任何对话更新 → 下次间隔 60–120s
# 若最近 6 小时内有更新 → 下次间隔 120–300s
# 否则 → 下次间隔 300–600s
```

### 4.4 同步状态（从 DB 读写）

**从 DB 加载 sync state**（替代 Swift `ChaoxingSyncState`）：
```python
async def load_sync_state(db_path) -> dict:
    # 读 chaoxing_processed_ids → processed_source_ids: set
    # 读 chaoxing_processed_fingerprints → processed_fingerprints: set
    # 读 chaoxing_sync_state WHERE key='initialized_at' → initialized_at: str|None
    # 读 chaoxing_conversation_sync → conversations: dict[id → state]
```

**保存 sync state 到 DB**：
```python
async def save_sync_state(db_path, result, messages, now):
    # INSERT OR IGNORE processed_source_ids
    # INSERT OR IGNORE processed_fingerprints
    # 若 initialized_at is None: INSERT chaoxing_sync_state('initialized_at', now.isoformat())
    # 更新 chaoxing_conversation_sync（last_seen_sent_at, last_seen_message_id, seen_count）
    # 维护 processed_source_ids/fingerprints 集合大小 ≤ 4000（超出时 trim 最旧的 2000 条）
```

---

## 5. ChaoxingMemoryReducer — Memory 文档管理

**Swift 源码**：`ChaoxingMemoryReducer.swift`（174 行）

**目标文件**：`app/services/memory_reducer.py`（新建）

### 5.1 Dedupe Key 生成（对照 Swift 第 130–147 行）

```python
def canonical_dedupe_key(item: dict, title: str, summary: str, messages: list[dict]) -> str:
    if item.get("dedupe_key"):
        return f"llm::{key_text(item['dedupe_key'])}"
    if item.get("linked_course_key"):
        return f"course::{key_text(item['linked_course_key'])}::{key_text(title)}"
    base = "|".join([
        item.get("category") or "notice",
        messages[0]["conversation_name"] if messages else "",
        title,
        summary,
    ])
    return f"event::{sha256_hex(key_text(base))}"
```

### 5.2 默认过期时间（对照 Swift 第 149–157 行）

```python
def default_expiry(item: dict, messages: list[dict], now: datetime) -> datetime:
    content_time = parse_iso(item.get("content_time"))
    if content_time and content_time > now:
        return content_time + timedelta(hours=12)
    sent_ats = [parse_iso(m["sent_at"]) for m in messages if m.get("sent_at")]
    sent_at = max(sent_ats) if sent_ats else now
    return sent_at + timedelta(days=14)
```

### 5.3 Reduce 主流程（对照 Swift `reduce()` 第 5–87 行）

```python
async def reduce_memory(
    extracted: list[dict],          # LLM 返回的 ChaoxingExtractedInsight 列表
    candidate_messages: list[dict], # normalized messages
    assignment_keys: set[str],
    now: datetime,
    db_path: str,
) -> None:
    """将 LLM 提取结果合并/更新到 DB 的 chaoxing_memory_entries 表"""
    message_by_id = {m["source_id"]: m for m in candidate_messages}

    for item in extracted:
        if item.get("decision", "").lower() != "keep":
            continue
        confidence = item.get("confidence") or 0.75
        if confidence < 0.55:
            continue

        source_messages = [message_by_id[sid] for sid in (item.get("source_ids") or [])
                           if sid in message_by_id]
        if not source_messages:
            continue
        if item.get("linked_assignment_key") in assignment_keys:
            continue  # 已有作业系统跟踪，不重复记忆

        importance = normalize_importance(item.get("importance"))
        if importance not in ("high", "medium"):
            continue

        summary = display_text(item.get("summary") or "")
        if not summary:
            continue
        title = display_text(item.get("title") or source_messages[0]["conversation_name"] or "学习通通知")
        dedupe_key = canonical_dedupe_key(item, title, summary, source_messages)
        expires_at = parse_iso(item.get("expires_at")) or default_expiry(item, source_messages, now)
        if expires_at <= now:
            continue

        # 读取现有条目（若 dedupe_key 已存在）
        existing = await db_get_entry_by_dedupe_key(db_path, dedupe_key)
        if existing:
            # 更新：合并 source_ids, fingerprints, conversation_ids 等；取 max expires_at
            await db_update_memory_entry(db_path, existing, item, source_messages, now, expires_at, confidence, title, summary)
        else:
            # 插入新条目
            await db_insert_memory_entry(db_path, dedupe_key, item, source_messages, now, expires_at, confidence, title, summary, importance)

    # Sweep: 删除/归档已过期条目，保持总数 ≤ 100
    await sweep_memory(db_path, now)
```

**合并规则**（对照 Swift 第 56–76 行）：更新时取：
- `importance`：直接覆盖（最新 LLM 判断）
- `expires_at`：`max(existing.expires_at, new_expires_at)`
- `confidence`：`max(existing.confidence, new_confidence)`
- `source_ids`、`source_fingerprints`、`conversation_ids`、`conversation_names`、`sender_names`：去重合并（保持插入顺序，不重复）
- `updated_at`：now

**Sweep**（对照 Swift `ChaoxingMemoryStore.sweep`）：
```python
async def sweep_memory(db_path, now):
    # DELETE WHERE expires_at <= now (已过期)
    # 若总条数 > 100: DELETE 最旧的 (count - 100) 条（按 importance ASC, updated_at ASC 排序）
```

### 5.4 Insights 输出（对照 Swift `insights()` 第 89–114 行）

```python
async def get_insights(db_path, now, limit=40) -> list[dict]:
    # SELECT from chaoxing_memory_entries WHERE expires_at > now AND archived_at IS NULL
    # 排序: importance DESC (high>medium>low), content_time/updated_at ASC
    # 返回 list[dict] 格式:
    # {id, title, summary, action_hint, importance, sent_at(=content_time or updated_at)}
```

---

## 6. ChaoxingMemoryAgent — LLM 提取管道

**Swift 源码**：`ChaoxingMemoryAgent.swift`（287 行）

**目标文件**：`app/services/memory_agent.py`（完整重写）

### 6.1 主入口

```python
async def run_memory_agent(
    chaoxing_svc,
    db_path: str,
    provider: dict,
    model: str,
    api_key: str,
    muted_names: set[str] = None,
) -> dict:
```

**流程**（对照 Swift `process()` 第 7–124 行）：

1. **加载 sync state**：从 DB 读 processed_source_ids、processed_fingerprints、initialized_at
2. **获取最新消息**：`chaoxing_svc.fetch_recent_messages(max_conversations=12, per_conversation=20)`
3. **获取作业快照**：`chaoxing_svc.fetch_all_pending_assignments()`，构建 `assignment_keys = set["{courseName}::{title}"]`（用 key_text 规范化）
4. **过滤消息**（调用 `ChaoxingMessageFilter.run()`）：
   - 输入：messages（normalized）、sync_state、assignment_snapshots、muted_names
   - 输出：candidates（max 40 条）、processed_source_ids、processed_fingerprints、dropped_reasons
5. **如果 candidates 非空**：调用 `_extract_with_llm(candidates, assignments, active_memory, provider, model, api_key, now)`
6. **Reduce**（调用 `memory_reducer.reduce_memory()`）：将 LLM 结果合并到 DB
7. **保存 sync state**（调用 `save_sync_state()`）：
   - 标记所有 candidates 的 source_ids 和 fingerprints 为已处理
   - 若 `initialized_at is None`：写入 now
   - 更新 conversation 级别 last_seen 状态
   - Trim processed sets 到 ≤ 4000 条
8. **记录 trace**：可选，写入日志表或 print

### 6.2 System Prompt（对照 Swift 第 156–191 行）

**必须完整复制这段 prompt，不要简化**：

```python
def _system_prompt(now: datetime) -> str:
    return f"""Current time: {format_current_time(now)}
You are the Chaoxing Memory Agent extraction profile for a schedule/todo app.
Return strict JSON only, no markdown.

Schema:
{{
  "insights": [
    {{
      "decision": "keep" | "drop",
      "source_ids": ["message id"],
      "category": "assignment" | "course_change" | "exam" | "meeting" | "notice" | "other",
      "importance": "high" | "medium" | "low",
      "title": "short title",
      "summary": "what happened, with concrete dates/times if present",
      "reason": "why this belongs in memory, or why it was dropped",
      "action_hint": "optional next action",
      "content_time": "ISO-8601 date if the event time is known",
      "expires_at": "ISO-8601 date, required for keep. IMPORTANT: For time-specific tasks (e.g. 'prepare by 12:00 today', 'meeting at 15:00'), set this to exactly that time point. DO NOT use the default 14-day expiry for ephemeral/deadline tasks.",
      "dedupe_key": "stable semantic key",
      "linked_assignment_key": "exact assignment key if this only duplicates an existing assignment",
      "linked_course_key": "course key if this affects a course",
      "confidence": 0.0
    }}
  ]
}}

Rules:
- Emit one object per candidate message or per clearly merged event.
- Drop pure chat, acknowledgements, vague system noise, and anything already represented by the assignment snapshot.
- If a teacher announces homework and the same assignment is in the assignment snapshot, drop it with linked_assignment_key.
- Keep course changes such as reschedule, cancellation, makeup class, room change, exam, meeting, and actionable notices.
- For keep decisions, expires_at must be in the future. If no event time exists, use sent_at + 14 days.
- Use existing memory to merge repeated notices. Prefer stable dedupe_key over source id."""
```

### 6.3 User Payload（对照 Swift 第 194–249 行）

```python
def _user_payload(candidates, assignments, courses, active_memory_entries, now) -> str:
    # candidate 消息格式（每条）:
    # {source_id, fingerprint, conversation_id, conversation_name, is_group,
    #  sender_id, sender_name, sent_at(ISO), type, text(preview ≤900字), image_urls}

    # assignment_snapshot 格式（每条作业）:
    # {key: "{courseName}::{title}", course_name, title, due_date(ISO), status}

    # active_memory_summary（前 30 条 memory）:
    # {dedupe_key, title, summary, expires_at(ISO)}

    # course schedule（过滤 end >= now，前 40 条）:
    # "- {title} {start}-{end} {location}"

    return f"""Candidate messages:
{json.dumps(candidate_payload, ensure_ascii=False, indent=2)}

Assignment snapshot. Existing homework here is already tracked by the assignment system:
{json.dumps(assignment_snapshot, ensure_ascii=False, indent=2)}

Course schedule snapshot:
{course_lines or "No local course data."}

Active memory summary:
{json.dumps(memory_summary, ensure_ascii=False, indent=2)}"""
```

### 6.4 解析 LLM 响应

```python
def _parse_envelope(text: str) -> list[dict]:
    # 去掉 ```json / ``` 包裹
    # 找到第一个 { 和最后一个 }
    # JSON parse → data["insights"]
    # 若失败 → []
```

---

## 7. Schedule Agent Harness — 工具循环与 Orchestrator

**Swift 源码**：`ScheduleHarness.swift`（362 行）、`ScheduleAgentCore.swift`（317 行）

**目标文件**：`app/services/schedule_agent.py`（对照补全）

### 7.1 System Prompt（对照 Swift `buildStaticSystemPrompt` 第 51–63 行）

**当前 Python 版本的 system prompt 太简化，必须替换为**：

```python
STATIC_SYSTEM_PROMPT = """你是 ChatBot 的日程 Agent，主要管理 Reminders（提醒事项）和日历事件（Calendar），也能读取课程表、学习通作业和学习通消息。
你可以读取、创建、更新、完成、删除提醒事项，也可以读取、创建、更新、删除日历事件；可以读取学习通作业、学习通 memory，并在 memory 不足时触发 refresh_message_memory。如果你认为某条 memory 不重要或用户明确要求删除，可以使用 delete_message_memory 工具将其删除。只有在用户明确要求修改、完成或删除时才执行写操作。
课程表是 App 内本地导入的数据，不属于系统 Calendar；需要了解上课时间时使用 list_courses。不要为了导入、查看或规划课程表而创建 Calendar 事件。
不要因为"考试、期中、作业截止、会议、活动、通知"自动查询课程表；只有用户明确提到具体课程名、课程表、上课安排、调课、停课、补课或换教室时，才读取课程表。
需要操作具体提醒事项或日历事件时，先通过工具查到 ID。
工具结果默认只给你阅读。只有用户明确要看列表，才在工具参数里设置 show_in_ui=true。
最终回复使用中文，只写一句简洁摘要；不要重复完整列表，不要输出 Markdown 列表、表格、标题或代码块。"""
```

### 7.2 Dynamic Context（对照 Swift `buildDynamicContextPrompt` 第 66–92 行）

```python
def build_dynamic_context(now: datetime) -> str:
    # 必须包含:
    # - ISO 8601 时间含时区偏移（如 2026-05-27T14:30:00+08:00）
    # - 星期（中文）
    # - 明确说明"当用户说今天/明天/下周一等相对日期时以此时间为基准"
    # - 所有工具日期参数必须含时区偏移的 ISO-8601 格式示例
```

### 7.3 Turn Context（对照 Swift `makeTurnContextPrompt` 第 99–172 行）

在每次 run 开始前，从 DB 预读数据，注入到系统消息：

```python
async def build_turn_context(db_path, chaoxing_svc, now, window_hours=48) -> str:
    # 权限状态: Chaoxing 是否已登录
    # 未来 48 小时内提醒事项（前 16 条）：id, title, due_at, is_important
    # 未来 48 小时日历/活动（前 16 条，排除课程）：id, title, start_at, end_at
    # 未来 48 小时本地课程（前 16 条）：title, start_at, end_at, location
    # 重要学习通消息（前 8 条 high/medium memory entries）：title, action_hint, importance
    # 注意：这是快照，告知 LLM "如需精确数据请调用工具"
```

### 7.4 Orchestrator（对照 Swift `ScheduleOrchestrator.plan()` 第 79–116 行）

在 `run_schedule_agent()` 开始时，根据 user_message 关键词决定预读哪些数据：

```python
def orchestrator_plan(user_text: str) -> dict:
    lower = user_text.lower()
    sub_agents = []

    if any(kw in lower for kw in ["日历", "日程", "会议", "安排", "冲突", "calendar"]):
        sub_agents.append("calendar")
    if any(kw in lower for kw in ["提醒", "待办", "todo", "reminder", "完成"]):
        sub_agents.append("reminders")
    if any(kw in lower for kw in ["课", "课程", "课表", "教室", "调课", "停课", "补课"]):
        sub_agents.append("courses")
    if any(kw in lower for kw in ["学习通", "作业", "ddl", "deadline", "通知", "消息"]):
        sub_agents.append("chaoxing")

    expects_mutation = any(kw in lower for kw in
        ["创建", "添加", "改成", "修改", "删除", "完成", "取消", "提醒我"])

    if not sub_agents:
        sub_agents = ["calendar", "reminders", "courses", "chaoxing"]

    return {"sub_agents": sub_agents[:4], "expects_mutation": expects_mutation}
```

### 7.5 Pre-run Reports 注入（对照 Swift `injectReports` + `collectReports` 第 143–178 行）

根据 orchestrator plan 收集轻量报告，在最后一条 user message 之前插入：

```python
async def collect_reports(plan, db_path, chaoxing_svc, now, window_hours=48) -> str:
    lines = [f"日程 Orchestrator 已先做了轻量只读汇总。注意力窗口：未来 {window_hours} 小时。"]
    # 以下各部分仅在 plan["sub_agents"] 包含对应 key 时执行:

    # "calendar": 读 server_events，过滤未来 48h，前 5 条格式化
    # "reminders": 读 server_reminders，过滤未来 48h，前 5 条
    # "courses": 读 server_courses，过滤未来 48h，前 5 条
    # "chaoxing": 读 DB 的 memory entries，若空提示"调用 refresh_message_memory"
    # "mutation": 若 expects_mutation，提示"写操作必须调用工具并经过确认"

    return "\n".join(lines)
```

### 7.6 工具循环（对照 Swift `ScheduleHarness.run` 第 220–333 行）

```python
# 最大迭代 8 次（对照 Swift maxIterations = 8）
# 工具并行执行（asyncio.gather）
# trimIntraTurnContext: 保留 system/user anchors + 最后 6 对 assistant/tool（maxToolPairs=6）
# 工具结果截断: 超过 8000 字符时截断加说明
# 检测 bare completion text: "完成"/"done"/"ok"/"好的"/"已完成" 且有工具失败 → 返回失败摘要
```

**Bare completion 检测**（对照 Swift 第 319–325 行）：
```python
BARE_COMPLETION = {"完成", "done", "ok", "好的", "已完成"}
def is_bare_completion(text: str) -> bool:
    normalized = text.strip().rstrip("。.!！ ").lower()
    return normalized in BARE_COMPLETION
```

**工具集**（对照 Swift `ScheduleHarness.skills` 第 18–39 行）：
```
list_reminders, create_reminder, update_reminder, complete_reminder, delete_reminder,
list_courses, list_calendar_events, create_calendar_event, update_calendar_event, delete_calendar_event,
get_chaoxing_assignments, get_chaoxing_messages,
read_message_memory, refresh_message_memory, delete_message_memory
```

---

## 8. Standby Agent — 已有，需要对照补全

**Swift 对应逻辑**：`CompanionEngine.makeState()` 提供情绪/紧迫度判断，但 Standby Agent 是 Python 后端独有功能。

**当前 Python 版本**（`app/tasks/standby_agent.py`）基本正确，需要以下补全：

1. **Context 构建**：当前查询 `chaoxing_assignments_cache` 表（可能不存在），应改为查 `chaoxing_memory_entries` + `server_reminders` + `server_events`（这些表肯定存在）
2. **作业截止来自 memory**：Memory entries 里的 `action_hint` 和 `expires_at` 已经是 LLM 提炼过的，直接用
3. **去重逻辑已有**：保持现有 `has_notified()` + `log_notification_sent()` 不变
4. **模型配置**：从 settings 表读 `standby_agent_provider` 和 `standby_agent_model`（已有）

---

## 9. 工作计划（重规划）

> 当前后端状态总结：**极度简化，核心功能缺失**。
> - `chaoxing_message_filter.py`：**不存在**
> - `memory_models.py` / `memory_reducer.py`：**不存在**
> - `memory_agent.py`：filter = 仅 id 去重，system prompt 错误，无 fingerprint，无时间感知
> - `memory_reducer` sweep：死代码，**从未被调度**，memory entries 永远不清理
> - `schedule_agent.py`：system prompt 严重简化，无 orchestrator，无 dynamic context
> - `standby_agent.py`：查询不存在的表 `chaoxing_assignments_cache`（有 fallback 但逻辑混乱）
> - `chaoxing_session.last_active_at`、`chaoxing_conversation_sync`、fingerprints 表：**DB 已加，代码未使用**

---

### 必读文件（施工前全部读完）

```
Swift 源码（参考，不修改）:
  /Users/macalan/Documents/chatbot/ChatBot/ChaoxingService.swift        # 1341 行
  /Users/macalan/Documents/chatbot/ChatBot/ChaoxingMessageFilter.swift  # 128 行
  /Users/macalan/Documents/chatbot/ChatBot/ChaoxingMemoryModels.swift   # 246 行
  /Users/macalan/Documents/chatbot/ChatBot/ChaoxingMemoryReducer.swift  # 174 行
  /Users/macalan/Documents/chatbot/ChatBot/ChaoxingMemoryAgent.swift    # 287 行
  /Users/macalan/Documents/chatbot/ChatBot/ScheduleHarness.swift        # 362 行
  /Users/macalan/Documents/chatbot/ChatBot/ScheduleAgentCore.swift      # 317 行

Python 后端（现有，不破坏公开接口）:
  /Users/macalan/Documents/chatbot/web/backend/app/database.py               ✅ 已更新
  /Users/macalan/Documents/chatbot/web/backend/app/services/chaoxing_service.py
  /Users/macalan/Documents/chatbot/web/backend/app/services/memory_agent.py
  /Users/macalan/Documents/chatbot/web/backend/app/services/schedule_agent.py
  /Users/macalan/Documents/chatbot/web/backend/app/routers/chaoxing.py
  /Users/macalan/Documents/chatbot/web/backend/app/routers/schedule.py
  /Users/macalan/Documents/chatbot/web/backend/app/tasks/standby_agent.py
  /Users/macalan/Documents/chatbot/web/backend/app/tasks/scheduler.py
  /Users/macalan/Documents/chatbot/web/backend/app/tasks/notification_sender.py
```

---

### Phase 0 — 快速止血（不依赖其他 Phase，立刻修）

这些 bug 当前直接影响线上可用性，改动小，优先做：

**P0-A `app/tasks/scheduler.py`** — 把 sweep 加入调度

```python
# 在 init_scheduler() 里新增，每小时跑一次
from app.tasks.memory_sweep import run_memory_sweep

scheduler.add_job(
    run_memory_sweep,
    IntervalTrigger(hours=1),
    args=[app_state],
    id="memory_sweep",
    misfire_grace_time=300,
    replace_existing=True,
)
```

**P0-B `app/tasks/memory_sweep.py`**（新建）— 独立 sweep task，避免循环依赖

```python
async def run_memory_sweep(app_state):
    from app.services.memory_agent import run_memory_maintenance
    await run_memory_maintenance(app_state.settings.database_path)
```

**P0-C `app/tasks/standby_agent.py`** — 删除 `chaoxing_assignments_cache` 分支

`_build_context()` 直接查 `chaoxing_memory_entries`（已有 fallback，去掉 `_table_exists` 判断，
保留 `server_reminders` + `chaoxing_memory_entries`，不再查不存在的表）。

---

### Phase 1 — 基础层（新文件，无破坏性）

**P1-A `app/services/memory_models.py`**（新建）

- `sha256_hex(s: str) -> str`
- `key_text(s: str) -> str`（规范化：小写，去标点空白）
- `display_text(s: str) -> str`
- `preview(s: str, limit: int) -> str`
- `parse_iso(s: str | None) -> datetime | None`（返回 UTC-aware）
- `normalize_importance(s: str) -> str`（映射到 high/medium/low，默认 medium）
- `make_assignment_key(course_name: str, title: str) -> str`

**P1-B `app/services/chaoxing_message_filter.py`**（新建）

按 §4 完整实现：
- `ChaoxingTextNormalizer`
- `normalize_message(msg) -> dict`
- `contains_future_cue(text) -> bool`
- `is_pure_chatter(text) -> bool`
- `is_duplicate_assignment_notice(text, assignments) -> bool`
- `load_sync_state(db_path) -> dict`
- `save_sync_state(db_path, result, messages, now)`
- `run(messages, sync_state, assignments, muted_names, now) -> dict`
  - **含 §4.5 时间分级**：1h → 直接保留；24h → 跳过时间检查；7d-30d → 仅留 future cue；>30d → 丢弃

**P1-C `app/services/memory_reducer.py`**（新建）

按 §5 完整实现：
- `canonical_dedupe_key(item, title, summary, messages) -> str`
- `default_expiry(item, messages, now) -> datetime`
- `reduce_memory(extracted, candidates, assignment_keys, now, db_path)`
- `sweep_memory(db_path, now)`（替换现有 `run_memory_maintenance` 逻辑）
- `get_insights(db_path, now, limit=40) -> list[dict]`

---

### Phase 2 — 核心服务重写

**P2-A `app/services/chaoxing_service.py`**（完整重写）

按 §3 逐节实现，对照 Swift 1341 行逐行确认：
- Session 管理（`_probe_session` 宽松策略）
- QR 登录（`create_qr_session` / `poll_qr` / `_finalize_qr_login`）
- 课程列表（mobile UA + `backclazzdata` endpoint）
- 作业列表（HTML 解析 + `parseRelativeTimeString`）
- IM 参数（`im.chaoxing.com/webim/me` regex）
- 对话列表（`getMessageList` POST）
- 漫游消息（EaseMob + suffix fallback）
- **完整 Protobuf 解码器**（`_ProtoReader` 纯手写，不用第三方库）
- 收件箱通知（`notice.chaoxing.com`）
- `adaptive_sync_pass()`：读 `chaoxing_session.last_active_at` 和 `chaoxing_conversation_sync.updated_at` 决定下次间隔（60-600s）

**不改变任何 public 方法签名**。

**P2-B `app/services/memory_agent.py`**（完整重写）

按 §6 重写，接入 P1 的 filter 和 reducer：
1. `load_sync_state()` 从 DB 读 processed ids/fingerprints/initialized_at
2. `chaoxing_svc.fetch_recent_messages()` 拉取消息
3. `chaoxing_svc.fetch_all_pending_assignments()` 获取作业快照
4. `ChaoxingMessageFilter.run()` 过滤（含时间分级）
5. `_extract_with_llm()` 调用 LLM（§6.2 完整 system prompt + §6.3 user payload）
6. `reduce_memory()` 合并到 DB
7. `save_sync_state()` 写回已处理 ids/fingerprints、更新 conversation sync
8. `chaoxing_session.last_active_at` 写入 now

---

### Phase 3 — Agent 层补全

**P3-A `app/services/schedule_agent.py`**（对照补全）

- 替换 `STATIC_SYSTEM_PROMPT`（§7.1 完整版本）
- 新增 `build_dynamic_context(now)` → 注入到每次 run 的 system 消息（§7.2）
- 新增 `build_turn_context(db_path, chaoxing_svc, now)` → 预读快照（§7.3）
- 新增 `orchestrator_plan(user_text)` → 关键词规划（§7.4）
- 新增 `collect_reports(plan, db_path, chaoxing_svc, now)` → 预读报告（§7.5）
- 调整工具循环：max 8 次迭代，parallel `asyncio.gather`，trim 6 对（§7.6）
- `BARE_COMPLETION` 检测（§7.6）
- 工具 `refresh_message_memory` 实际调用 `run_memory_agent()`（当前是死代码）

**P3-B `app/tasks/scheduler.py`** — 完整更新

```python
# 确认所有 job：
# chaoxing_probe  - DateTrigger 自调度（已有）
# deadline_check  - 每 5 分钟（已有）
# daily_summary   - 08:00 cron（已有）
# standby_agent   - 每 15 分钟（已有）
# memory_sweep    - 每 1 小时（P0-A 已加）
```

---

### Phase 3.5 — Scheduled Notifications + LLM 自主调度

> **核心设计**：scheduled_notifications 最大的价值不是"用户指定几点推"，而是
> **LLM 读到新 memory entry 后，自主判断值不值得推、什么时候推最合适**。
> 用户可以配置 rule prompt 作为决策依据；用户也可以显式让 agent 安排推送。
>
> 与 `server_reminders` 的区别：reminders 是任务管理，scheduled_notifications 是推送指令。
> 与 `standby_agent` 的区别：standby 是"现在该不该推"，scheduled 是"提前决定好未来某时推"。

**P3.5-A `database.py`** — 新增表（已加入 `_SCHEMA`）✅

```sql
CREATE TABLE IF NOT EXISTS scheduled_notifications (
    id           TEXT PRIMARY KEY,
    title        TEXT NOT NULL,
    body         TEXT NOT NULL,
    scheduled_at TEXT NOT NULL,   -- ISO-8601，到时间推送
    source_id    TEXT,            -- 关联的 memory_entry/reminder/event id
    source_type  TEXT NOT NULL DEFAULT 'agent',  -- "memory"|"reminder"|"event"|"user"|"rule"
    reason       TEXT,            -- LLM 调度理由（供 notification center 展示）
    created_at   TEXT NOT NULL,
    sent_at      TEXT,
    cancelled_at TEXT
);
CREATE INDEX IF NOT EXISTS idx_sched_notif_fire
    ON scheduled_notifications(scheduled_at)
    WHERE sent_at IS NULL AND cancelled_at IS NULL;
```

新增 `settings` 表 key：
```
notification_rule_prompt  — 用户配置的推送规则 prompt（见 P3.5-B）
```

---

**P3.5-B Notification Rule Prompt（可配置推送规则）**

存在 `settings` 表，key = `notification_rule_prompt`，用户可在设置页编辑。

默认值：
```
你是推送通知调度器。读到新的重要消息或事件后，判断是否值得推送给用户，以及最佳推送时机。

规则：
- 考试/期末/期中变动 → 立即调度一条推送（scheduled_at = now + 5分钟）
- 作业截止在 48 小时内 → 调度在截止前 2 小时推送（若已有 deadline_check 覆盖则跳过）
- 调课/停课/换教室 → 立即调度
- 普通通知/闲聊/已知信息 → 不调度
- 同一事件只调度一次（检查 source_id 是否已存在 scheduled_notifications）
- 夜间（23:00-7:00）不调度，推迟到次日 7:30
```

---

**P3.5-C `app/services/notification_scheduler.py`**（新建）— LLM 自主调度引擎

```python
async def auto_schedule_from_memory(
    new_entries: list[dict],   # 本次 memory_agent 新写入的条目
    db_path: str,
    provider: dict,
    model: str,
    api_key: str,
    now: datetime,
) -> int:
    """
    在每次 memory_agent 跑完后调用。
    LLM 读取新 memory entries + rule prompt，决定要不要 / 何时 schedule 推送。
    返回新创建的 scheduled_notifications 条数。
    """
    rule_prompt = await _get_rule_prompt(db_path)
    existing_source_ids = await _get_existing_source_ids(db_path)  # 防重复调度

    # 过滤掉已调度过的
    to_evaluate = [e for e in new_entries if e["id"] not in existing_source_ids]
    if not to_evaluate:
        return 0

    # 注入当前时间 + 已有 pending 推送（防重叠）
    pending = await _get_pending_scheduled(db_path, now)

    # LLM 判断
    decisions = await _llm_schedule_decision(
        to_evaluate, pending, rule_prompt, provider, model, api_key, now
    )

    # 写入 scheduled_notifications
    count = 0
    for d in decisions:
        if d.get("action") == "schedule":
            await _insert_scheduled(db_path, d, now)
            count += 1
    return count
```

LLM 返回格式：
```json
[
  {
    "action": "schedule",
    "source_id": "memory_entry_id",
    "title": "期末考试时间调整",
    "body": "明天上午10点，教室换到A201",
    "scheduled_at": "2026-05-28T07:30:00+08:00",
    "reason": "重要课程变动，安排晨间提醒"
  },
  {
    "action": "skip",
    "source_id": "xxx",
    "reason": "普通通知，不值得推送"
  }
]
```

---

**P3.5-D 调用时机** — 在 `chaoxing_sync.py` 探针里，memory_agent 跑完后：

```python
result = await run_memory_agent(...)
new_entry_ids = result.get("new_entry_ids", [])  # memory_agent 新写入的条目 ID
if new_entry_ids:
    new_entries = await fetch_memory_entries_by_ids(db_path, new_entry_ids)
    await auto_schedule_from_memory(new_entries, db_path, provider, model, api_key, now)
```

`memory_agent` 需要返回本次新写入的 entry ID 列表（现在只返回 `kept_count`，需补充）。

---

**P3.5-E `app/tasks/notification_sender.py`** — `check_scheduled_notifications()`

每分钟检查到期的 scheduled_notifications，发推，写 `sent_at`。逻辑同原设计，另加：
- 发送前检查是否在静默时段（23:00-7:00），非紧急的延迟到 7:30
- 发送后在 `notification_log` 里写 title/body（供 notification center 展示）

---

**P3.5-F `app/services/schedule_agent.py`** — 用户显式调度工具（三个）

```
schedule_notification(title, body, scheduled_at, reason?)
  → 用户明确说"提醒我 X 点做 Y"时使用
  → 写入 scheduled_notifications，source_type="user"，需确认

cancel_scheduled_notification(id)
  → 取消一条待推送通知，需确认

list_scheduled_notifications()
  → 返回未发送的列表（sent_at IS NULL AND cancelled_at IS NULL）
```

---

**P3.5-G `app/tasks/scheduler.py`** — 新增 job

```python
scheduler.add_job(
    check_scheduled_notifications,
    IntervalTrigger(minutes=1),
    args=[app_state],
    id="scheduled_notifications",
    misfire_grace_time=60,
    replace_existing=True,
)
```

---

**P3.5-H `app/routers/settings.py`** — rule prompt 的读写接口

```
GET  /api/settings/notification-rules  → 返回当前 rule prompt
PUT  /api/settings/notification-rules  → 更新 rule prompt
```

前端设置页加一个 textarea 让用户编辑规则。

---

### Phase 3.6 — Push Delivery State（推送到达确认）

> 现在只知道 push service 接受了请求（HTTP 201），不知道手机是否真正收到。
> 用 Service Worker ping 回后端来确认设备侧收到，standby agent 可据此决定是否重推。

**P3.6-A `database.py`** — 扩展 `notification_log`（`_COLUMN_MIGRATIONS` 里加）

```sql
ALTER TABLE notification_log ADD COLUMN device_received_at TEXT;
ALTER TABLE notification_log ADD COLUMN clicked_at TEXT;
ALTER TABLE notification_log ADD COLUMN dismissed_at TEXT;
```

**P3.6-B `frontend/public/sw.js`** — 三个 ping

```javascript
// push 事件：通知展示后 ping device_received
self.addEventListener("push", (event) => {
  const data = event.data?.json() ?? {};
  const tag = data.tag ?? "default";
  event.waitUntil(
    self.registration.showNotification(data.title ?? "ChatBot", { ...options }).then(() =>
      fetch("/api/push/received", {
        method: "POST",
        headers: { "Content-Type": "application/json" },
        body: JSON.stringify({ tag }),
        keepalive: true,
      }).catch(() => {})
    )
  );
});

// notificationclick：用户点击
self.addEventListener("notificationclick", (event) => {
  const tag = event.notification.data?.tag ?? event.notification.tag;
  fetch("/api/push/clicked", {
    method: "POST", body: JSON.stringify({ tag }), keepalive: true,
  }).catch(() => {});
  // ...原有跳转逻辑不变
});

// notificationclose：用户滑掉（未点击）
self.addEventListener("notificationclose", (event) => {
  const tag = event.notification.data?.tag ?? event.notification.tag;
  fetch("/api/push/dismissed", {
    method: "POST", body: JSON.stringify({ tag }), keepalive: true,
  }).catch(() => {});
});
```

**P3.6-C `app/routers/push.py`**（新建或并入现有 router）

```python
POST /api/push/received   → UPDATE notification_log SET device_received_at=now WHERE item_id=tag
POST /api/push/clicked    → UPDATE notification_log SET clicked_at=now WHERE item_id=tag
POST /api/push/dismissed  → UPDATE notification_log SET dismissed_at=now WHERE item_id=tag
```

所有接口无需鉴权，body 只有 `{tag}`，幂等（`SET x=now WHERE x IS NULL`）。

**P3.6-D `app/tasks/standby_agent.py`** — 利用 delivery state 决定是否重推

```python
# 在 _build_context() 里注入"未到达"状态：
# 查 notification_log WHERE sent_at 在 1 小时内 AND device_received_at IS NULL
# → 加入 context："以下通知已发送但设备未确认收到：..."
# standby 可决定重推

# 去重逻辑改为：
# has_notified() 仅在 device_received_at IS NOT NULL 时才视为"已成功推送"
# device_received_at IS NULL 且超过 30 分钟 → 允许重推（设备可能当时离线）
```

---

### Phase 3.7 — Daily Begin & Daily Summary（每日简报）

> Daily Begin（晨间简报）：替换现有极简 `send_daily_summary`，LLM 生成有温度的今日概览。
> Daily Summary（晚间总结）：新增，睡前回顾今天 + 预告明天，当前完全没有。

**P3.7-A Daily Begin** — 替换 `send_daily_summary()`，改时间为 07:30

上下文（LLM 生成 title + body）：
```
今日课程（server_courses WHERE date = today）
今日截止作业（chaoxing_svc.fetch_all_pending_assignments，filter due 在今天）
今日到期提醒（server_reminders WHERE due_at 在今天）
高重要度 memory entries（前 5 条）
今日 scheduled_notifications（scheduled_at 在今天）
```

System prompt 要求 LLM 输出：
- `title`：15 字以内，如"今天有 3 门课 + 1 个作业截止"
- `body`：50 字以内，重点事项提炼，有温度，不是列表

**P3.7-B Daily Summary** — 新增，22:00 触发

上下文：
```
今日未完成提醒（server_reminders WHERE due_at 在今天 AND is_completed=0）
今日已完成提醒（is_completed=1 AND updated_at 在今天）
明日课程 + 截止作业
未读高重要度 memory（device_received_at IS NULL 或 dismissed_at IS NOT NULL）
```

System prompt 要求：
- `title`：如"今天收尾：还有 2 件事未完成"或"今天完美✓ 明天有期末"
- `body`：简洁总结 + 明日预告

**P3.7-C `app/tasks/scheduler.py`** — 调整时间

```python
# 把 daily_summary 改名为 daily_begin，时间改为 07:30
CronTrigger(hour=7, minute=30)

# 新增 daily_summary（晚间），22:00
scheduler.add_job(
    send_daily_summary_evening,
    CronTrigger(hour=22, minute=0),
    args=[app_state],
    id="daily_summary_evening",
    misfire_grace_time=300,
    replace_existing=True,
)
```

**去重**：`notification_log` 用 `item_id = f"daily-begin-{today}"` / `f"daily-summary-{today}"`，每天各推一次。

---

### Phase 3.8 — Notification Center（前端通知中心）

> 独立第四个 Tab，展示所有推送历史、到达状态、内容，用户可以看到"推了什么、到没到、有没有看"。

**P3.8-A `database.py`** — `notification_log` 补列（`_COLUMN_MIGRATIONS`）

```sql
ALTER TABLE notification_log ADD COLUMN title TEXT;
ALTER TABLE notification_log ADD COLUMN body TEXT;
-- device_received_at / clicked_at / dismissed_at 已在 P3.6 加过
```

所有发推送的地方（`push_service.py`、`notification_sender.py`、`standby_agent.py`）在调
`log_notification_sent()` 时顺带传 `title` / `body`，存入 log。

**P3.8-B `app/routers/push.py`** — 新增列表接口

```
GET /api/notifications?limit=50&offset=0
→ 返回 notification_log 倒序列表：
  [{id, item_id, notif_type, title, body, sent_at,
    device_received_at, clicked_at, dismissed_at}]

DELETE /api/notifications/{id}   → 软删除（加 deleted_at 列）或硬删除
DELETE /api/notifications        → 清空全部历史
```

**P3.8-C `frontend/src/components/notifications/`**（新建目录）

```
NotificationCenter.jsx     — 主页面，列表 + 筛选
NotificationItem.jsx       — 单条通知卡片
NotificationBadge.jsx      — Tab 上的未读红点
```

**卡片内容**：
```
[类型图标] 标题                              时间
正文摘要
状态：✅ 已送达  👆 已点击  / ⏳ 未确认到达  / 👋 已忽略
```

类型图标：📋 deadline / 🔔 standby / ⏰ scheduled / ☀️ daily_begin / 🌙 daily_summary

**未读红点逻辑**：`sent_at` 在最近 24h 内 AND `clicked_at IS NULL` 的条数 > 0 → 红点。

**P3.8-D `frontend/src/App.jsx`** — 加第四个 Tab

```jsx
// 现有三个 Tab：overview / agent / settings
// 新增：
{ id: "notifications", label: "通知", icon: Bell }

// 主内容区加：
<div className={tab !== "notifications" ? "hidden" : "h-full"}>
  <NotificationCenter />
</div>
```

底部移动端 TabBar 和桌面端右上角 Tab 同步加第四个按钮，带未读红点。

**P3.8-E `frontend/public/sw.js`** — tag 透传到 data

P3.6 的 ping 用 `tag` 作为 key 匹配 `notification_log.item_id`，需确保发推时 `data.tag` 和 `item_id` 一致（现在已是如此，确认不变）。

---

### Phase 3.9 — 全流程逻辑修复（Bugfix Pass）

> 宏观审查发现的逻辑漏洞，不依赖其他 Phase，可穿插进行。

**BUG-1 作业通知重复推送** — `deadline_check` 与 `standby_agent` 互不感知

`deadline_check` 用 `assignment["id"] + "deadline_1h"` 去重，
`standby_agent` 读 memory_entries 用 `entry_id + "standby_agent"` 去重，
同一作业可能被两个系统各推一次。

修法：`standby_agent._build_context()` 里额外注入今日已由 `deadline_check` 推过的 assignment ID，
system prompt 明确告知 LLM 跳过这些条目。

```python
# 在 _build_context() 里加：
notified_today = await db.execute("""
    SELECT item_id FROM notification_log
    WHERE notif_type IN ('deadline_1h','deadline_24h')
    AND sent_at >= date('now')
""")
# 注入 context：【今日已由系统推送的作业，请勿重复】...
```

---

**BUG-2 Memory entries 无 `expires_at` 永不 sweep**

LLM 经常不填 `expires_at`，值为 NULL，`sweep_memory` 跳过它们，数据永久积累。

修法：`reduce_memory()` 写入时，若 `expires_at` 为 NULL，用 `default_expiry()` 补填
（`sent_at + 14天`）；`run_memory_maintenance()` 里加兜底：
```sql
-- 超过 90 天且 expires_at 仍为 NULL 的条目直接归档
UPDATE chaoxing_memory_entries SET archived_at=?
WHERE expires_at IS NULL AND archived_at IS NULL
AND julianday('now') - julianday(extracted_at) > 90
```

---

**BUG-3 Pending mutation 单槽覆盖**

`schedule_pending_mutation` 是 settings 表的单个 key，多步操作时后者覆盖前者。

修法：key 改为 UUID，`_store_pending_mutation()` 返回 mutation_id，
assistant 回复里携带 mutation_id，用户确认时带上 ID，精确匹配。

```python
mutation_id = str(uuid.uuid4())
await _set_setting(db_path, f"pending_mutation_{mutation_id}", json.dumps({...}))
# assistant 回复："确认创建提醒《XXX》吗？[mutation:mutation_id]"
# execute_confirmed 解析回复里的 mutation_id，精确取出执行
```

---

**BUG-4 `refresh_chaoxing_memory` 是死代码**

`schedule_agent` 里该工具只返回字符串，没有触发任何操作。

修法：
```python
elif tc.name == "refresh_chaoxing_memory":
    from .provider_registry import resolve_provider
    from app.services.memory_agent import run_memory_agent
    provider, api_key = await resolve_provider(...)
    result = await run_memory_agent(chaoxing_svc, db_path, provider, model, api_key)
    return f"已刷新：处理 {result['candidate_count']} 条候选，提取 {result['kept_count']} 条记忆。"
```

---

**BUG-5 Chaoxing session 过期无告警**

Session 失效后系统静默停止工作，用户不知道。

修法：`chaoxing_sync.py` 探针里，检测到 `is_logged_in=False` 时：
```python
if not app_state.chaoxing_svc.is_logged_in:
    # 推送一条告警，每 6 小时最多一次
    if not await has_notified(db_path, "session_expired", "session_alert_6h"):
        await send_push_to_all_subscribers(db_path,
            title="⚠️ 学习通会话已过期",
            body="请打开 App 重新扫码登录，否则消息同步已停止。")
        await log_notification_sent(db_path, "session_expired", "session_alert_6h")
```
注意：`session_alert_6h` 这个 notif_type 需要在 `has_notified` 逻辑里支持时间窗口去重（6h TTL），而不是永久去重。

---

**BUG-6 `/memory/sync` 硬编码 OpenAI**

`routers/chaoxing.py` 第 91-94 行写死了 OpenAI provider 和 `settings.openai_api_key`。

修法：改用 `resolve_provider()`，与其他地方保持一致。

---

**BUG-7 Daily summary/begin key 冲突**

`send_daily_summary` 去重 key 是 `f"daily-{today}"`，
新增 daily_summary_evening 后两者 key 不同即可，但需明确区分：
- Daily Begin：`f"daily-begin-{today}"`
- Daily Summary Evening：`f"daily-summary-{today}"`

---

**BUG-8 `max_iterations` 应为 8**

`schedule_agent.py:52` 写的是 12，对照 Swift spec 应为 8。直接改。

---

**BUG-9 SW `notificationclick` 里 tag 取值路径错误**

```javascript
// 现在：
const data = event.notification.data ?? {};   // data 是 {type, id, ...}
// P3.6 ping 用的是 tag，应取：
const tag = event.notification.tag;  // 直接取 notification.tag，不从 data 取
```

P3.6 实现时确保 SW 三个 ping 都用 `event.notification.tag`。

---

**BUG-10 Schedule agent 对话历史无上限、无摘要**

`trimmed_history = history[-(20 * 2):]` 保留最近 40 条消息但不压缩，
长期使用后 token 持续增长。

修法（简单版）：超过 30 条时，先用 LLM 对前面的消息做一次摘要，
存入 `schedule_messages` 的一条 `role="system"` 摘要消息，替换掉原来那批消息。
复杂版参考 `conversations.context_summary` 字段的处理方式。

---

### Phase 4 — 验证

```bash
cd /Users/macalan/Documents/chatbot/web/backend

# 1. import 检查
python -c "
from app.services.memory_models import sha256_hex, key_text, parse_iso
from app.services.chaoxing_message_filter import ChaoxingMessageFilter, ChaoxingTextNormalizer, run as filter_run
from app.services.memory_reducer import reduce_memory, sweep_memory, get_insights
from app.services.memory_agent import run_memory_agent
from app.services.schedule_agent import run_schedule_agent, orchestrator_plan, build_dynamic_context
from app.tasks.memory_sweep import run_memory_sweep
print('All imports OK')
"

# 2. filter 单元测试（无需网络）
python -c "
from app.services.chaoxing_message_filter import ChaoxingTextNormalizer, contains_future_cue, is_pure_chatter
assert is_pure_chatter('好的') == True
assert is_pure_chatter('明天上课') == False
assert contains_future_cue('下周一截止') == True
assert contains_future_cue('哈哈') == False
print('Filter unit tests OK')
"

# 3. DB migration 验证
python -c "
import asyncio, aiosqlite
async def check():
    async with aiosqlite.connect('/tmp/test_migration.db') as db:
        from app.database import run_migrations
        await run_migrations('/tmp/test_migration.db')
        tables = [r[0] for r in await (await db.execute(\"SELECT name FROM sqlite_master WHERE type='table'\")).fetchall()]
        assert 'chaoxing_processed_fingerprints' in tables
        assert 'chaoxing_conversation_sync' in tables
        cols = [r[1] for r in await (await db.execute('PRAGMA table_info(chaoxing_session)')).fetchall()]
        assert 'last_active_at' in cols
        cols2 = [r[1] for r in await (await db.execute('PRAGMA table_info(chaoxing_memory_entries)')).fetchall()]
        assert 'dedupe_key' in cols2
        assert 'confidence' in cols2
        print('DB migration OK, tables:', sorted(tables))
asyncio.run(check())
"
```

---

### 约束条件（全 Phase 通用）

- **不引入新 pip 依赖**：Protobuf 解码器纯手写，不用 `protobuf` 库
- **不改变 public 方法签名**：routers 和 tasks 直接调用，签名变了会 500
- **时区**：全部用 `datetime.now(timezone.utc)`，存 DB 用 `.isoformat()`
- **错误处理**：网络请求一律 `try/except`，失败返回 `[]` 不抛出（对照 Swift `try?`）
- **日志**：`logging.getLogger("chaoxing")` / `logging.getLogger("memory_agent")`，不用 print
- **幂等**：所有 DB 操作 `INSERT OR IGNORE` / `INSERT OR REPLACE`，重启安全
