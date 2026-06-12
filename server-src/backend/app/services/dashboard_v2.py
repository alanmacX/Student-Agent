from __future__ import annotations

import asyncio
import hashlib
import json
from datetime import timedelta
from typing import Any

import aiosqlite

from app.config import settings
from app.database import db_conn
from app.services.agent_service import AgentMsg, agent_complete
from app.services.budget import budget_day, daily_token_budget, log_usage_later, tokens_used_today
from app.services.provider_registry import resolve_provider
from app.services.time_utils import LOCAL_TZ, local_day_window, parse_any_time, to_utc_iso, utc_now
from app.services.tool_router import resolve_light_agent_provider

_HASH_KEY = "dashboard_v2_hash"
_TEXT_KEY = "dashboard_v2_briefing_text"
_TODOS_KEY = "dashboard_v2_briefing_todos"
_TS_KEY = "dashboard_v2_briefing_at"
_IN_FLIGHT: set[str] = set()


async def dashboard_today(force_briefing: bool = False, wait_for_briefing: bool = False) -> dict[str, Any]:
    payload = await build_dashboard_payload(settings.database_path)
    content_hash = dashboard_hash(payload)
    cached = await load_briefing(settings.database_path)
    hash_changed = cached.get("hash") != content_hash

    if force_briefing or (hash_changed and wait_for_briefing):
        cached = await refresh_briefing(settings.database_path, payload, content_hash)
    elif hash_changed:
        _schedule_refresh(settings.database_path, payload, content_hash)

    payload["briefing"] = _briefing_or_fallback(cached)
    payload["dashboard_hash"] = content_hash
    payload["briefing_stale"] = bool(hash_changed)
    return payload


async def build_dashboard_payload(db_path: str) -> dict[str, Any]:
    now = utc_now()
    today_start, tomorrow_start = local_day_window(now)
    week_end = now + timedelta(days=7)
    longterm_horizon = now + timedelta(days=90)
    now_iso = to_utc_iso(now)

    async with aiosqlite.connect(db_path) as db:
        db.row_factory = aiosqlite.Row
        courses = await _fetchall(db, """
            SELECT id, title, start_at, end_at, location, notes
            FROM server_courses
            WHERE datetime(end_at) >= datetime(?) AND datetime(start_at) < datetime(?)
            ORDER BY datetime(start_at) ASC
            LIMIT 30
        """, (to_utc_iso(today_start), to_utc_iso(tomorrow_start)))
        events = await _fetchall(db, """
            SELECT id, title, start_at, end_at, location, notes, calendar_name
            FROM server_events
            WHERE datetime(end_at) >= datetime(?) AND datetime(start_at) < datetime(?)
            ORDER BY datetime(start_at) ASC
            LIMIT 30
        """, (to_utc_iso(today_start), to_utc_iso(tomorrow_start)))
        overdue_reminders = await _fetchall(db, """
            SELECT id, title, due_at, notes, list_name, is_important
            FROM server_reminders
            WHERE is_completed=0 AND due_at IS NOT NULL AND datetime(due_at) < datetime(?)
            ORDER BY datetime(due_at) ASC
            LIMIT 30
        """, (now_iso,))
        reminders = await _fetchall(db, """
            SELECT id, title, due_at, notes, list_name, is_important
            FROM server_reminders
            WHERE is_completed=0
              AND (due_at IS NULL OR (datetime(due_at) >= datetime(?) AND datetime(due_at) < datetime(?)))
            ORDER BY due_at IS NULL, datetime(due_at) ASC
            LIMIT 30
        """, (now_iso, to_utc_iso(tomorrow_start)))
        memory_items = await _fetchall(db, """
            SELECT id, title, summary, action_hint, importance, kind, category,
                   expires_at, entity_id, source_type, hierarchy_tier
            FROM chaoxing_memory_entries
            WHERE archived_at IS NULL
              AND COALESCE(status, 'active')='active'
              AND (expires_at IS NULL OR datetime(expires_at) >= datetime(?))
              AND importance IN ('high', 'medium')
            ORDER BY CASE importance WHEN 'high' THEN 1 ELSE 2 END,
                     datetime(COALESCE(expires_at, updated_at, extracted_at, sent_at)) ASC
            LIMIT 30
        """, (now_iso,))
        assignments = await _fetchall(db, """
            SELECT id, course_name, title, due_date, status
            FROM chaoxing_assignments
            WHERE status IN ('未交', '未提交')
              AND (due_date IS NULL OR datetime(due_date) <= datetime(?))
            ORDER BY due_date IS NULL, datetime(due_date) ASC
            LIMIT 30
        """, (to_utc_iso(week_end),))
        scheduled = await _fetchall(db, """
            SELECT id, title, body, scheduled_at, source_type, source_id, reason
            FROM scheduled_notifications
            WHERE sent_at IS NULL AND cancelled_at IS NULL
              AND datetime(scheduled_at) >= datetime(?) AND datetime(scheduled_at) <= datetime(?)
            ORDER BY datetime(scheduled_at) ASC
            LIMIT 30
        """, (now_iso, to_utc_iso(week_end)))
        far_events = await _fetchall(db, """
            SELECT id, title, start_at, end_at, location
            FROM server_events
            WHERE datetime(start_at) > datetime(?) AND datetime(start_at) <= datetime(?)
            ORDER BY datetime(start_at) ASC
            LIMIT 40
        """, (to_utc_iso(week_end), to_utc_iso(longterm_horizon)))
        far_reminders = await _fetchall(db, """
            SELECT id, title, due_at, notes, is_important
            FROM server_reminders
            WHERE is_completed=0 AND datetime(due_at) > datetime(?) AND datetime(due_at) <= datetime(?)
            ORDER BY datetime(due_at) ASC
            LIMIT 40
        """, (to_utc_iso(week_end), to_utc_iso(longterm_horizon)))
        far_assignments = await _fetchall(db, """
            SELECT id, course_name, title, due_date, status
            FROM chaoxing_assignments
            WHERE status IN ('未交', '未提交')
              AND datetime(due_date) > datetime(?) AND datetime(due_date) <= datetime(?)
            ORDER BY datetime(due_date) ASC
            LIMIT 40
        """, (to_utc_iso(week_end), to_utc_iso(longterm_horizon)))
        far_memory = await _fetchall(db, """
            SELECT id, title, summary, action_hint, importance, expires_at
            FROM chaoxing_memory_entries
            WHERE archived_at IS NULL
              AND COALESCE(status, 'active')='active'
              AND datetime(expires_at) > datetime(?) AND datetime(expires_at) <= datetime(?)
            ORDER BY datetime(expires_at) ASC
            LIMIT 40
        """, (to_utc_iso(week_end), to_utc_iso(longterm_horizon)))
        notifications = await _fetchall(db, """
            SELECT id, item_id, notif_type, sent_at, clicked_at, dismissed_at,
                   push_title AS title, push_body AS body
            FROM notification_log
            ORDER BY datetime(sent_at) DESC
            LIMIT 20
        """)
        feedback_rows = await _fetchall(db, """
            SELECT action, COUNT(*) AS count
            FROM notification_feedback
            WHERE datetime(created_at) >= datetime(?)
            GROUP BY action
        """, (to_utc_iso(now - timedelta(days=7)),))
        audits = await _fetchall(db, """
            SELECT id, conversation_id, tool_name, sql_or_op, result_summary, created_at
            FROM agent_audit_log
            ORDER BY datetime(created_at) DESC
            LIMIT 20
        """)

    overdue = _dedupe([
        _overdue_todo(r["id"], r["title"], r.get("due_at"), "high" if r.get("is_important") else "medium", r.get("notes"), now)
        for r in overdue_reminders
    ])
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
    seen = {i["key"] for i in plan} | {i["key"] for i in upcoming}
    longterm = [
        item for item in _dedupe([
            *[_event("event", e["id"], e["title"], e["start_at"], e["end_at"], e.get("location")) for e in far_events],
            *[_todo("reminder", r["id"], r["title"], r.get("due_at"), "high" if r.get("is_important") else "medium", r.get("notes")) for r in far_reminders],
            *[_todo("assignment", a["id"], f"{a.get('course_name') or '学习通'}：{a['title']}", a.get("due_date"), "medium", a.get("status")) for a in far_assignments],
            *[_todo("memory", m["id"], m["title"], m.get("expires_at"), m.get("importance"), m.get("action_hint") or m.get("summary")) for m in far_memory],
        ])
        if item["key"] not in seen
    ]

    used = await tokens_used_today(db_path, now)
    limit = await daily_token_budget(db_path)
    local = now.astimezone(LOCAL_TZ)
    return {
        "date": local.date().isoformat(),
        "now": local.isoformat(),
        "overdue": sorted(overdue, key=lambda x: x.get("sort_at") or "9999")[:40],
        "plan": sorted(plan, key=lambda x: x.get("sort_at") or "9999")[:40],
        "upcoming": sorted(upcoming, key=lambda x: x.get("sort_at") or "9999")[:40],
        "longterm": sorted(longterm, key=lambda x: x.get("sort_at") or "9999")[:40],
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
            "open_reminders": len(reminders) + len(overdue_reminders),
            "overdue_reminders": len(overdue_reminders),
            "active_memory": len(memory_items),
            "upcoming_notifications": len(scheduled),
        },
    }


def dashboard_hash(payload: dict[str, Any]) -> str:
    relevant = {
        key: payload.get(key)
        for key in ("overdue", "plan", "upcoming", "longterm", "counts")
    }
    raw = json.dumps(relevant, ensure_ascii=False, sort_keys=True, separators=(",", ":"))
    return hashlib.sha256(raw.encode("utf-8")).hexdigest()[:16]


async def load_briefing(db_path: str) -> dict[str, Any]:
    async with aiosqlite.connect(db_path) as db:
        rows = await (await db.execute(
            "SELECT key, value FROM chaoxing_sync_state WHERE key IN (?,?,?,?)",
            (_HASH_KEY, _TEXT_KEY, _TODOS_KEY, _TS_KEY),
        )).fetchall()
    kv = {k: v for k, v in rows}
    todos = []
    if kv.get(_TODOS_KEY):
        try:
            todos = json.loads(kv[_TODOS_KEY]) or []
        except (json.JSONDecodeError, TypeError):
            todos = []
    return {
        "hash": kv.get(_HASH_KEY),
        "text": kv.get(_TEXT_KEY),
        "todos": todos,
        "generated_at": kv.get(_TS_KEY),
    }


async def refresh_briefing(db_path: str, payload: dict[str, Any] | None = None, content_hash: str | None = None) -> dict[str, Any]:
    payload = payload or await build_dashboard_payload(db_path)
    content_hash = content_hash or dashboard_hash(payload)
    try:
        provider, model, api_key = await _resolve_schedule_provider()
        provider, model, api_key = await resolve_light_agent_provider(provider, model, api_key)
        response = await agent_complete(
            [
                AgentMsg(role="system", content=_briefing_system_prompt()),
                AgentMsg(role="user", content=json.dumps(_brief_payload(payload), ensure_ascii=False)),
            ],
            [], provider, model, api_key,
        )
        if response.usage:
            log_usage_later(db_path, "dashboard_briefing", provider.get("id", ""), model, response.usage)
        text, todos = _parse_briefing_json(response.text or "")
        if not text:
            raise ValueError("empty briefing")
    except Exception:
        fallback = _fallback_briefing(payload)
        text, todos = fallback["text"], fallback["todos"]
    now_iso = to_utc_iso(utc_now())
    async with aiosqlite.connect(db_path) as db:
        for key, value in (
            (_HASH_KEY, content_hash),
            (_TEXT_KEY, text),
            (_TODOS_KEY, json.dumps(todos, ensure_ascii=False)),
            (_TS_KEY, now_iso),
        ):
            await db.execute("INSERT OR REPLACE INTO chaoxing_sync_state (key, value) VALUES (?,?)", (key, value))
        await db.commit()
    return {"hash": content_hash, "text": text, "todos": todos, "generated_at": now_iso}


def _schedule_refresh(db_path: str, payload: dict[str, Any], content_hash: str) -> None:
    if content_hash in _IN_FLIGHT:
        return
    _IN_FLIGHT.add(content_hash)

    async def _run():
        try:
            await refresh_briefing(db_path, payload, content_hash)
        finally:
            _IN_FLIGHT.discard(content_hash)

    asyncio.create_task(_run())


async def _resolve_schedule_provider():
    async with db_conn() as db:
        provider_id_row = await (await db.execute(
            "SELECT value FROM settings WHERE key='schedule_agent_provider_id'"
        )).fetchone()
        provider_id = provider_id_row["value"] if provider_id_row else "openai"
        sched_provider = await (await db.execute(
            "SELECT value FROM settings WHERE key='schedule_agent_provider'"
        )).fetchone()
    provider, api_key = await resolve_provider(provider_id)
    model = (provider.get("models") or ["gpt-4o-mini"])[0]
    if sched_provider:
        try:
            prov_data = json.loads(sched_provider[0])
            provider = {"api_type": prov_data.get("api_type", "openAI"), "base_url": prov_data.get("base_url", "")}
            api_key = prov_data.get("api_key", api_key)
            model = prov_data.get("model", model)
        except json.JSONDecodeError:
            pass
    return provider, model, api_key


async def _fetchall(db, sql: str, params: tuple = ()) -> list[dict[str, Any]]:
    rows = await (await db.execute(sql, params)).fetchall()
    return [dict(r) for r in rows]


def _event(source: str, row_id: str, title: str, start_at: str, end_at: str, location: str | None) -> dict:
    return {"key": f"{source}:{row_id}", "source": source, "kind": "event", "title": title, "start_at": start_at, "end_at": end_at, "location": location or "", "sort_at": start_at}


def _todo(source: str, row_id: str, title: str, due_at: str | None, importance: str | None, detail: str | None) -> dict:
    return {"key": f"{source}:{row_id}", "source": source, "kind": "todo", "title": title, "due_at": due_at, "importance": importance or "medium", "detail": detail or "", "sort_at": due_at or ""}


def _overdue_todo(row_id: str, title: str, due_at: str | None, importance: str | None, detail: str | None, now) -> dict:
    item = _todo("reminder", row_id, title, due_at, importance, detail)
    item["overdue"] = True
    due = parse_any_time(due_at)
    if due:
        item["overdue_days"] = max(0, (now.astimezone(LOCAL_TZ).date() - due.astimezone(LOCAL_TZ).date()).days)
    else:
        item["overdue_days"] = 0
    return item


def _dedupe(items: list[dict]) -> list[dict]:
    out: list[dict] = []
    seen: set[str] = set()
    for item in items:
        key = item.get("key")
        if key and key not in seen:
            seen.add(key)
            out.append(item)
    return out


def _brief_payload(payload: dict[str, Any]) -> dict[str, Any]:
    def slim(items):
        return [
            {k: item.get(k) for k in ("key", "source", "kind", "title", "due_at", "start_at", "end_at", "importance", "detail", "sort_at") if item.get(k)}
            for item in items[:12]
        ]
    return {
        "date": payload.get("date"),
        "now": payload.get("now"),
        "overdue": slim(payload.get("overdue") or []),
        "plan": slim(payload.get("plan") or []),
        "upcoming": slim(payload.get("upcoming") or []),
        "longterm": slim(payload.get("longterm") or []),
        "counts": payload.get("counts") or {},
    }


def _briefing_system_prompt() -> str:
    return (
        "你是轻量 dashboard briefing agent。只基于输入 JSON，总结今天重点。"
        "输出严格 JSON：{\"briefing\":\"一句自然中文\",\"todos\":[{\"title\":\"短标题\",\"detail\":\"一句理由\",\"when\":\"时间线索\",\"urgency\":\"high|medium|low\"}]}。"
        "最多 5 个 todos；不要编造输入里没有的事项。"
    )


def _parse_briefing_json(raw: str) -> tuple[str, list]:
    start = raw.find("{")
    end = raw.rfind("}")
    if start >= 0 and end > start:
        try:
            obj = json.loads(raw[start:end + 1])
            text = (obj.get("briefing") or "").strip()
            todos = obj.get("todos") if isinstance(obj.get("todos"), list) else []
            return text, [_clean_todo(t) for t in todos[:5] if isinstance(t, dict) and t.get("title")]
        except json.JSONDecodeError:
            pass
    return raw.strip(), []


def _clean_todo(todo: dict[str, Any]) -> dict[str, str]:
    urgency = str(todo.get("urgency") or "medium").lower()
    if urgency not in ("high", "medium", "low"):
        urgency = "medium"
    return {
        "title": str(todo.get("title") or "").strip()[:40],
        "detail": str(todo.get("detail") or "").strip()[:180],
        "when": str(todo.get("when") or "").strip()[:40],
        "urgency": urgency,
    }


def _briefing_or_fallback(cached: dict[str, Any]) -> dict[str, Any]:
    if cached.get("text"):
        return {"text": cached.get("text"), "todos": cached.get("todos") or [], "generated_at": cached.get("generated_at")}
    return {"text": "今天的重点正在整理。", "todos": [], "generated_at": None}


def _fallback_briefing(payload: dict[str, Any]) -> dict[str, Any]:
    candidates = (payload.get("overdue") or []) + (payload.get("plan") or []) + (payload.get("upcoming") or [])
    todos = []
    for item in candidates[:5]:
        todos.append({
            "title": item.get("title", "")[:40],
            "detail": item.get("detail") or item.get("location") or "",
            "when": item.get("due_at") or item.get("start_at") or "",
            "urgency": "high" if item.get("overdue") or item.get("importance") == "high" else "medium",
        })
    text = "今天没有特别紧急的事项。" if not todos else f"今天有 {len(todos)} 件事值得优先看。"
    return {"text": text, "todos": todos}
