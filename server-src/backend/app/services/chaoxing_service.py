"""
Chaoxing (超星学习通) HTTP client.
Full port of ChaoxingService.swift — courses, assignments, IM messages.
"""
from __future__ import annotations

import asyncio
import base64
import json
import logging
import random
import re
import time
import zoneinfo
from datetime import datetime, timedelta, timezone
from typing import Optional
from urllib.parse import unquote

import aiosqlite
import httpx

log = logging.getLogger("chaoxing")

CHAOXING_MOBILE_UA = (
    "Mozilla/5.0 (Linux; Android 12; MI10) AppleWebKit/537.36 "
    "(KHTML, like Gecko) Chrome/108.0.0.0 Mobile Safari/537.36 "
    "com.chaoxing.mobile/ChaoXingStudy_3_6.7.2_android_phone_10831_263"
)
CHAOXING_DESKTOP_UA = (
    "Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/537.36 "
    "(KHTML, like Gecko) Chrome/120.0.0.0 Safari/537.36"
)
CHAOXING_BASE_URL = "https://passport2.chaoxing.com"


# ---------------------------------------------------------------------------
# Minimal Protobuf reader  (port of Swift ProtoReader)
# ---------------------------------------------------------------------------

class _ProtoError(Exception):
    pass


class _ProtoReader:
    def __init__(self, data: bytes):
        self._buf = data
        self._pos = 0

    def next_field(self) -> tuple[int, int] | None:
        if self._pos >= len(self._buf):
            return None
        key = self._read_varint()
        return (int(key >> 3), int(key & 0x07))

    def _read_varint(self) -> int:
        result = 0
        shift = 0
        while self._pos < len(self._buf):
            byte = self._buf[self._pos]
            self._pos += 1
            result |= (byte & 0x7F) << shift
            if not (byte & 0x80):
                return result
            shift += 7
        raise _ProtoError("Truncated varint")

    def read_varint(self) -> int:
        return self._read_varint()

    def read_length_delimited(self) -> bytes:
        length = self._read_varint()
        if length < 0 or self._pos + length > len(self._buf):
            raise _ProtoError("Truncated length-delimited field")
        data = self._buf[self._pos: self._pos + length]
        self._pos += length
        return bytes(data)

    def read_string(self) -> str:
        data = self.read_length_delimited()
        for enc in ("utf-8", "gb18030", "gbk", "big5", "latin-1"):
            try:
                return data.decode(enc)
            except Exception:
                continue
        return data.decode("utf-8", errors="replace")

    def skip(self, wire_type: int) -> None:
        if wire_type == 0:
            self._read_varint()
        elif wire_type == 1:
            if self._pos + 8 > len(self._buf):
                raise _ProtoError("Truncated 64-bit field")
            self._pos += 8
        elif wire_type == 2:
            self.read_length_delimited()
        elif wire_type == 5:
            if self._pos + 4 > len(self._buf):
                raise _ProtoError("Truncated 32-bit field")
            self._pos += 4
        else:
            raise _ProtoError(f"Unknown wire type: {wire_type}")


def _decode_meta(data: bytes) -> dict:
    r = _ProtoReader(data)
    meta: dict = {"id": "", "from": None, "timestamp": 0, "payload": b""}
    while (f := r.next_field()) is not None:
        num, wt = f
        if num == 1:
            meta["id"] = str(r.read_varint())
        elif num == 2:
            meta["from"] = _decode_jid(r.read_length_delimited())
        elif num == 4:
            meta["timestamp"] = r.read_varint()
        elif num == 6:
            meta["payload"] = r.read_length_delimited()
        else:
            r.skip(wt)
    return meta


def _decode_jid(data: bytes) -> dict:
    r = _ProtoReader(data)
    jid = {"name": ""}
    while (f := r.next_field()) is not None:
        num, wt = f
        if num == 2:
            jid["name"] = r.read_string()
        else:
            r.skip(wt)
    return jid


def _decode_kv(data: bytes) -> tuple[str, str]:
    r = _ProtoReader(data)
    key = value = ""
    while (f := r.next_field()) is not None:
        num, wt = f
        if num == 1:
            key = r.read_string()
        elif num == 6:
            value = r.read_string()
        else:
            r.skip(wt)
    return key, value


def _decode_content(data: bytes) -> dict:
    r = _ProtoReader(data)
    c = {"raw_type": 0, "text": "", "display_name": "", "remote_path": "", "action": "", "custom_event": ""}
    while (f := r.next_field()) is not None:
        num, wt = f
        if num == 1:
            c["raw_type"] = r.read_varint()
        elif num == 2:
            c["text"] = r.read_string()
        elif num == 6:
            c["display_name"] = r.read_string()
        elif num == 7:
            c["remote_path"] = r.read_string()
        elif num == 10:
            c["action"] = r.read_string()
        elif num == 19:
            c["custom_event"] = r.read_string()
        else:
            r.skip(wt)
    return c


def _decode_body(data: bytes) -> dict:
    r = _ProtoReader(data)
    body: dict = {"raw_type": 0, "from": None, "contents": [], "ext": {}}
    while (f := r.next_field()) is not None:
        num, wt = f
        if num == 1:
            body["raw_type"] = r.read_varint()
        elif num == 2:
            body["from"] = _decode_jid(r.read_length_delimited())
        elif num == 4:
            body["contents"].append(_decode_content(r.read_length_delimited()))
        elif num == 5:
            k, v = _decode_kv(r.read_length_delimited())
            if k and v:
                body["ext"][k] = v
        else:
            r.skip(wt)
    return body


def _content_display(c: dict) -> str:
    text = c["text"].strip()
    if text:
        return text
    name = c["display_name"].strip()
    rt = c["raw_type"]
    if rt == 1:
        return f"[图片] {name}" if name else "[图片]"
    if rt == 2:
        return f"[视频] {name}" if name else "[视频]"
    if rt == 4:
        return f"[语音] {name}" if name else "[语音]"
    if rt == 5:
        return f"[文件] {name}" if name else "[文件]"
    if rt == 6:
        return f"[命令] {c['action']}" if c["action"] else "[命令消息]"
    if rt == 7:
        return f"[自定义] {c['custom_event']}" if c["custom_event"] else "[自定义消息]"
    return ""


def _first_nonempty(*args) -> str | None:
    for v in args:
        if v and str(v).strip():
            return str(v).strip()
    return None


def _decode_roaming_message(
    encoded: str,
    conversation: dict,
    raw_sender_uid: str | None = None,
    raw_sender_name: str | None = None,
    raw_msg_time_ms: float | None = None,
) -> dict | None:
    """Port of Swift decodeRoamingMessage. Returns None if undecipherable."""

    def make_ts() -> datetime:
        if raw_msg_time_ms:
            return datetime.fromtimestamp(raw_msg_time_ms / 1000, tz=timezone.utc)
        return datetime.now(tz=timezone.utc)

    # --- Fast path: short strings that might be plain text ---
    plain_text: str | None = None
    if len(encoded) < 256:
        try:
            decoded_bytes = base64.b64decode(encoded)
            try:
                t = decoded_bytes.decode("utf-8").strip()
                # Looks like plain text (no binary control chars)?
                if t and all(ord(ch) >= 32 or ch in "\t\n\r" for ch in t):
                    plain_text = t
            except Exception:
                pass
        except Exception:
            # Not valid base64 — treat raw string as plain text
            t = encoded.strip()
            if t:
                plain_text = t

    # --- Normal Protobuf path ---
    try:
        meta_bytes = base64.b64decode(encoded)
        meta = _decode_meta(meta_bytes)
    except Exception:
        # Fall back to plain text if available
        if plain_text and raw_sender_uid:
            ts = make_ts()
            return {
                "id": f"{conversation['id']}-{int(ts.timestamp() * 1000)}-{raw_sender_uid}",
                "conversation_id": conversation["id"],
                "conversation_name": conversation["name"],
                "is_group": conversation["is_group"],
                "sender_id": raw_sender_uid,
                "sender_name": raw_sender_name,
                "sent_at": ts.isoformat(),
                "type": "TEXT",
                "text": plain_text,
                "image_urls": None,
            }
        return None

    # Payload might be double-base64-encoded
    payload = meta["payload"]
    try:
        payload_str = payload.decode("utf-8")
        double = base64.b64decode(payload_str)
        payload = double
    except Exception:
        pass

    try:
        body = _decode_body(payload)
    except Exception:
        if plain_text and raw_sender_uid:
            ts = make_ts()
            return {
                "id": f"{conversation['id']}-{int(ts.timestamp() * 1000)}-{raw_sender_uid}",
                "conversation_id": conversation["id"],
                "conversation_name": conversation["name"],
                "is_group": conversation["is_group"],
                "sender_id": raw_sender_uid,
                "sender_name": raw_sender_name,
                "sent_at": ts.isoformat(),
                "type": "TEXT",
                "text": plain_text,
                "image_urls": None,
            }
        return None

    parts = [_content_display(c) for c in body["contents"]]
    parts = [p for p in parts if p]
    text = "\n".join(parts).strip()
    if not text:
        return None

    sender_id = _first_nonempty(
        body["from"]["name"] if body.get("from") else None,
        meta["from"]["name"] if meta.get("from") else None,
        raw_sender_uid,
    ) or "unknown"

    sender_name = _first_nonempty(
        raw_sender_name,
        body["ext"].get("fromName"),
        body["ext"].get("fromNickName"),
        body["ext"].get("nickname"),
        body["ext"].get("realName"),
    )

    if meta["timestamp"] > 0:
        sent_at = datetime.fromtimestamp(meta["timestamp"] / 1000, tz=timezone.utc)
    elif raw_msg_time_ms:
        sent_at = datetime.fromtimestamp(raw_msg_time_ms / 1000, tz=timezone.utc)
    else:
        sent_at = datetime.now(tz=timezone.utc)

    msg_id = meta["id"] if meta["id"] else f"{conversation['id']}-{meta['timestamp']}-{sender_id}"
    image_urls = [c["remote_path"] for c in body["contents"] if c["raw_type"] == 1 and c["remote_path"]] or None

    return {
        "id": msg_id,
        "conversation_id": conversation["id"],
        "conversation_name": conversation["name"],
        "is_group": conversation["is_group"],
        "sender_id": sender_id,
        "sender_name": sender_name,
        "sent_at": sent_at.isoformat(),
        "type": "TEXT",
        "text": text,
        "image_urls": image_urls,
    }


# ---------------------------------------------------------------------------
# HTML parsing helpers
# ---------------------------------------------------------------------------

_LI_RX = re.compile(
    r'<li\s+onclick="goTask\(this\);"[^>]*data1="(\d+)"[^>]*>([\s\S]*?)</li>',
    re.DOTALL,
)
_TITLE_RX = re.compile(r"<p>([^<]+)</p>")
_STATUS_RX = re.compile(r"<span>([^<]+)</span>")
_TIME_RX = re.compile(r'<span\s+class="fr">([^<]+)</span>')
_HTML_ID_RX_CACHE: dict[str, re.Pattern] = {}


def _html_id_value(html: str, elem_id: str) -> str | None:
    if elem_id not in _HTML_ID_RX_CACHE:
        _HTML_ID_RX_CACHE[elem_id] = re.compile(
            r'id="' + re.escape(elem_id) + r'"[^>]*>([^<]*)'
        )
    m = _HTML_ID_RX_CACHE[elem_id].search(html)
    v = m.group(1).strip() if m else None
    return v or None


def _parse_relative_time(s: str) -> str | None:
    if not s:
        return None
    if any(x in s for x in ("已过期", "已截止", "已超时")):
        return datetime.now(tz=timezone.utc).isoformat()
    seconds = 0
    if m := re.search(r"(\d+)天", s):
        seconds += int(m.group(1)) * 86400
    if m := re.search(r"(\d+)小时", s):
        seconds += int(m.group(1)) * 3600
    if m := re.search(r"(\d+)分钟", s):
        seconds += int(m.group(1)) * 60
    if seconds > 0:
        return datetime.fromtimestamp(
            datetime.now(tz=timezone.utc).timestamp() + seconds, tz=timezone.utc
        ).isoformat()
    return None


def _status_label(raw: str) -> str:
    if raw in ("0", "未做"):
        return "未提交"
    if raw in ("1", "已做"):
        return "已提交"
    if raw in ("2", "已截止"):
        return "已截止"
    return raw if raw else "未提交"


def _parse_assignments_html(html: str, course_id: str, course_name: str) -> list[dict]:
    if "暂无作业" in html or 'class="empty"' in html:
        return []
    assignments = []
    for m in _LI_RX.finditer(html):
        task_id = m.group(1)
        block = m.group(2)
        tm = _TITLE_RX.search(block)
        title = tm.group(1).strip() if tm else "(作业)"
        sm = _STATUS_RX.search(block)
        status_raw = sm.group(1).strip() if sm else ""
        tr = _TIME_RX.search(block)
        time_str = tr.group(1).strip() if tr else ""
        assignments.append({
            "id": task_id,
            "courseId": course_id,
            "courseName": course_name,
            "title": title,
            "dueDate": _parse_relative_time(time_str),
            "status": _status_label(status_raw),
            "type": "作业",
            "remainingTime": time_str,
        })
    return assignments


# ---------------------------------------------------------------------------
# Signal-driven sync cadence (P1) — replaces the hard-coded interval ladder.
# Pure function so it is unit-testable; thresholds live here, not scattered
# across branches.
# ---------------------------------------------------------------------------

def _min_minutes_to_due(assignments: list[dict], now: datetime) -> float | None:
    """Minutes until the nearest *future* assignment deadline, or None."""
    best: float | None = None
    for a in assignments or []:
        due_str = a.get("dueDate") or a.get("due_date")
        if not due_str:
            continue
        try:
            due = datetime.fromisoformat(str(due_str).replace("Z", "+00:00"))
        except (ValueError, TypeError):
            continue
        if due.tzinfo is None:
            due = due.replace(tzinfo=timezone.utc)
        mins = (due - now).total_seconds() / 60.0
        if mins > 0 and (best is None or mins < best):
            best = mins
    return best


def _dingtalk_active(window_minutes: int = 10) -> bool:
    """True if the DingTalk WAL was written within the last `window_minutes`."""
    import os
    wal_path = os.getenv("DINGTALK_WAL_PATH", "/dingtalk_db/dingtalk.db-wal")
    try:
        age = time.time() - os.path.getmtime(wal_path)
        return age < window_minutes * 60
    except OSError:
        return False


def compute_sync_interval(
    *,
    changed: int,
    consecutive_no_change: int,
    now_local: datetime,
    imminent_deadline_min: float | None,
    dingtalk_active: bool,
    urgent_recent_memory: bool,
) -> float:
    """Decide the next Chaoxing sync interval (seconds) from current signals.

    Priority: hard acceleration > night back-off > activity-follow > idle ladder.
    """
    hour = now_local.hour
    night = hour >= 23 or hour < 7

    # 1) Hard acceleration — something time-critical is happening right now.
    if imminent_deadline_min is not None and imminent_deadline_min <= 60:
        return 45.0
    if urgent_recent_memory:
        return 45.0

    # 2) Night back-off — don't burn cycles at 3am unless a deadline is close.
    if night:
        if imminent_deadline_min is not None and imminent_deadline_min <= 180:
            return 120.0
        return 900.0

    # 3) Activity-follow — recent change in messages or DingTalk → poll tighter.
    if changed > 0:
        return random.uniform(45, 90)
    if dingtalk_active:
        return random.uniform(60, 120)

    # 4) Idle back-off ladder — the longer nothing changes, the slower we poll.
    if consecutive_no_change >= 12:
        return 600.0
    if consecutive_no_change >= 8:
        return 300.0
    if consecutive_no_change >= 4:
        return 180.0
    if consecutive_no_change >= 2:
        return 120.0
    return 90.0


# ---------------------------------------------------------------------------
# ChaoxingService
# ---------------------------------------------------------------------------

class ChaoxingService:
    """Singleton. Initialize once in FastAPI lifespan."""

    ASSIGNMENT_CACHE_TTL = 300  # 5 minutes

    def __init__(self, db_path: str):
        self.db_path = db_path
        self._client: Optional[httpx.AsyncClient] = None
        self.is_logged_in = False
        self.uid: Optional[str] = None
        self.username: Optional[str] = None
        self._qr_client: Optional[httpx.AsyncClient] = None
        self._assignment_cache: list = []
        self._assignment_cache_at: Optional[datetime] = None

    # ------------------------------------------------------------------
    # Init & session persistence
    # ------------------------------------------------------------------

    async def init(self):
        """Load persisted session from DB on startup."""
        async with aiosqlite.connect(self.db_path) as db:
            row = await (await db.execute(
                "SELECT cookies_json, uid, username FROM chaoxing_session WHERE id=1"
            )).fetchone()
            if row and row[0]:
                cookies = json.loads(row[0])
                self._client = self._make_client(cookies)
                self.uid = row[1]
                self.username = row[2]
                # Lenient: trust stored session; only invalidate on explicit auth failure
                self.is_logged_in = await self._probe_session()
                log.info(f"Chaoxing session loaded (uid={self.uid}, logged_in={self.is_logged_in})")

    @staticmethod
    def _extract_cookies(client: httpx.AsyncClient) -> dict:
        """Safely extract cookies from a client, handling duplicate names (e.g. JSESSIONID).

        httpx raises CookieConflict when multiple cookies share a name across paths/domains.
        We iterate the underlying CookieJar directly to avoid that.
        """
        result: dict = {}
        try:
            for cookie in client.cookies.jar:
                # For duplicates keep the root-path or broadest cookie; last-seen wins
                result[cookie.name] = cookie.value
        except Exception as e:
            log.warning(f"cookie extraction fallback: {e}")
        return result

    def _make_client(self, cookies: dict) -> httpx.AsyncClient:
        return httpx.AsyncClient(
            cookies=cookies,
            headers={"User-Agent": CHAOXING_DESKTOP_UA},
            follow_redirects=True,
            timeout=httpx.Timeout(20.0),
        )

    def _make_client_from_jar(self, source: httpx.AsyncClient) -> httpx.AsyncClient:
        """Create a new main client that inherits the full cookie jar from a QR client."""
        new_client = httpx.AsyncClient(
            headers={"User-Agent": CHAOXING_DESKTOP_UA},
            follow_redirects=True,
            timeout=httpx.Timeout(20.0),
        )
        # Copy every cookie from the source jar, including duplicates
        for cookie in source.cookies.jar:
            new_client.cookies.jar.set_cookie(cookie)
        return new_client

    def _make_qr_client(self) -> httpx.AsyncClient:
        return httpx.AsyncClient(
            headers={"User-Agent": CHAOXING_DESKTOP_UA},
            follow_redirects=True,
            timeout=httpx.Timeout(20.0),
        )

    async def _probe_session(self) -> bool:
        """Probe session — only invalidate on confirmed not-logged-in; keep session on any error."""
        if not self._client:
            return False
        try:
            resp = await self._client.get(
                "https://passport2.chaoxing.com/api/check?islogin=1",
                timeout=10.0,
            )
            try:
                data = resp.json()
                logged_in = bool(data.get("isLogin", False))
                if logged_in and data.get("uid"):
                    # Refresh uid from live check
                    self.uid = str(data["uid"])
                log.info(f"Chaoxing probe: isLogin={logged_in} uid={self.uid}")
                return logged_in
            except Exception:
                # Non-JSON response — probe with a real authenticated endpoint
                log.warning(f"Chaoxing probe: non-JSON response (HTTP {resp.status_code}), trying courses probe")
                return await self._probe_with_courses()
        except (httpx.NetworkError, httpx.TimeoutException):
            log.warning("Chaoxing probe: network error, keeping stored session")
            return self.uid is not None
        except Exception as e:
            log.warning(f"Chaoxing probe unexpected error: {e}, keeping stored session")
            return self.uid is not None

    async def _probe_with_courses(self) -> bool:
        """Secondary probe: try fetching course list. If it redirects to login, session is dead."""
        if not self._client:
            return False
        try:
            resp = await self._client.get(
                "https://mooc1.chaoxing.com/visit/courses/list?rss=1&page=1&pageSize=1",
                timeout=10.0,
            )
            ct = resp.headers.get("content-type", "")
            if "json" in ct:
                return True
            if resp.url and "login" in str(resp.url).lower():
                log.warning("Chaoxing secondary probe: redirected to login, session dead")
                self.is_logged_in = False
                return False
            return self.uid is not None
        except Exception:
            return self.uid is not None

    async def _persist_session(self, cookies: dict, uid: str | None, username: str | None):
        now_iso = datetime.now(timezone.utc).isoformat()
        async with aiosqlite.connect(self.db_path) as db:
            await db.execute(
                "INSERT OR REPLACE INTO chaoxing_session "
                "(id, cookies_json, uid, username, phone, logged_in_at, last_active_at, updated_at) "
                "VALUES (1,?,?,?,?,?,?,?)",
                (json.dumps(cookies), uid, username, "", now_iso, now_iso, now_iso),
            )
            await db.commit()

    # ------------------------------------------------------------------
    # QR login
    # ------------------------------------------------------------------

    async def create_qr_session(self) -> dict:
        if self._qr_client:
            await self._qr_client.aclose()
        self._qr_client = self._make_qr_client()
        await self._qr_client.get(f"{CHAOXING_BASE_URL}/login")
        refresh = await self._qr_client.post(
            f"{CHAOXING_BASE_URL}/refreshQRCode",
            headers={"Referer": f"{CHAOXING_BASE_URL}/login"},
        )
        data = refresh.json()
        uuid = data.get("uuid")
        enc = data.get("enc")
        if not uuid or not enc:
            raise ValueError(f"bad QR response: {data}")
        image = await self._qr_client.get(
            f"{CHAOXING_BASE_URL}/createqr",
            params={"uuid": uuid, "fid": "-1"},
            headers={"Referer": f"{CHAOXING_BASE_URL}/login"},
        )
        image.raise_for_status()
        return {
            "uuid": uuid,
            "enc": enc,
            "image_data_url": "data:image/png;base64," + base64.b64encode(image.content).decode(),
        }

    async def poll_qr(self, uuid: str, enc: str) -> dict:
        if not self._qr_client:
            return {"status": "failed", "message": "QR session not found"}
        resp = await self._qr_client.post(
            f"{CHAOXING_BASE_URL}/getauthstatus/v2",
            data={"uuid": uuid, "enc": enc, "doubleFactorLogin": "0", "forbidotherlogin": "0"},
            headers={"Referer": f"{CHAOXING_BASE_URL}/login"},
        )
        data = resp.json()
        log.info(f"[QR] poll response: {data}")
        # Chaoxing may return status=True (bool) or status=1 (int)
        status_val = data.get("status")
        if status_val is True or status_val == 1:
            login_url = data.get("loginUrl") or data.get("moocLoginUrl") or data.get("url")
            try:
                await self._finalize_qr_login(login_url)
                return {"status": "confirmed"}
            except Exception as e:
                log.error(f"[QR] finalize failed: {e}", exc_info=True)
                return {"status": "failed", "message": str(e)}
        qr_type = data.get("type")
        if qr_type == 4:
            return {"status": "scanned"}
        elif qr_type in (6, 7):
            return {"status": "expired"}
        else:
            return {"status": "waiting"}

    async def _finalize_qr_login(self, login_url: str | None = None):
        client = self._qr_client
        if not client:
            raise RuntimeError("QR client missing")

        # Follow the confirmation redirect if provided — this is what gives us session cookies
        if login_url:
            log.info(f"[QR] following loginUrl: {login_url}")
            try:
                await client.get(login_url)
            except Exception as e:
                log.warning(f"[QR] loginUrl follow error: {e}")

        # Also try the MOOC space index to propagate cookies cross-domain
        for url in (
            "https://i.mooc.chaoxing.com/space/index",
            "http://i.mooc.chaoxing.com/space/index",
        ):
            try:
                await client.get(url, timeout=8.0)
                break
            except Exception:
                pass

        # Fetch SSO profile to get username
        username = self.username
        try:
            resp = await client.get(
                "https://sso.chaoxing.com/apis/login/userLogin4Uname.do",
                timeout=10.0,
            )
            log.info(f"[QR] SSO status={resp.status_code} body={resp.text[:200]}")
            sso_data = resp.json()
            if sso_data.get("result") and isinstance(sso_data.get("msg"), dict):
                username = sso_data["msg"].get("name") or username
        except Exception as e:
            log.warning(f"[QR] SSO profile fetch failed: {e}")

        # Use jar-copy client (preserves duplicate cookies like JSESSIONID)
        self._client = self._make_client_from_jar(client)

        # Extract a flat dict for persistence and uid lookup (duplicates → last value wins)
        cookies = self._extract_cookies(client)
        log.info(f"[QR] cookies after finalize: {list(cookies.keys())}")
        uid = cookies.get("_uid") or cookies.get("UID") or cookies.get("uid")
        if not uid:
            # Try to get uid via the check API (use the new main client, not qr_client)
            try:
                check = await self._client.get(
                    "https://passport2.chaoxing.com/api/check?islogin=1",
                    timeout=8.0,
                )
                check_data = check.json()
                log.info(f"[QR] check response: {check_data}")
                if check_data.get("isLogin"):
                    uid = str(check_data.get("uid") or check_data.get("UID") or "")
            except Exception as e:
                log.warning(f"[QR] check API failed: {e}")

        self.is_logged_in = True
        self.uid = uid
        self.username = username or uid
        await self._persist_session(cookies, uid, self.username)
        log.info(f"[QR] login finalized uid={uid} username={self.username}")

    async def logout(self):
        self.is_logged_in = False
        self._client = None
        self.uid = None
        self.username = None
        async with aiosqlite.connect(self.db_path) as db:
            await db.execute("DELETE FROM chaoxing_session WHERE id=1")
            await db.commit()

    # ------------------------------------------------------------------
    # Phone OTP login (secondary method)
    # ------------------------------------------------------------------

    async def request_otp(self, phone: str) -> bool:
        async with httpx.AsyncClient(
            headers={"User-Agent": CHAOXING_MOBILE_UA}, follow_redirects=True
        ) as client:
            resp = await client.post(
                "https://passport2.chaoxing.com/mlogin/phoneLoginV2",
                data={"phone": phone, "type": "1"},
            )
            return resp.json().get("status", False)

    async def verify_otp(self, phone: str, code: str) -> bool:
        async with httpx.AsyncClient(
            headers={"User-Agent": CHAOXING_MOBILE_UA}, follow_redirects=True
        ) as client:
            resp = await client.post(
                "https://passport2.chaoxing.com/mlogin/phoneLoginV2",
                data={"phone": phone, "code": code, "type": "2"},
            )
            data = resp.json()
            if not data.get("status"):
                return False
            cookies = dict(client.cookies)
            uid = cookies.get("_uid") or cookies.get("UID")
            self._client = self._make_client(cookies)
            self.is_logged_in = True
            self.uid = uid
            self.username = phone
            await self._persist_session(cookies, uid, phone)
            return True

    # ------------------------------------------------------------------
    # Courses  (correct API: backclazzdata with mobile UA)
    # ------------------------------------------------------------------

    async def fetch_courses(self) -> list[dict]:
        if not self.is_logged_in or not self._client:
            return []
        try:
            resp = await self._client.get(
                "https://mooc1-api.chaoxing.com/mycourse/backclazzdata?view=json&mcode=&rss=1",
                headers={
                    "User-Agent": CHAOXING_MOBILE_UA,
                    "X-Requested-With": "com.chaoxing.mobile",
                    "Accept-Language": "zh_CN",
                    "Referer": "https://i.chaoxing.com",
                },
            )
            data = resp.json()
            courses = []
            for ch in data.get("channelList", []):
                if ch.get("cataid") != "100000002":
                    continue
                content = ch.get("content") or {}
                # Skip archived / filed courses (isFiled == 1)
                if content.get("isFiled") == 1 or str(content.get("isFiled", "0")) == "1":
                    continue
                course_data = ((content.get("course") or {}).get("data")) or []
                if not course_data:
                    continue
                c0 = course_data[0]
                course_id = str(c0.get("id", ""))
                class_id = str(ch.get("key", ""))
                cpi = str(ch.get("cpi", ""))
                if not course_id or not class_id:
                    continue
                courses.append({
                    "id": course_id,
                    "classId": class_id,
                    "cpi": cpi,
                    "name": content.get("name", "(未知课程)"),
                    "teacher": c0.get("teacherfactor", ""),
                    "image": c0.get("courseImg", ""),
                })
            log.info(f"Fetched {len(courses)} active courses (isFiled filtered)")
            return courses
        except Exception as e:
            log.warning(f"fetch_courses error: {e}")
            return []

    # ------------------------------------------------------------------
    # Assignments  (HTML response, mobile UA required)
    # ------------------------------------------------------------------

    async def fetch_assignments(
        self, course_id: str, class_id: str, cpi: str, course_name: str
    ) -> list[dict]:
        if not self.is_logged_in or not self._client:
            return []
        try:
            resp = await self._client.get(
                f"https://mooc1-api.chaoxing.com/work/task-list"
                f"?courseId={course_id}&classId={class_id}&cpi={cpi}",
                headers={
                    "User-Agent": CHAOXING_MOBILE_UA,
                    "X-Requested-With": "com.chaoxing.mobile",
                    "Accept-Language": "zh_CN",
                    "Referer": "https://mooc1.chaoxing.com",
                },
            )
            return _parse_assignments_html(resp.text, course_id, course_name)
        except Exception as e:
            log.warning(f"fetch_assignments error ({course_name}): {e}")
            return []

    async def fetch_all_pending_assignments(self) -> list[dict]:
        if not self.is_logged_in:
            return []
        now = datetime.now(timezone.utc)
        if (self._assignment_cache_at
                and (now - self._assignment_cache_at).total_seconds() < self.ASSIGNMENT_CACHE_TTL):
            return self._assignment_cache
        result = await self._fetch_all_pending_assignments_uncached()
        self._assignment_cache = result
        self._assignment_cache_at = now
        return result

    async def _fetch_all_pending_assignments_uncached(self) -> list[dict]:
        courses = await self.fetch_courses()
        tasks = [
            self.fetch_assignments(c["id"], c["classId"], c["cpi"], c["name"])
            for c in courses
        ]
        results = await asyncio.gather(*tasks, return_exceptions=True)
        all_asgn = []
        for r in results:
            if isinstance(r, list):
                all_asgn.extend(r)
        all_asgn.sort(key=lambda a: a.get("dueDate") or "9999")
        return all_asgn

    # ------------------------------------------------------------------
    # IM — params, conversations, roaming messages, inbox notices
    # ------------------------------------------------------------------

    async def _fetch_im_params(self) -> dict:
        """GET https://im.chaoxing.com/webim/me → parse myTuid, myPuid, myToken."""
        resp = await self._client.get(
            "https://im.chaoxing.com/webim/me",
            headers={"Referer": "https://i.chaoxing.com"},
        )
        html = resp.text
        tuid = _html_id_value(html, "myTuid")
        puid = _html_id_value(html, "myPuid")
        token = _html_id_value(html, "myToken")
        if not tuid or not puid or not token:
            raise ValueError("Failed to extract IM params — not logged in or page changed")
        return {"tuid": tuid, "puid": puid, "token": token}

    async def _fetch_conversations(self, params: dict) -> list[dict]:
        """POST https://im.chaoxing.com/webim/message/list/getMessageList."""
        resp = await self._client.post(
            "https://im.chaoxing.com/webim/message/list/getMessageList",
            data={"tuid": params["tuid"], "puid": params["puid"], "token": params["token"]},
            headers={
                "X-Requested-With": "XMLHttpRequest",
                "Content-Type": "application/x-www-form-urlencoded; charset=UTF-8",
                "Referer": "https://im.chaoxing.com/webim/me",
            },
        )
        data = resp.json()
        if data.get("status") != "success":
            log.warning(f"getMessageList status: {data.get('status')}")
            return []
        convs = []
        for item in data.get("data", []):
            if str(item.get("folder", "false")).lower() == "true":
                continue
            chat_id = str(item.get("chatId", ""))
            if not chat_id:
                continue
            is_group = item.get("chatType") == "groupchat"
            update_ms = item.get("updateTime") or item.get("createTime")
            updated_at = None
            if update_ms:
                try:
                    updated_at = datetime.fromtimestamp(
                        float(update_ms) / 1000, tz=timezone.utc
                    ).isoformat()
                except Exception:
                    pass
            name = item.get("chatName") or "学习通消息"
            try:
                name = unquote(name)
            except Exception:
                pass
            convs.append({
                "id": chat_id,
                "msg_id": str(item.get("msgId", "")),
                "name": name,
                "is_group": is_group,
                "updated_at": updated_at,
            })
        convs.sort(key=lambda c: c.get("updated_at") or "", reverse=True)
        return convs

    async def _fetch_roaming_messages(
        self, params: dict, conversation: dict, limit: int
    ) -> list[dict]:
        """Fetch roaming messages via EaseMob API + Protobuf decode."""
        tuid = params["tuid"]
        token = params["token"]
        url = f"https://a1-vip6.easecdn.com/cx-dev/cxstudy/users/{tuid}/messageroaming"
        primary = "@conference.easemob.com" if conversation["is_group"] else "@easemob.com"
        fallback = "@easemob.com" if conversation["is_group"] else "@conference.easemob.com"

        for suffix in (primary, fallback):
            try:
                resp = await self._client.post(
                    url,
                    json={"queue": conversation["id"] + suffix, "start": -1, "end": -1},
                    headers={
                        "Authorization": f"Bearer {token}",
                        "Content-Type": "application/json",
                        "User-Agent": CHAOXING_DESKTOP_UA,
                    },
                )
                raw_msgs = (resp.json().get("data") or {}).get("msgs") or []
                if not raw_msgs:
                    continue

                eff_conv = dict(conversation)
                eff_conv["is_group"] = suffix == "@conference.easemob.com"
                decoded = []
                for raw in raw_msgs:
                    encoded = raw.get("msg")
                    if not encoded:
                        continue
                    from_user = raw.get("fromUser") or {}
                    raw_sender_name = _first_nonempty(
                        from_user.get("nickname"), from_user.get("name"),
                        from_user.get("realName"), from_user.get("showName"),
                        raw.get("fromName"), raw.get("fromNickName"),
                    )
                    raw_sender_uid = _first_nonempty(
                        raw.get("from"),
                        from_user.get("uid"), from_user.get("puid"), from_user.get("id"),
                        raw.get("fromUid"), raw.get("fromPuid"),
                    )
                    msg_time = raw.get("msgTime")
                    raw_ts_ms = float(msg_time) if msg_time is not None else None
                    msg = _decode_roaming_message(
                        encoded, eff_conv,
                        raw_sender_uid=raw_sender_uid,
                        raw_sender_name=raw_sender_name,
                        raw_msg_time_ms=raw_ts_ms,
                    )
                    if msg:
                        decoded.append(msg)
                if decoded:
                    decoded.sort(key=lambda m: m.get("sent_at") or "", reverse=True)
                    return decoded[:limit]
            except Exception as e:
                log.debug(f"roaming ({conversation['id']}{suffix}): {e}")
        return []

    async def _fetch_inbox_notices(self, limit: int = 20) -> list[dict]:
        """GET https://notice.chaoxing.com/pc/notice/getNoticeList."""
        try:
            resp = await self._client.get(
                f"https://notice.chaoxing.com/pc/notice/getNoticeList?pnum=1&count={limit}&type=0",
                headers={"Referer": "https://i.chaoxing.com"},
            )
            data = resp.json()
            raw_list = (data.get("notices") or {}).get("list") or []
            messages = []
            for item in raw_list:
                raw_id = item.get("idCode") or str(item.get("id", ""))
                if not raw_id:
                    continue
                title = (item.get("title") or "").strip()
                content = (item.get("content") or "").strip()
                if title and content:
                    text = f"{title}\n{content}"
                elif content:
                    text = content
                elif title:
                    text = title
                else:
                    continue
                sender_name = item.get("createrName") or "系统通知"
                sender_uid = str(item.get("createrId") or item.get("createrPuid") or "system")
                ts_ms = item.get("insertTime") or item.get("createTime") or item.get("sendTime")
                sent_at = (
                    datetime.fromtimestamp(float(ts_ms) / 1000, tz=timezone.utc).isoformat()
                    if ts_ms else datetime.now(tz=timezone.utc).isoformat()
                )
                messages.append({
                    "id": f"inbox-{raw_id}",
                    "conversation_id": "inbox",
                    "conversation_name": "收件箱",
                    "is_group": False,
                    "sender_id": sender_uid,
                    "sender_name": sender_name,
                    "sent_at": sent_at,
                    "type": "TEXT",
                    "text": text,
                    "image_urls": None,
                })
            return messages
        except Exception as e:
            log.warning(f"fetch_inbox_notices error: {e}")
            return []

    # ------------------------------------------------------------------
    # Public message APIs
    # ------------------------------------------------------------------

    async def fetch_conversation_probes(self, limit: int = 12) -> list[dict]:
        if not self.is_logged_in or not self._client:
            return []
        try:
            params = await self._fetch_im_params()
            convs = await self._fetch_conversations(params)
            return [
                {
                    "conversation_id": c["id"],
                    "name": c["name"],
                    "signature": f"{c['msg_id']}:{c.get('updated_at', '')}",
                }
                for c in convs[:limit]
            ]
        except Exception as e:
            log.warning(f"fetch_conversation_probes error: {e}")
            return []

    async def fetch_recent_messages(
        self,
        max_conversations: int = 12,
        per_conversation: int = 20,
        changed_conversation_ids: list[str] | None = None,
    ) -> list[dict]:
        if not self.is_logged_in or not self._client:
            return []
        try:
            params = await self._fetch_im_params()
            all_convs = await self._fetch_conversations(params)
            if changed_conversation_ids:
                convs = [c for c in all_convs if c["id"] in changed_conversation_ids]
                if not convs:
                    convs = all_convs[:max_conversations]
            else:
                convs = all_convs[:max_conversations]

            messages: list[dict] = []
            seen: set[str] = set()
            for conv in convs:
                for msg in await self._fetch_roaming_messages(params, conv, per_conversation):
                    if msg["id"] not in seen:
                        seen.add(msg["id"])
                        messages.append(msg)

            for msg in await self._fetch_inbox_notices(per_conversation):
                if msg["id"] not in seen:
                    seen.add(msg["id"])
                    messages.append(msg)

            messages.sort(key=lambda m: m.get("sent_at") or "", reverse=True)
            return messages
        except Exception as e:
            log.warning(f"fetch_recent_messages error: {e}")
            return []

    # ------------------------------------------------------------------
    # Adaptive sync
    # ------------------------------------------------------------------

    async def adaptive_sync_pass(self, db_path: str, assignments: list[dict] | None = None) -> float:
        now = datetime.now(timezone.utc)
        probes = await self.fetch_conversation_probes()
        changed_ids = await self._filter_changed_probes(probes, db_path)

        # Expose this tick's change count so the probe pipeline (chaoxing_sync)
        # can skip the expensive LLM extraction when no conversation changed (P4).
        self._last_sync_changed = len(changed_ids)

        if changed_ids:
            await self.fetch_recent_messages(changed_conversation_ids=changed_ids)
            consecutive_no_change = 0
        else:
            consecutive_no_change = await self._get_consecutive_no_change(db_path) + 1

        await self._save_probe_signatures(probes, db_path)
        await self._save_consecutive_no_change(consecutive_no_change, db_path)
        await self._touch_session_activity(db_path, now)
        if assignments is None:
            assignments = await self.fetch_all_pending_assignments()

        # ── Gather signals for the signal-driven cadence decision (P1) ──
        signals = {
            "changed": len(changed_ids),
            "consecutive_no_change": consecutive_no_change,
            "now_local": now.astimezone(zoneinfo.ZoneInfo("Asia/Shanghai")),
            "imminent_deadline_min": _min_minutes_to_due(assignments, now),
            "dingtalk_active": _dingtalk_active(),
            "urgent_recent_memory": await self._has_urgent_recent_memory(db_path, now),
        }
        interval = compute_sync_interval(**signals)
        log.debug(
            "sync cadence: %.0fs from signals %s", interval,
            {k: (round(v, 1) if isinstance(v, float) else v)
             for k, v in signals.items() if k != "now_local"},
        )
        return interval

    async def _has_urgent_recent_memory(self, db_path: str, now: datetime) -> bool:
        """True if a high-importance memory entry was extracted in the last 15 min."""
        cutoff = (now - timedelta(minutes=15)).isoformat()
        try:
            async with aiosqlite.connect(db_path) as db:
                row = await (await db.execute(
                    "SELECT 1 FROM chaoxing_memory_entries "
                    "WHERE importance='high' AND archived_at IS NULL "
                    "AND COALESCE(extracted_at, updated_at, sent_at) > ? LIMIT 1",
                    (cutoff,),
                )).fetchone()
            return row is not None
        except Exception:
            return False

    async def _touch_session_activity(self, db_path: str, now: datetime):
        async with aiosqlite.connect(db_path) as db:
            await db.execute(
                "UPDATE chaoxing_session SET last_active_at=?, updated_at=? WHERE id=1",
                (now.isoformat(), now.isoformat()),
            )
            await db.commit()

    async def _next_interval_from_activity(self, db_path: str, now: datetime) -> float:
        async with aiosqlite.connect(db_path) as db:
            row = await (await db.execute("""
                SELECT MAX(updated_at) FROM chaoxing_conversation_sync
            """)).fetchone()
        last_dt = None
        if row and row[0]:
            try:
                last_dt = datetime.fromisoformat(row[0].replace("Z", "+00:00"))
                if last_dt.tzinfo is None:
                    last_dt = last_dt.replace(tzinfo=timezone.utc)
            except Exception:
                last_dt = None
        if last_dt and now - last_dt <= timedelta(hours=1):
            return random.uniform(60, 120)
        if last_dt and now - last_dt <= timedelta(hours=6):
            return random.uniform(120, 300)
        return random.uniform(300, 600)

    async def _filter_changed_probes(self, probes: list[dict], db_path: str) -> list[str]:
        async with aiosqlite.connect(db_path) as db:
            changed = []
            for p in probes:
                row = await (await db.execute(
                    "SELECT signature FROM chaoxing_probe_signatures WHERE conversation_id=?",
                    (p["conversation_id"],),
                )).fetchone()
                if not row or row[0] != p["signature"]:
                    changed.append(p["conversation_id"])
            return changed

    async def _save_probe_signatures(self, probes: list[dict], db_path: str):
        async with aiosqlite.connect(db_path) as db:
            for p in probes:
                await db.execute(
                    "INSERT OR REPLACE INTO chaoxing_probe_signatures "
                    "(conversation_id, signature, updated_at) VALUES (?,?,?)",
                    (p["conversation_id"], p["signature"], datetime.utcnow().isoformat()),
                )
            await db.commit()

    async def _get_consecutive_no_change(self, db_path: str) -> int:
        async with aiosqlite.connect(db_path) as db:
            row = await (await db.execute(
                "SELECT value FROM chaoxing_sync_state WHERE key='consecutive_no_change_count'"
            )).fetchone()
            return int(row[0]) if row else 0

    async def _save_consecutive_no_change(self, count: int, db_path: str):
        async with aiosqlite.connect(db_path) as db:
            await db.execute(
                "INSERT OR REPLACE INTO chaoxing_sync_state (key, value) "
                "VALUES ('consecutive_no_change_count', ?)",
                (str(count),),
            )
            await db.commit()

    def _in_important_window(self, assignments: list[dict]) -> bool:
        """Check if any assignment is due within 1 hour. Accepts pre-fetched assignments."""
        now = datetime.now(tz=timezone.utc)
        for a in assignments:
            try:
                due_str = a.get("dueDate")
                if not due_str:
                    continue
                due = datetime.fromisoformat(due_str)
                if due.tzinfo is None:
                    due = due.replace(tzinfo=timezone.utc)
                if 0 < (due - now).total_seconds() <= 3600:
                    return True
            except Exception:
                pass
        return False

    def _next_interval(self, consecutive_no_change: int, in_important_window: bool) -> float:
        if in_important_window:
            return 45.0
        if consecutive_no_change >= 12:
            return 600.0
        if consecutive_no_change >= 8:
            return 300.0
        if consecutive_no_change >= 4:
            return 180.0
        if consecutive_no_change >= 2:
            return 90.0
        return 45.0
