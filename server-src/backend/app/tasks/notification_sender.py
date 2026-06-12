"""Push notification decision logic."""

from __future__ import annotations
import json
from datetime import datetime, time, timedelta, timezone
from app.services.push_service import send_push_to_all_subscribers, has_notified, log_notification_sent
import aiosqlite

# 仅"未提交/未交"算待办;已提交/待批阅/已批阅/已完成/已截止都不再提醒。
_PENDING_STATUSES = {"未交", "未提交"}


def _is_pending(a: dict) -> bool:
    return (a.get("status") or "").strip() in _PENDING_STATUSES


async def check_and_send_deadline_notifications(app_state):
    if not app_state.chaoxing_svc.is_logged_in:
        return

    db_path = app_state.settings.database_path
    now = datetime.now(timezone.utc)

    assignments = await app_state.chaoxing_svc.fetch_all_pending_assignments()
    for assignment in assignments:
        # 只提醒"未提交/未交";已提交、待批阅、已批阅、已完成、已截止都不再打扰。
        if (assignment.get("status") or "").strip() not in _PENDING_STATUSES:
            continue
        try:
            due_str = assignment.get("dueDate")
            if not due_str:
                continue
            due = datetime.fromisoformat(due_str)
        except (ValueError, TypeError):
            continue
        delta = due - now

        if timedelta(0) < delta <= timedelta(hours=1):
            notif_type = "deadline_1h"
            if not await has_notified(db_path, assignment["id"], notif_type):
                await send_push_to_all_subscribers(
                    db_path,
                    title=f"⏰ {assignment['title']}",
                    body=f"截止时间不到 1 小时！{assignment.get('courseName', '')}",
                    tag=f"deadline-{assignment['id']}",
                    data={"type": "assignment", "id": assignment["id"]},
                )
                await log_notification_sent(db_path, assignment["id"], notif_type,
                                             title=f"⏰ {assignment['title']}",
                                             body=f"截止时间不到 1 小时！{assignment.get('courseName', '')}")

        elif timedelta(hours=1) < delta <= timedelta(hours=24):
            notif_type = "deadline_24h"
            if not await has_notified(db_path, assignment["id"], notif_type):
                remaining = _format_remaining(delta)
                await send_push_to_all_subscribers(
                    db_path,
                    title=f"📋 {assignment['title']}",
                    body=f"还剩 {remaining}。{assignment.get('courseName', '')}",
                    tag=f"deadline-{assignment['id']}",
                )
                await log_notification_sent(db_path, assignment["id"], notif_type,
                                             title=f"📋 {assignment['title']}",
                                             body=f"还剩 {remaining}。{assignment.get('courseName', '')}")


async def send_daily_begin(app_state):
    db_path = app_state.settings.database_path
    now = datetime.now(timezone.utc)
    local_now = _to_local(now)
    today_str = local_now.strftime("%Y-%m-%d")
    notif_id = f"daily-begin-{today_str}"

    if await has_notified(db_path, notif_id, "daily_begin"):
        return

    context = await _build_daily_begin_context(app_state, now)
    title, body = await _generate_daily_push_copy(
        app_state,
        now,
        "你是晨间简报助手。输出 JSON：{\"title\":\"12字以内\",\"body\":\"40字以内\"}。只点出今天最关键的一两件事（最硬的截止或第一节课），有温度、像朋友提醒，禁止列表、禁止罗列全部。",
        context,
        fallback=_fallback_daily_begin(context),
    )

    await send_push_to_all_subscribers(db_path, title=title, body=body, tag=f"daily-begin-{today_str}")
    await log_notification_sent(db_path, notif_id, "daily_begin", title=title, body=body)


async def send_daily_summary_evening(app_state):
    db_path = app_state.settings.database_path
    now = datetime.now(timezone.utc)
    local_now = _to_local(now)
    today_str = local_now.strftime("%Y-%m-%d")
    notif_id = f"daily-evening-{today_str}"

    if await has_notified(db_path, notif_id, "daily_summary_evening"):
        return

    context = await _build_daily_evening_context(app_state, now)
    title, body = await _generate_daily_push_copy(
        app_state,
        now,
        "你是晚间总结助手。输出 JSON：{\"title\":\"12字以内\",\"body\":\"40字以内\"}。一句话收尾今天（未完成的重点）并预告明天最关键的一件事，温和、不列表、不罗列全部。",
        context,
        fallback=_fallback_daily_evening(context),
    )

    await send_push_to_all_subscribers(db_path, title=title, body=body, tag=f"daily-evening-{today_str}")
    await log_notification_sent(db_path, notif_id, "daily_summary_evening", title=title, body=body)


async def send_daily_summary(app_state):
    await send_daily_begin(app_state)


async def check_scheduled_notifications(app_state):
    db_path = app_state.settings.database_path
    now = datetime.now(timezone.utc)
    async with aiosqlite.connect(db_path) as db:
        db.row_factory = aiosqlite.Row
        rows = await (await db.execute("""
            SELECT id, title, body, scheduled_at, source_id, source_type
            FROM scheduled_notifications
            WHERE sent_at IS NULL AND cancelled_at IS NULL AND scheduled_at <= ?
            ORDER BY scheduled_at ASC
            LIMIT 20
        """, (now.isoformat(),))).fetchall()

    quiet_start, quiet_end = await _load_quiet_hours(db_path)
    for row in rows:
        local_now = now.astimezone(timezone(timedelta(hours=8)))
        if _in_quiet_hours(local_now, quiet_start, quiet_end):
            delayed = local_now.replace(
                hour=quiet_end.hour, minute=quiet_end.minute, second=0, microsecond=0
            )
            if delayed <= local_now:
                delayed += timedelta(days=1)
            async with aiosqlite.connect(db_path) as db:
                await db.execute(
                    "UPDATE scheduled_notifications SET scheduled_at=? WHERE id=? AND sent_at IS NULL",
                    (delayed.astimezone(timezone.utc).isoformat(), row["id"]),
                )
                await db.commit()
            continue

        result = await send_push_to_all_subscribers(
            db_path,
            title=row["title"],
            body=row["body"],
            tag=f"scheduled-{row['id']}",
            data={"type": "scheduled_notification", "id": row["id"], "tag": f"scheduled-{row['id']}"},
        )
        async with aiosqlite.connect(db_path) as db:
            await db.execute(
                "UPDATE scheduled_notifications SET sent_at=? WHERE id=?",
                (now.isoformat(), row["id"]),
            )
            await db.commit()
        if result.get("attempted", 0) > 0:
            await log_notification_sent(db_path, row["id"], "scheduled_notification",
                                         title=row["title"], body=row["body"])


async def _load_quiet_hours(db_path: str) -> tuple[time, time]:
    async with aiosqlite.connect(db_path) as db:
        row = await (await db.execute(
            "SELECT value FROM settings WHERE key='quiet_hours'"
        )).fetchone()
    return _parse_quiet_hours(row[0] if row else None)


def _parse_quiet_hours(value: str | None) -> tuple[time, time]:
    raw = (value or "23:30-07:00").strip()
    try:
        start_raw, end_raw = raw.split("-", 1)
        start_h, start_m = [int(part) for part in start_raw.split(":", 1)]
        end_h, end_m = [int(part) for part in end_raw.split(":", 1)]
        return time(start_h, start_m), time(end_h, end_m)
    except Exception:
        return time(23, 30), time(7, 0)


def _in_quiet_hours(local_dt: datetime, start: time, end: time) -> bool:
    current = local_dt.time()
    if start <= end:
        return start <= current < end
    return current >= start or current < end


def _format_remaining(delta: timedelta) -> str:
    total = int(delta.total_seconds())
    h, m = divmod(total // 60, 60)
    return f"{h} 小时 {m} 分钟" if h else f"{m} 分钟"


def _due_within_days(due_str: str, days: int) -> bool:
    try:
        due = datetime.fromisoformat(due_str)
        return timedelta(0) < due - datetime.now(timezone.utc) <= timedelta(days=days)
    except Exception:
        return False


async def _build_daily_begin_context(app_state, now: datetime) -> dict:
    db_path = app_state.settings.database_path
    start, end = _local_day_bounds(now)
    assignments = []
    if app_state.chaoxing_svc.is_logged_in:
        all_assignments = await app_state.chaoxing_svc.fetch_all_pending_assignments()
        assignments = [a for a in all_assignments if _is_pending(a) and _is_between(a.get("dueDate"), start, end)]

    async with aiosqlite.connect(db_path) as db:
        db.row_factory = aiosqlite.Row
        courses = await (await db.execute("""
            SELECT title, start_at, end_at, location FROM server_courses
            WHERE end_at >= ? AND start_at <= ? ORDER BY start_at ASC LIMIT 12
        """, (start.isoformat(), end.isoformat()))).fetchall()
        reminders = await (await db.execute("""
            SELECT title, due_at, is_important FROM server_reminders
            WHERE is_completed=0 AND due_at IS NOT NULL AND due_at >= ? AND due_at <= ?
            ORDER BY is_important DESC, due_at ASC LIMIT 12
        """, (start.isoformat(), end.isoformat()))).fetchall()
        memory = await (await db.execute("""
            SELECT m.title, m.summary, m.action_hint, m.importance FROM chaoxing_memory_entries m
            WHERE m.archived_at IS NULL AND m.importance IN ('high','medium')
            AND (m.expires_at IS NULL OR m.expires_at > ?)
            AND NOT EXISTS (
                SELECT 1 FROM notification_log n
                WHERE n.item_id = m.id
                AND n.device_received_at IS NOT NULL
                AND n.dismissed_at IS NULL
            )
            ORDER BY CASE m.importance WHEN 'high' THEN 1 ELSE 2 END, COALESCE(m.updated_at, m.extracted_at, m.sent_at) DESC
            LIMIT 5
        """, (now.isoformat(),))).fetchall()
        scheduled = await (await db.execute("""
            SELECT title, body, scheduled_at FROM scheduled_notifications
            WHERE cancelled_at IS NULL AND scheduled_at >= ? AND scheduled_at <= ?
            ORDER BY scheduled_at ASC LIMIT 8
        """, (start.isoformat(), end.isoformat()))).fetchall()

    return {
        "today": _to_local(now).date().isoformat(),
        "courses": [dict(r) for r in courses],
        "assignments_due_today": assignments,
        "reminders_due_today": [dict(r) for r in reminders],
        "important_memory": [dict(r) for r in memory],
        "scheduled_notifications_today": [dict(r) for r in scheduled],
    }


async def _build_daily_evening_context(app_state, now: datetime) -> dict:
    db_path = app_state.settings.database_path
    today_start, today_end = _local_day_bounds(now)
    tomorrow_start, tomorrow_end = today_start + timedelta(days=1), today_end + timedelta(days=1)
    tomorrow_assignments = []
    if app_state.chaoxing_svc.is_logged_in:
        all_assignments = await app_state.chaoxing_svc.fetch_all_pending_assignments()
        tomorrow_assignments = [a for a in all_assignments if _is_pending(a) and _is_between(a.get("dueDate"), tomorrow_start, tomorrow_end)]

    async with aiosqlite.connect(db_path) as db:
        db.row_factory = aiosqlite.Row
        incomplete = await (await db.execute("""
            SELECT title, due_at, is_important FROM server_reminders
            WHERE is_completed=0 AND due_at IS NOT NULL AND due_at >= ? AND due_at <= ?
            ORDER BY is_important DESC, due_at ASC LIMIT 12
        """, (today_start.isoformat(), today_end.isoformat()))).fetchall()
        completed = await (await db.execute("""
            SELECT title, updated_at FROM server_reminders
            WHERE is_completed=1 AND updated_at >= ? AND updated_at <= ?
            ORDER BY updated_at DESC LIMIT 12
        """, (today_start.isoformat(), today_end.isoformat()))).fetchall()
        tomorrow_courses = await (await db.execute("""
            SELECT title, start_at, end_at, location FROM server_courses
            WHERE end_at >= ? AND start_at <= ? ORDER BY start_at ASC LIMIT 12
        """, (tomorrow_start.isoformat(), tomorrow_end.isoformat()))).fetchall()
        memory = await (await db.execute("""
            SELECT m.id, m.title, m.action_hint, m.importance
            FROM chaoxing_memory_entries m
            WHERE m.archived_at IS NULL AND m.importance='high'
            AND (m.expires_at IS NULL OR m.expires_at > ?)
            AND NOT EXISTS (
                SELECT 1 FROM notification_log n
                WHERE n.item_id = m.id
                AND n.device_received_at IS NOT NULL
                AND n.dismissed_at IS NULL
            )
            ORDER BY COALESCE(m.updated_at, m.extracted_at, m.sent_at) DESC
            LIMIT 5
        """, (now.isoformat(),))).fetchall()

    return {
        "today": _to_local(now).date().isoformat(),
        "unfinished_today": [dict(r) for r in incomplete],
        "completed_today": [dict(r) for r in completed],
        "tomorrow_courses": [dict(r) for r in tomorrow_courses],
        "tomorrow_assignments": tomorrow_assignments,
        "unread_important_memory": [dict(r) for r in memory],
    }


async def _generate_daily_push_copy(app_state, now: datetime, system_prompt: str, context: dict, fallback: tuple[str, str]) -> tuple[str, str]:
    try:
        from app.services.agent_service import AgentMsg, agent_complete
        from app.services.provider_registry import resolve_provider

        provider, api_key = await resolve_provider(app_state.settings.standby_agent_provider or "openai")
        if not api_key:
            return fallback
        response = await agent_complete(
            [
                AgentMsg(role="system", content=f"当前时间：{_to_local(now).isoformat()}。\n{system_prompt}\n只返回 JSON，不要 markdown。"),
                AgentMsg(role="user", content=json.dumps(context, ensure_ascii=False, indent=2)),
            ],
            [],
            provider,
            app_state.settings.standby_agent_model or "gpt-4o-mini",
            api_key,
        )
        parsed = _parse_json_object(response.text or "")
        title = str(parsed.get("title") or "").strip()[:18]
        body = str(parsed.get("body") or "").strip()[:60]
        if title and body:
            return title, body
    except Exception as e:
        print(f"Daily summary LLM failed: {e}")
    return fallback


def _fallback_daily_begin(context: dict) -> tuple[str, str]:
    course_count = len(context.get("courses") or [])
    assignment_count = len(context.get("assignments_due_today") or [])
    reminder_count = len(context.get("reminders_due_today") or [])
    if course_count or assignment_count or reminder_count:
        title = f"今天 {course_count}课 {assignment_count}作业"
        body = f"还有 {reminder_count} 个提醒要留意，先抓最硬的截止。"
    else:
        title = "今天节奏不错"
        body = "暂时没有紧急事项，按自己的步子来。"
    return title, body


def _fallback_daily_evening(context: dict) -> tuple[str, str]:
    unfinished = len(context.get("unfinished_today") or [])
    tomorrow_courses = len(context.get("tomorrow_courses") or [])
    tomorrow_assignments = len(context.get("tomorrow_assignments") or [])
    if unfinished:
        title = f"今天还有 {unfinished} 件未收尾"
    else:
        title = "今天收尾完成"
    body = f"明天有 {tomorrow_courses} 门课、{tomorrow_assignments} 个作业截止。"
    return title, body


def _parse_json_object(text: str) -> dict:
    body = text.strip()
    if body.startswith("```"):
        body = body.split("\n", 1)[1] if "\n" in body else body
        body = body.rsplit("```", 1)[0].strip()
        if body.startswith("json"):
            body = body[4:].strip()
    start = body.find("{")
    end = body.rfind("}")
    if start >= 0 and end > start:
        body = body[start:end + 1]
    try:
        parsed = json.loads(body)
    except json.JSONDecodeError:
        return {}
    return parsed if isinstance(parsed, dict) else {}


def _local_day_bounds(now: datetime) -> tuple[datetime, datetime]:
    local = _to_local(now)
    start_local = local.replace(hour=0, minute=0, second=0, microsecond=0)
    end_local = start_local + timedelta(days=1)
    return start_local.astimezone(timezone.utc), end_local.astimezone(timezone.utc)


def _to_local(dt: datetime) -> datetime:
    if dt.tzinfo is None:
        dt = dt.replace(tzinfo=timezone.utc)
    return dt.astimezone(timezone(timedelta(hours=8)))


def _is_between(value: str | None, start: datetime, end: datetime) -> bool:
    dt = _parse_dt(value)
    return bool(dt and start <= dt < end)


def _parse_dt(value: str | None) -> datetime | None:
    if not value:
        return None
    try:
        dt = datetime.fromisoformat(value.replace("Z", "+00:00"))
    except ValueError:
        return None
    if dt.tzinfo is None:
        dt = dt.replace(tzinfo=timezone.utc)
    return dt.astimezone(timezone.utc)
