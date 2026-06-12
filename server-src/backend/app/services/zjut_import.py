"""ZJUT 导入:登录拉取 → 展开成 server_courses + 写考试到 server_events。

凭据用 AES-GCM 加密存库(密钥在 .env 的 ZJUT_KEY,不进数据库/备份/git)。
刷新只在「手动」或「Reconciler external_update 信号」时调用,绝不定时。
"""
from __future__ import annotations

import base64
import json
import re
import uuid
from datetime import datetime, timedelta, timezone

import aiosqlite
from Crypto.Cipher import AES

from app.config import settings

LOCAL_TZ = timezone(timedelta(hours=8))

# 节次 → (开始, 结束) 时分。可改;第5节是午休空档。对齐用户给的作息表(12 节)。
PERIOD_TIMES: dict[int, tuple[str, str]] = {
    1: ("08:00", "08:45"), 2: ("08:55", "09:40"),
    3: ("09:55", "10:40"), 4: ("10:50", "11:35"),
    5: ("11:35", "13:30"),
    6: ("13:30", "14:15"), 7: ("14:25", "15:10"),
    8: ("15:25", "16:10"), 9: ("16:20", "17:05"),
    10: ("18:30", "19:15"), 11: ("19:25", "20:10"), 12: ("20:20", "21:05"),
}


# ── 加密 ──────────────────────────────────────────────────────────────────────

def _key() -> bytes:
    raw = (settings.zjut_key or "").strip()
    if not raw:
        raise RuntimeError("ZJUT_KEY 未配置,无法加解密凭据")
    return base64.b64decode(raw)


def encrypt(text: str) -> str:
    cipher = AES.new(_key(), AES.MODE_GCM)
    ct, tag = cipher.encrypt_and_digest(text.encode("utf-8"))
    return base64.b64encode(cipher.nonce + tag + ct).decode("ascii")


def decrypt(blob: str) -> str:
    raw = base64.b64decode(blob)
    nonce, tag, ct = raw[:16], raw[16:32], raw[32:]
    cipher = AES.new(_key(), AES.MODE_GCM, nonce=nonce)
    return cipher.decrypt_and_verify(ct, tag).decode("utf-8")


# ── 凭据 / 配置存储 ────────────────────────────────────────────────────────────

async def save_config(db_path: str, *, student_id: str, password: str,
                      save_credentials: bool) -> None:
    """只处理凭据(学号 + 是否加密存密码)。学年/学期/开学日由 run_import 自动写入。"""
    pw_enc = encrypt(password) if (save_credentials and password) else None
    async with aiosqlite.connect(db_path) as db:
        await db.execute("INSERT OR IGNORE INTO zjut_config (id, save_credentials) VALUES (1, 0)")
        await db.execute(
            "UPDATE zjut_config SET student_id=?, password_enc=?, save_credentials=?, updated_at=? WHERE id=1",
            (student_id, pw_enc, 1 if save_credentials else 0,
             datetime.now(timezone.utc).isoformat()),
        )
        await db.commit()


async def get_config(db_path: str) -> dict | None:
    async with aiosqlite.connect(db_path) as db:
        db.row_factory = aiosqlite.Row
        row = await (await db.execute("SELECT * FROM zjut_config WHERE id=1")).fetchone()
    return dict(row) if row else None


async def stored_credentials(db_path: str) -> tuple[str, str] | None:
    """返回 (student_id, password) 或 None。学期每次刷新自动检测,不依赖存储。"""
    cfg = await get_config(db_path)
    if not cfg or not cfg.get("save_credentials") or not cfg.get("password_enc"):
        return None
    return cfg["student_id"], decrypt(cfg["password_enc"])


# ── 展开课表 → server_courses ──────────────────────────────────────────────────

def _dt(date_only: datetime, hhmm: str) -> str:
    h, m = (int(x) for x in hhmm.split(":"))
    return date_only.replace(hour=h, minute=m, second=0, microsecond=0).isoformat()


def expand_courses(courses: list[dict], week1_monday: str) -> list[dict]:
    base = datetime.fromisoformat(week1_monday).replace(tzinfo=LOCAL_TZ)
    rows: list[dict] = []
    for c in courses:
        s, e = c["start_section"], c["end_section"]
        if s not in PERIOD_TIMES or e not in PERIOD_TIMES:
            continue
        start_hm, end_hm = PERIOD_TIMES[s][0], PERIOD_TIMES[e][1]
        for wk in c["weeks"]:
            day = base + timedelta(days=(wk - 1) * 7 + (c["weekday"] - 1))
            rows.append({
                "id": f"zjut_{uuid.uuid4().hex[:12]}",
                "title": c["course"],
                "location": c.get("classroom", ""),
                "start_at": _dt(day, start_hm),
                "end_at": _dt(day, end_hm),
                "notes": "|".join(filter(None, [c.get("teacher", ""), f"第{wk}周", c.get("campus", "")])),
            })
    return rows


_EXAM_TIME = re.compile(r"(\d{4})-(\d{1,2})-(\d{1,2}).*?(\d{1,2}):(\d{2})\s*[-~到至]\s*(\d{1,2}):(\d{2})")


def parse_exam_time(time_raw: str) -> tuple[str, str] | None:
    m = _EXAM_TIME.search(time_raw.replace("（", "(").replace("：", ":"))
    if not m:
        return None
    y, mo, d, h1, m1, h2, m2 = (int(x) for x in m.groups())
    start = datetime(y, mo, d, h1, m1, tzinfo=LOCAL_TZ)
    end = datetime(y, mo, d, h2, m2, tzinfo=LOCAL_TZ)
    return start.isoformat(), end.isoformat()


def expand_exams(exams: list[dict]) -> list[dict]:
    rows: list[dict] = []
    for ex in exams:
        parsed = parse_exam_time(ex.get("time_raw", ""))
        if not parsed:
            continue
        start_at, end_at = parsed
        rows.append({
            "id": f"zjutexam_{uuid.uuid4().hex[:10]}",
            "title": f"考试·{ex['course']}",
            "start_at": start_at,
            "end_at": end_at,
            "location": ex.get("location", ""),
            "notes": "|".join(filter(None, [ex.get("exam_name", ""), ex.get("seat", "")])),
        })
    return rows


# ── 写库(替换 zjut 来源的旧数据) ─────────────────────────────────────────────

async def _write(db_path: str, course_rows: list[dict], exam_rows: list[dict]) -> None:
    now = datetime.now(timezone.utc).isoformat()
    async with aiosqlite.connect(db_path) as db:
        # 课表:清掉本地课程表里 zjut 来源的(calendar_name 标记),再写新
        await db.execute("DELETE FROM server_courses WHERE calendar_name='正方教务'")
        await db.executemany(
            """INSERT INTO server_courses (id, title, calendar_name, start_at, end_at, location, notes, created_at, updated_at)
               VALUES (?, ?, '正方教务', ?, ?, ?, ?, ?, ?)""",
            [(r["id"], r["title"], r["start_at"], r["end_at"], r["location"], r["notes"], now, now)
             for r in course_rows],
        )
        # 考试:写入 server_events,先清旧 zjut 考试(按 id 前缀无法 DELETE,用 calendar_name)
        await db.execute("DELETE FROM server_events WHERE calendar_name='正方考试'")
        await db.executemany(
            """INSERT INTO server_events (id, title, calendar_name, start_at, end_at, location, notes, created_at, updated_at)
               VALUES (?, ?, '正方考试', ?, ?, ?, ?, ?, ?)""",
            [(r["id"], r["title"], r["start_at"], r["end_at"], r["location"], r["notes"], now, now)
             for r in exam_rows],
        )
        await db.commit()


async def run_import(db_path: str, *, student_id: str, password: str,
                     year: str = "", term: str = "", week1_monday: str = "") -> dict:
    """登录→自动检测学期→拉取→展开→写库。year/term/week1 留空则全自动检测。"""
    from app.services import zjut
    data = await zjut.fetch_timetable_and_exams(student_id, password, year, term)
    sem = data.get("semester") or {}
    wk1 = week1_monday or sem.get("week1_monday") or ""
    if not wk1:
        raise zjut.ZjutError("无法确定开学日(第1周周一)")
    course_rows = expand_courses(data["courses"], wk1)
    exam_rows = expand_exams(data["exams"])
    await _write(db_path, course_rows, exam_rows)
    # 记下检测到的学期信息 + 本次导入时间(供界面显示);不碰 password/save 字段
    now = datetime.now(timezone.utc).isoformat()
    async with aiosqlite.connect(db_path) as db:
        await db.execute("INSERT OR IGNORE INTO zjut_config (id, save_credentials) VALUES (1, 0)")
        await db.execute(
            "UPDATE zjut_config SET student_id=?, year=?, term=?, week1_monday=?, "
            "semester_label=?, last_import_at=? WHERE id=1",
            (student_id, sem.get("year", year), sem.get("term", term), wk1,
             sem.get("label", ""), now),
        )
        await db.commit()
    return {
        "ok": True,
        "semester": sem.get("label", ""),
        "courses_fetched": len(data["courses"]),
        "course_sessions_written": len(course_rows),
        "exams_written": len(exam_rows),
    }
