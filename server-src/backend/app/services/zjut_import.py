"""ZJUT 导入:登录拉取 → 展开成 server_courses + 写考试到 server_events。

凭据用 AES-GCM 加密存库(密钥在 .env 的 ZJUT_KEY,不进数据库/备份/git)。
刷新只在「手动」或「Reconciler external_update 信号」时调用,绝不定时。
"""
from __future__ import annotations

import base64
import re
import uuid
from datetime import date, datetime, timedelta, timezone

import aiosqlite
from Crypto.Cipher import AES

from app.config import settings

LOCAL_TZ = timezone(timedelta(hours=8))
TERM_XQM = {"1": "3", "2": "12", "3": "16"}

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
    # 统一存 UTC ISO,和 server_reminders/events 及 dashboard 的 UTC 边界一致;
    # 否则 +08:00 字符串和 +00:00 边界做字典序比较会把昨天的课算进今天。
    h, m = (int(x) for x in hhmm.split(":"))
    return (date_only.replace(hour=h, minute=m, second=0, microsecond=0)
            .astimezone(timezone.utc).isoformat())


def expand_courses(courses: list[dict], week1_monday: str) -> list[dict]:
    base = datetime.fromisoformat(week1_monday).replace(tzinfo=LOCAL_TZ)
    rows: list[dict] = []
    for c in courses:
        s, e = c["start_section"], c["end_section"]
        if s not in PERIOD_TIMES or e not in PERIOD_TIMES:
            continue
        start_hm, end_hm = PERIOD_TIMES[s][0], PERIOD_TIMES[e][1]
        weekdays = c.get("weekdays") or [c.get("weekday")]
        weekdays = [int(d) for d in weekdays if d]
        for wk in c["weeks"]:
            for weekday in weekdays:
                day = base + timedelta(days=(wk - 1) * 7 + (weekday - 1))
                rows.append({
                    "id": f"zjut_{uuid.uuid4().hex[:12]}",
                    "title": c["course"],
                    "location": c.get("classroom", ""),
                    "start_at": _dt(day, start_hm),
                    "end_at": _dt(day, end_hm),
                    "notes": "|".join(filter(None, [
                        c.get("teacher", ""),
                        f"第{wk}周",
                        c.get("campus", ""),
                        "实践环节" if c.get("kind") == "practice" else "",
                    ])),
                })
    return rows


_EXAM_TIME = re.compile(r"(\d{4})-(\d{1,2})-(\d{1,2}).*?(\d{1,2}):(\d{2})\s*[-~到至]\s*(\d{1,2}):(\d{2})")


def parse_exam_time(time_raw: str) -> tuple[str, str] | None:
    m = _EXAM_TIME.search(time_raw.replace("（", "(").replace("：", ":"))
    if not m:
        return None
    y, mo, d, h1, m1, h2, m2 = (int(x) for x in m.groups())
    start = datetime(y, mo, d, h1, m1, tzinfo=LOCAL_TZ).astimezone(timezone.utc)
    end = datetime(y, mo, d, h2, m2, tzinfo=LOCAL_TZ).astimezone(timezone.utc)
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

def term_key(year: str, term: str) -> str:
    return f"{year}:{term}"


def course_calendar_name(year: str, term: str) -> str:
    return f"正方教务:{year}:{term}"


def exam_calendar_name(year: str, term: str) -> str:
    return f"正方考试:{year}:{term}"


def term_label(year: str, term: str) -> str:
    return f"{year}-{int(year) + 1}学年第{term}学期"


def _local_date(iso: str) -> date:
    return datetime.fromisoformat(iso).astimezone(LOCAL_TZ).date()


def _term_end_date(course_rows: list[dict], exam_rows: list[dict], fallback_end: str | None) -> str | None:
    dates: list[date] = []
    for row in course_rows + exam_rows:
        end_at = row.get("end_at") or row.get("start_at")
        if end_at:
            dates.append(_local_date(end_at))
    if fallback_end:
        try:
            dates.append(datetime.fromisoformat(fallback_end).date())
        except ValueError:
            pass
    return max(dates).isoformat() if dates else None


def _next_day(value: str) -> str:
    return (datetime.fromisoformat(value).date() + timedelta(days=1)).isoformat()


def _infer_week1(year: str, term: str, semester: dict, explicit: str = "") -> str:
    if explicit:
        return explicit
    if semester and semester.get("year") == year and semester.get("term") == term:
        return semester.get("week1_monday") or ""
    # ZJUT short term follows the spring term. The calendar block gives spring
    # term end as a Sunday; short term week 1 starts on the next day.
    if semester and semester.get("year") == year and semester.get("term") == "2" and term == "3":
        end = semester.get("end")
        if end:
            return _next_day(end)
    return ""


def _prefetch_targets(semester: dict) -> list[tuple[str, str]]:
    if not semester or not semester.get("year") or not semester.get("term"):
        return []
    year, term = semester["year"], semester["term"]
    targets = [(year, term)]
    if term == "2":
        targets.append((year, "3"))
    return targets


def _choose_active(terms: list[dict], now: datetime | None = None) -> dict | None:
    if not terms:
        return None
    today = (now or datetime.now(timezone.utc)).astimezone(LOCAL_TZ).date().isoformat()
    with_ranges = [t for t in terms if t.get("start_date")]
    for term in with_ranges:
        end = term.get("end_date") or term["start_date"]
        if term["start_date"] <= today <= end:
            return term
    past = [t for t in with_ranges if t["start_date"] <= today]
    if past:
        return sorted(past, key=lambda t: t["start_date"])[-1]
    return sorted(with_ranges, key=lambda t: t["start_date"])[0]


async def _write_term(
    db_path: str,
    *,
    year: str,
    term: str,
    week1_monday: str,
    semester: dict,
    course_rows: list[dict],
    exam_rows: list[dict],
) -> dict:
    now = datetime.now(timezone.utc).isoformat()
    c_cal = course_calendar_name(year, term)
    e_cal = exam_calendar_name(year, term)
    label = term_label(year, term)
    fallback_end = semester.get("end") if semester.get("year") == year and semester.get("term") == term else None
    end_date = _term_end_date(course_rows, exam_rows, fallback_end)
    async with aiosqlite.connect(db_path) as db:
        # 课表:只替换当前 term;顺手清掉旧版单一 calendar_name 的遗留数据。
        await db.execute("DELETE FROM server_courses WHERE calendar_name IN (?, '正方教务')", (c_cal,))
        await db.executemany(
            """INSERT INTO server_courses
                   (id, title, calendar_name, start_at, end_at, location, notes, created_at, updated_at)
               VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?)""",
            [(r["id"], r["title"], c_cal, r["start_at"], r["end_at"], r["location"], r["notes"], now, now)
             for r in course_rows],
        )
        # 考试:按 term 替换;顺手清掉旧版单一 calendar_name 的遗留数据。
        await db.execute("DELETE FROM server_events WHERE calendar_name IN (?, '正方考试')", (e_cal,))
        await db.executemany(
            """INSERT INTO server_events
                   (id, title, calendar_name, start_at, end_at, location, notes, created_at, updated_at)
               VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?)""",
            [(r["id"], r["title"], e_cal, r["start_at"], r["end_at"], r["location"], r["notes"], now, now)
             for r in exam_rows],
        )
        await db.execute(
            """INSERT INTO zjut_terms
                   (term_key, year, term, xqm, week1_monday, start_date, end_date,
                    semester_label, calendar_name, courses_count, exams_count, last_import_at)
               VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
               ON CONFLICT(term_key) DO UPDATE SET
                   xqm=excluded.xqm,
                   week1_monday=excluded.week1_monday,
                   start_date=excluded.start_date,
                   end_date=excluded.end_date,
                   semester_label=excluded.semester_label,
                   calendar_name=excluded.calendar_name,
                   courses_count=excluded.courses_count,
                   exams_count=excluded.exams_count,
                   last_import_at=excluded.last_import_at""",
            (term_key(year, term), year, term, TERM_XQM.get(term, term), week1_monday,
             week1_monday, end_date, label, c_cal, len(course_rows), len(exam_rows), now),
        )
        await db.commit()
    return {
        "term_key": term_key(year, term),
        "year": year,
        "term": term,
        "week1_monday": week1_monday,
        "start_date": week1_monday,
        "end_date": end_date,
        "semester_label": label,
        "courses_fetched": len(course_rows),
        "exams_written": len(exam_rows),
        "calendar_name": c_cal,
        "last_import_at": now,
    }


async def run_import(db_path: str, *, student_id: str, password: str,
                     year: str = "", term: str = "", week1_monday: str = "") -> dict:
    """登录→自动检测学期→预抓可确定的 term→展开→写库。

    year/term/week1 指定时只导入该 term;留空时导入当前 term,并在春学期
    自动预抓紧随其后的短学期。
    """
    from app.services import zjut

    first = await zjut.fetch_timetable_and_exams(student_id, password, year, term)
    sem = first.get("semester") or {}
    targets = [(year, term)] if year and term else _prefetch_targets(sem)
    if not targets:
        raise zjut.ZjutError("拿不到当前学期信息,且未手动指定 year/term")

    imported: list[dict] = []
    skipped: list[dict] = []
    first_key = term_key(year, term) if year and term else None
    fetched_cache = {first_key: first} if first_key else {}

    for target_year, target_term in targets:
        wk1 = _infer_week1(target_year, target_term, sem, week1_monday if (target_year, target_term) == (year, term) else "")
        if not wk1:
            skipped.append({"year": target_year, "term": target_term, "reason": "无法确定第1周周一"})
            continue
        key = term_key(target_year, target_term)
        data = fetched_cache.get(key)
        if data is None:
            data = await zjut.fetch_timetable_and_exams(student_id, password, target_year, target_term)
        course_rows = expand_courses(data["courses"], wk1)
        exam_rows = expand_exams(data["exams"])
        if not course_rows and not exam_rows:
            skipped.append({"year": target_year, "term": target_term, "reason": "正方返回空课表/空考试,保留已有数据"})
            continue
        imported.append(await _write_term(
            db_path,
            year=target_year,
            term=target_term,
            week1_monday=wk1,
            semester=sem,
            course_rows=course_rows,
            exam_rows=exam_rows,
        ))

    if not imported:
        details = "; ".join(f"{s['year']}第{s['term']}学期:{s['reason']}" for s in skipped)
        raise zjut.ZjutError(details or "没有可导入的正方数据")

    active = _choose_active(imported) or imported[0]
    # 记下当前激活/最近导入的学期信息 + 本次导入时间(供界面显示);不碰 password/save 字段
    now = datetime.now(timezone.utc).isoformat()
    async with aiosqlite.connect(db_path) as db:
        await db.execute("INSERT OR IGNORE INTO zjut_config (id, save_credentials) VALUES (1, 0)")
        await db.execute(
            "UPDATE zjut_config SET student_id=?, year=?, term=?, week1_monday=?, "
            "semester_label=?, last_import_at=? WHERE id=1",
            (student_id, active["year"], active["term"], active["week1_monday"],
             active["semester_label"], now),
        )
        await db.commit()
    return {
        "ok": True,
        "semester": active["semester_label"],
        "courses_fetched": sum(t["courses_fetched"] for t in imported),
        "course_sessions_written": sum(t["courses_fetched"] for t in imported),
        "exams_written": sum(t["exams_written"] for t in imported),
        "prefetched_terms": imported,
        "skipped_terms": skipped,
    }
