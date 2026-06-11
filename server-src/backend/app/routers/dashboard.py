from __future__ import annotations

from datetime import datetime, time, timedelta, timezone
from zoneinfo import ZoneInfo

from fastapi import APIRouter

from app.config import settings
from app.database import db_conn
from app.services.budget import budget_day, daily_token_budget, tokens_used_today


router = APIRouter(prefix="/api/dashboard", tags=["dashboard"])
LOCAL_TZ = ZoneInfo("Asia/Shanghai")


@router.get("/today")
async def dashboard_today():
    now = datetime.now(timezone.utc)
    local_now = now.astimezone(LOCAL_TZ)
    today_start = datetime.combine(local_now.date(), time.min, tzinfo=LOCAL_TZ).astimezone(timezone.utc)
    tomorrow_start = today_start + timedelta(days=1)
    week_end = now + timedelta(days=7)
    now_iso = now.isoformat()

    async with db_conn() as db:
        courses = await _fetchall(db, """
            SELECT id, title, start_at, end_at, location, notes
            FROM server_courses
            WHERE end_at >= ? AND start_at < ?
            ORDER BY start_at ASC
            LIMIT 30
        """, (today_start.isoformat(), tomorrow_start.isoformat()))
        events = await _fetchall(db, """
            SELECT id, title, start_at, end_at, location, notes, calendar_name
            FROM server_events
            WHERE end_at >= ? AND start_at < ?
            ORDER BY start_at ASC
            LIMIT 30
        """, (today_start.isoformat(), tomorrow_start.isoformat()))
        reminders = await _fetchall(db, """
            SELECT id, title, due_at, notes, list_name, is_important
            FROM server_reminders
            WHERE is_completed=0
              AND (due_at IS NULL OR due_at < ?)
            ORDER BY due_at IS NULL, due_at ASC
            LIMIT 30
        """, (tomorrow_start.isoformat(),))
        memory_items = await _fetchall(db, """
            SELECT id, title, summary, action_hint, importance, kind, category,
                   expires_at, entity_id, source_type
            FROM chaoxing_memory_entries
            WHERE archived_at IS NULL
              AND COALESCE(status, 'active')='active'
              AND (expires_at IS NULL OR expires_at >= ?)
              AND importance IN ('high', 'medium')
            ORDER BY CASE importance WHEN 'high' THEN 1 ELSE 2 END,
                     COALESCE(expires_at, updated_at, extracted_at, sent_at) ASC
            LIMIT 30
        """, (now_iso,))
        assignments = await _fetchall(db, """
            SELECT id, course_name, title, due_date, status
            FROM chaoxing_assignments
            WHERE status NOT IN ('已交', '已完成')
            ORDER BY due_date IS NULL, due_date ASC
            LIMIT 30
        """)
        scheduled = await _fetchall(db, """
            SELECT id, title, body, scheduled_at, source_type, source_id, reason
            FROM scheduled_notifications
            WHERE sent_at IS NULL AND cancelled_at IS NULL
              AND scheduled_at >= ? AND scheduled_at <= ?
            ORDER BY scheduled_at ASC
            LIMIT 30
        """, (now_iso, week_end.isoformat()))
        notifications = await _fetchall(db, """
            SELECT id, item_id, notif_type, sent_at, clicked_at, dismissed_at,
                   push_title AS title, push_body AS body
            FROM notification_log
            ORDER BY sent_at DESC
            LIMIT 20
        """)
        feedback_rows = await _fetchall(db, """
            SELECT action, COUNT(*) AS count
            FROM notification_feedback
            WHERE created_at >= ?
            GROUP BY action
        """, ((now - timedelta(days=7)).isoformat(),))
        audits = await _fetchall(db, """
            SELECT id, conversation_id, tool_name, sql_or_op, result_summary, created_at
            FROM agent_audit_log
            ORDER BY created_at DESC
            LIMIT 20
        """)

    plan = _dedupe([
        *[_event("course", c["id"], c["title"], c["start_at"], c["end_at"], c.get("location")) for c in courses],
        *[_event("event", e["id"], e["title"], e["start_at"], e["end_at"], e.get("location")) for e in events],
        *[_todo("reminder", r["id"], r["title"], r.get("due_at"), "high" if r.get("is_important") else "medium", r.get("notes")) for r in reminders],
        *[_todo("memory", m["id"], m["title"], m.get("expires_at"), m.get("importance"), m.get("action_hint") or m.get("summary")) for m in memory_items],
    ])

    upcoming = _dedupe([
        *[_todo("assignment", a["id"], f"{a.get('course_name') or '学习通'}：{a['title']}", a.get("due_date"), "medium", a.get("status")) for a in assignments],
        *[_todo("scheduled", s["id"], s["title"], s.get("scheduled_at"), "medium", s.get("body") or s.get("reason")) for s in scheduled],
    ])

    used = await tokens_used_today(settings.database_path, now)
    limit = await daily_token_budget(settings.database_path)
    return {
        "date": local_now.date().isoformat(),
        "now": local_now.isoformat(),
        "plan": sorted(plan, key=lambda x: x.get("sort_at") or "9999")[:40],
        "upcoming": sorted(upcoming, key=lambda x: x.get("sort_at") or "9999")[:40],
        "notifications": notifications,
        "feedback": {r["action"]: r["count"] for r in feedback_rows},
        "agent_audit": audits,
        "budget": {
            "day": budget_day(now),
            "used_tokens": used,
            "daily_token_budget": limit,
            "remaining_tokens": max(0, limit - used) if limit else None,
        },
        "counts": {
            "courses_today": len(courses),
            "events_today": len(events),
            "open_reminders": len(reminders),
            "active_memory": len(memory_items),
            "upcoming_notifications": len(scheduled),
        },
    }


async def _fetchall(db, sql: str, params: tuple = ()) -> list[dict]:
    rows = await (await db.execute(sql, params)).fetchall()
    return [dict(r) for r in rows]


def _event(source: str, row_id: str, title: str, start_at: str, end_at: str, location: str | None) -> dict:
    return {
        "key": f"{source}:{row_id}",
        "source": source,
        "kind": "event",
        "title": title,
        "start_at": start_at,
        "end_at": end_at,
        "location": location or "",
        "sort_at": start_at,
    }


def _todo(source: str, row_id: str, title: str, due_at: str | None, importance: str | None, detail: str | None) -> dict:
    return {
        "key": f"{source}:{row_id}",
        "source": source,
        "kind": "todo",
        "title": title,
        "due_at": due_at,
        "importance": importance or "medium",
        "detail": detail or "",
        "sort_at": due_at or "",
    }


def _dedupe(items: list[dict]) -> list[dict]:
    out: list[dict] = []
    seen: set[str] = set()
    for item in items:
        key = item.get("key")
        if not key or key in seen:
            continue
        seen.add(key)
        out.append(item)
    return out
