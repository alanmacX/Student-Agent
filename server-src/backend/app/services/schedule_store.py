from __future__ import annotations
import re
import uuid
from datetime import datetime, timedelta, timezone
from zoneinfo import ZoneInfo

import aiosqlite

BEIJING_TZ = ZoneInfo("Asia/Shanghai")


def now_iso() -> str:
    return datetime.now(timezone.utc).isoformat()


def parse_dt(value: str | None) -> datetime | None:
    if not value:
        return None
    try:
        return datetime.fromisoformat(value.replace("Z", "+00:00"))
    except ValueError:
        return None


def serialize_reminder(row) -> dict:
    return {
        "id": row["id"],
        "title": row["title"],
        "listName": row["list_name"],
        "dueDate": row["due_at"],
        "notes": row["notes"],
        "isCompleted": bool(row["is_completed"]),
        "isImportant": bool(row["is_important"]),
    }


def serialize_event(row, kind: str = "event") -> dict:
    return {
        "id": row["id"],
        "title": row["title"],
        "calendarName": row["calendar_name"],
        "startDate": row["start_at"],
        "endDate": row["end_at"],
        "location": row["location"],
        "notes": row["notes"],
        "isAllDay": bool(row["is_all_day"]) if "is_all_day" in row.keys() else False,
        "kind": row["kind"] if "kind" in row.keys() else kind,
    }


async def list_reminders(db_path: str, include_completed: bool = False) -> list[dict]:
    async with aiosqlite.connect(db_path) as db:
        db.row_factory = aiosqlite.Row
        where = "" if include_completed else "WHERE is_completed=0"
        rows = await (await db.execute(
            f"SELECT * FROM server_reminders {where} ORDER BY due_at IS NULL, due_at ASC, updated_at DESC"
        )).fetchall()
    return [serialize_reminder(row) for row in rows]


async def create_reminder(db_path: str, title: str, due_at: str | None = None, notes: str | None = None, list_name: str = "默认", is_important: bool = False) -> dict:
    reminder_id = str(uuid.uuid4())
    ts = now_iso()
    async with aiosqlite.connect(db_path) as db:
        db.row_factory = aiosqlite.Row
        await db.execute(
            """
            INSERT INTO server_reminders (id, title, list_name, due_at, notes, is_important, created_at, updated_at)
            VALUES (?, ?, ?, ?, ?, ?, ?, ?)
            """,
            (reminder_id, title, list_name or "默认", due_at, notes, 1 if is_important else 0, ts, ts),
        )
        await db.commit()
        row = await (await db.execute("SELECT * FROM server_reminders WHERE id=?", (reminder_id,))).fetchone()
    return serialize_reminder(row)


async def update_reminder(db_path: str, reminder_id: str, **updates) -> dict | None:
    allowed = {
        "title": "title",
        "listName": "list_name",
        "dueDate": "due_at",
        "notes": "notes",
        "isCompleted": "is_completed",
        "isImportant": "is_important",
    }
    fields = []
    params = []
    for key, column in allowed.items():
        if key not in updates:
            continue
        value = updates[key]
        if key in ("isCompleted", "isImportant"):
            value = 1 if value else 0
        fields.append(f"{column}=?")
        params.append(value)
    if not fields:
        return None
    fields.append("updated_at=?")
    params.append(now_iso())
    params.append(reminder_id)
    async with aiosqlite.connect(db_path) as db:
        db.row_factory = aiosqlite.Row
        await db.execute(f"UPDATE server_reminders SET {', '.join(fields)} WHERE id=?", params)
        await db.commit()
        row = await (await db.execute("SELECT * FROM server_reminders WHERE id=?", (reminder_id,))).fetchone()
    return serialize_reminder(row) if row else None


async def delete_reminder(db_path: str, reminder_id: str) -> bool:
    async with aiosqlite.connect(db_path) as db:
        cur = await db.execute("DELETE FROM server_reminders WHERE id=?", (reminder_id,))
        await db.commit()
        return cur.rowcount > 0


async def list_events(db_path: str, days: int = 14) -> list[dict]:
    now = datetime.now(timezone.utc)
    end = now + timedelta(days=days)
    async with aiosqlite.connect(db_path) as db:
        db.row_factory = aiosqlite.Row
        rows = await (await db.execute(
            """
            SELECT * FROM server_events
            WHERE datetime(end_at) >= datetime(?) AND datetime(start_at) <= datetime(?)
            ORDER BY start_at ASC
            """,
            (now.isoformat(), end.isoformat()),
        )).fetchall()
    return [serialize_event(row) for row in rows]


async def create_event(
    db_path: str,
    title: str,
    start_at: str,
    end_at: str,
    notes: str | None = None,
    location: str | None = None,
    calendar_name: str = "Web 日程",
    is_all_day: bool = False,
) -> dict:
    event_id = str(uuid.uuid4())
    ts = now_iso()
    async with aiosqlite.connect(db_path) as db:
        db.row_factory = aiosqlite.Row
        await db.execute(
            """
            INSERT INTO server_events
                (id, title, calendar_name, start_at, end_at, location, notes, is_all_day, kind, created_at, updated_at)
            VALUES (?, ?, ?, ?, ?, ?, ?, ?, 'event', ?, ?)
            """,
            (event_id, title, calendar_name or "Web 日程", start_at, end_at, location, notes, 1 if is_all_day else 0, ts, ts),
        )
        await db.commit()
        row = await (await db.execute("SELECT * FROM server_events WHERE id=?", (event_id,))).fetchone()
    return serialize_event(row)


async def update_event(db_path: str, event_id: str, **updates) -> dict | None:
    allowed = {
        "title": "title",
        "calendarName": "calendar_name",
        "startDate": "start_at",
        "endDate": "end_at",
        "notes": "notes",
        "location": "location",
        "isAllDay": "is_all_day",
    }
    fields = []
    params = []
    for key, column in allowed.items():
        if key not in updates:
            continue
        value = updates[key]
        if key == "isAllDay":
            value = 1 if value else 0
        fields.append(f"{column}=?")
        params.append(value)
    if not fields:
        return None
    fields.append("updated_at=?")
    params.append(now_iso())
    params.append(event_id)
    async with aiosqlite.connect(db_path) as db:
        db.row_factory = aiosqlite.Row
        await db.execute(f"UPDATE server_events SET {', '.join(fields)} WHERE id=?", params)
        await db.commit()
        row = await (await db.execute("SELECT * FROM server_events WHERE id=?", (event_id,))).fetchone()
    return serialize_event(row) if row else None


async def delete_event(db_path: str, event_id: str) -> bool:
    async with aiosqlite.connect(db_path) as db:
        cur = await db.execute("DELETE FROM server_events WHERE id=?", (event_id,))
        await db.commit()
        return cur.rowcount > 0


PERIOD_START = {
    1: (8, 0), 2: (8, 55), 3: (10, 0), 4: (10, 55),
    5: (14, 0), 6: (14, 55), 7: (16, 0), 8: (16, 55),
    9: (19, 0), 10: (19, 55), 11: (20, 50), 12: (21, 45),
}
PERIOD_END = {
    1: (8, 45), 2: (9, 40), 3: (10, 45), 4: (11, 40),
    5: (14, 45), 6: (15, 40), 7: (16, 45), 8: (17, 40),
    9: (19, 45), 10: (20, 40), 11: (21, 35), 12: (22, 30),
}


def _parse_weeks_str(s: str) -> list[int]:
    """Parse a human week spec: "1-8", "1-8,10-16", "1,3,5", with optional
    单/双 (odd/even) markers, e.g. "1-16单" / "2-16/双" / "1-16(单)"."""
    parity = "odd" if "单" in s else ("even" if "双" in s else None)
    out: set[int] = set()
    # Keep only digits, ranges and separators; turn everything else into commas.
    cleaned = re.sub(r"[^0-9,\-]", ",", s)
    for seg in cleaned.split(","):
        seg = seg.strip().strip("-")
        if not seg:
            continue
        if "-" in seg:
            try:
                a, b = (int(x) for x in seg.split("-", 1))
            except ValueError:
                continue
            out.update(range(min(a, b), max(a, b) + 1))
        else:
            try:
                out.add(int(seg))
            except ValueError:
                continue
    weeks = sorted(w for w in out if w > 0)
    if parity == "odd":
        weeks = [w for w in weeks if w % 2 == 1]
    elif parity == "even":
        weeks = [w for w in weeks if w % 2 == 0]
    return weeks


def expand_weeks(weeks) -> list[int]:
    """Normalize the many ways a timetable can express which weeks a class runs.

    Backward compatible with the original [start, end] range format:
      - None / [] / missing      -> weeks 1..16 (default)
      - [a, b] (exactly 2 ints)  -> inclusive range a..b   (LEGACY — unchanged)
      - [w1, w2, w3, ...]        -> those explicit weeks (length != 2)
      - "1-8,10-16" / "1-16单"   -> string spec with ranges + 单/双 parity
      - 7                        -> single week
    """
    if not weeks:
        return list(range(1, 17))
    if isinstance(weeks, str):
        return _parse_weeks_str(weeks) or list(range(1, 17))
    if isinstance(weeks, (list, tuple)):
        try:
            ints = [int(w) for w in weeks]
        except (TypeError, ValueError):
            return list(range(1, 17))
        if len(ints) == 2:  # legacy range form — keep exactly as before
            return list(range(min(ints), max(ints) + 1))
        return sorted({w for w in ints if w > 0}) or list(range(1, 17))
    try:
        return [int(weeks)]
    except (TypeError, ValueError):
        return list(range(1, 17))


def _parse_hhmm(value) -> tuple[int, int] | None:
    """Parse an optional explicit "HH:MM" time override; None if absent/invalid."""
    if not value or not isinstance(value, str):
        return None
    m = re.match(r"^\s*(\d{1,2})[:：](\d{2})\s*$", value)
    if not m:
        return None
    h, mi = int(m.group(1)), int(m.group(2))
    if 0 <= h < 24 and 0 <= mi < 60:
        return (h, mi)
    return None


async def import_timetable(db_path: str, semester_start_str: str, courses: list[dict]) -> dict:
    """Expand a weekly-repeating timetable into dated rows in server_courses.

    semester_start_str: "YYYY-MM-DD", the Monday of week 1.
    courses: [{name, day(1=Mon..7=Sun), periods[start,end], location?, teacher?, weeks[start,end]}]
    Replaces any previously imported timetable (calendar_name='导入课程表').
    """
    try:
        semester_start = datetime.strptime(semester_start_str, "%Y-%m-%d").replace(tzinfo=BEIJING_TZ)
    except (ValueError, TypeError):
        return {"error": "invalid semester_start, expected YYYY-MM-DD"}

    ts = now_iso()
    rows_to_insert = []
    for course in courses:
        name = (course.get("name") or "").strip()
        if not name:
            continue
        day = int(course.get("day", 1))
        periods = course.get("periods") or [1, 2]
        start_period = min(periods)
        end_period = max(periods)
        location = course.get("location") or None
        teacher = course.get("teacher") or None
        week_list = expand_weeks(course.get("weeks"))
        notes = f"教师：{teacher}" if teacher else None
        sh, sm = PERIOD_START.get(start_period, (8, 0))
        eh, em = PERIOD_END.get(end_period, (9, 40))
        # Optional explicit "HH:MM" overrides for schools with different bells.
        start_override = _parse_hhmm(course.get("start"))
        end_override = _parse_hhmm(course.get("end"))
        if start_override:
            sh, sm = start_override
        if end_override:
            eh, em = end_override
        for week in week_list:
            days_offset = (week - 1) * 7 + (day - 1)
            course_date = semester_start + timedelta(days=days_offset)
            start_dt = course_date.replace(hour=sh, minute=sm, second=0, microsecond=0)
            end_dt = course_date.replace(hour=eh, minute=em, second=0, microsecond=0)
            rows_to_insert.append((
                str(uuid.uuid4()), name, "导入课程表",
                start_dt.astimezone(timezone.utc).isoformat(),
                end_dt.astimezone(timezone.utc).isoformat(),
                location, notes, ts, ts,
            ))

    async with aiosqlite.connect(db_path) as db:
        await db.execute("DELETE FROM server_courses WHERE calendar_name='导入课程表'")
        if rows_to_insert:
            await db.executemany(
                "INSERT INTO server_courses (id, title, calendar_name, start_at, end_at, location, notes, created_at, updated_at) VALUES (?,?,?,?,?,?,?,?,?)",
                rows_to_insert,
            )
        await db.commit()
    return {"ok": True, "inserted": len(rows_to_insert), "courses": len([c for c in courses if (c.get("name") or "").strip()])}


async def list_courses(db_path: str, days: int = 14, past_days: int = 7) -> list[dict]:
    now = datetime.now(timezone.utc)
    start = (now - timedelta(days=past_days)).isoformat()
    end = (now + timedelta(days=days)).isoformat()
    async with aiosqlite.connect(db_path) as db:
        db.row_factory = aiosqlite.Row
        rows = await (await db.execute(
            """
            SELECT id, title, calendar_name, start_at, end_at, location, notes
            FROM server_courses
            WHERE datetime(end_at) >= datetime(?) AND datetime(start_at) <= datetime(?)
            ORDER BY start_at ASC
            """,
            (start, end),
        )).fetchall()
    return [
        {
            "id": row["id"],
            "title": row["title"],
            "calendarName": row["calendar_name"],
            "startDate": row["start_at"],
            "endDate": row["end_at"],
            "location": row["location"],
            "notes": row["notes"],
            "isAllDay": False,
            "kind": "course",
        }
        for row in rows
    ]
