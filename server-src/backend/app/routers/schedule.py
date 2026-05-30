from __future__ import annotations

from fastapi import APIRouter, Request
from fastapi.responses import StreamingResponse
import json
import asyncio
import uuid
from datetime import datetime
from app.database import db_conn
from app.services.schedule_agent import (
    execute_confirmed_pending_mutation,
    run_schedule_agent,
)
from app.config import settings
from app.services.provider_registry import resolve_provider
from app.services.schedule_store import list_courses, list_events, list_reminders

router = APIRouter(prefix="/api/schedule", tags=["schedule"])


# ── Session management ────────────────────────────────────────────────────────

@router.get("/sessions")
async def list_sessions():
    async with db_conn() as db:
        rows = await (await db.execute(
            "SELECT id, title, created_at, updated_at FROM schedule_sessions ORDER BY updated_at DESC"
        )).fetchall()
        return [dict(r) for r in rows]


@router.post("/sessions")
async def create_session(request: Request):
    body = await request.json()
    title = body.get("title", "新对话").strip() or "新对话"
    now = datetime.utcnow().isoformat()
    session_id = str(uuid.uuid4())
    async with db_conn() as db:
        await db.execute(
            "INSERT INTO schedule_sessions (id, title, created_at, updated_at) VALUES (?,?,?,?)",
            (session_id, title, now, now),
        )
        await db.commit()
    return {"id": session_id, "title": title, "created_at": now, "updated_at": now}


@router.patch("/sessions/{session_id}")
async def rename_session(session_id: str, request: Request):
    body = await request.json()
    title = body.get("title", "").strip()
    if not title:
        return {"error": "title required"}
    now = datetime.utcnow().isoformat()
    async with db_conn() as db:
        await db.execute(
            "UPDATE schedule_sessions SET title=?, updated_at=? WHERE id=?",
            (title, now, session_id),
        )
        await db.commit()
    return {"ok": True}


@router.delete("/sessions/{session_id}")
async def delete_session(session_id: str):
    async with db_conn() as db:
        await db.execute("DELETE FROM schedule_messages WHERE session_id=?", (session_id,))
        await db.execute("DELETE FROM schedule_sessions WHERE id=?", (session_id,))
        await db.commit()
    return {"ok": True}


@router.get("/sessions/{session_id}/messages")
async def list_session_messages(session_id: str):
    async with db_conn() as db:
        rows = await (await db.execute(
            "SELECT id, role, content, reasoning_content, usage_json, schedule_payload_json, timestamp, position "
            "FROM schedule_messages WHERE session_id=? ORDER BY position",
            (session_id,),
        )).fetchall()
        return [dict(r) for r in rows]


@router.delete("/sessions/{session_id}/messages")
async def clear_session_messages(session_id: str):
    async with db_conn() as db:
        await db.execute("DELETE FROM schedule_messages WHERE session_id=?", (session_id,))
        await db.commit()
    return {"ok": True}


# ── Legacy: default session (backward compat) ─────────────────────────────────

@router.get("/messages")
async def list_schedule_messages():
    async with db_conn() as db:
        rows = await (await db.execute(
            "SELECT id, role, content, reasoning_content, usage_json, schedule_payload_json, timestamp, position "
            "FROM schedule_messages WHERE session_id='default' ORDER BY position"
        )).fetchall()
        return [dict(r) for r in rows]


@router.delete("/messages")
async def clear_schedule_messages():
    async with db_conn() as db:
        await db.execute("DELETE FROM schedule_messages WHERE session_id='default'")
        await db.commit()
        return {"ok": True}


async def _ensure_session_exists(db, session_id: str, now: str):
    """Create the session row if it doesn't already exist."""
    row = await (await db.execute(
        "SELECT id FROM schedule_sessions WHERE id=?", (session_id,)
    )).fetchone()
    if not row:
        await db.execute(
            "INSERT OR IGNORE INTO schedule_sessions (id, title, created_at, updated_at) VALUES (?,?,?,?)",
            (session_id, "新对话", now, now),
        )
        await db.commit()


async def _handle_slash_command(cmd: str, db_path: str, chaoxing_svc) -> tuple[str, dict | None]:
    """Handle /status, /scan, /memory, /push commands deterministically (no LLM)."""
    import aiosqlite
    cmd = cmd.strip().lower()

    if cmd == "/status":
        async with aiosqlite.connect(db_path) as db:
            memory_count = (await (await db.execute(
                "SELECT COUNT(*) FROM chaoxing_memory_entries WHERE archived_at IS NULL"
            )).fetchone())[0]
            pending_notifs = (await (await db.execute(
                "SELECT COUNT(*) FROM scheduled_notifications WHERE sent_at IS NULL AND cancelled_at IS NULL"
            )).fetchone())[0]
            sub_count = (await (await db.execute(
                "SELECT COUNT(*) FROM push_subscriptions"
            )).fetchone())[0]
            standby_row = await (await db.execute(
                "SELECT decision, ran_at FROM standby_agent_log ORDER BY ran_at DESC LIMIT 1"
            )).fetchone()
            courses_count = (await (await db.execute(
                "SELECT COUNT(*) FROM chaoxing_courses"
            )).fetchone())[0]
            assign_count = (await (await db.execute(
                "SELECT COUNT(*) FROM chaoxing_assignments"
            )).fetchone())[0]
        standby_info = f"最近决策: {standby_row[0]} ({standby_row[1][:16]})" if standby_row else "暂无决策记录"
        text = (
            f"**系统状态**\n\n"
            f"- 学习通: {'已登录' if chaoxing_svc.is_logged_in else '未登录'}\n"
            f"- 课程缓存: {courses_count} 门\n"
            f"- 作业缓存: {assign_count} 项\n"
            f"- 活跃 Memory: {memory_count} 条\n"
            f"- 待发通知: {pending_notifs} 条\n"
            f"- 推送订阅: {sub_count} 个设备\n"
            f"- {standby_info}"
        )
        return text, None

    elif cmd == "/scan":
        import asyncio
        from app.tasks.memory_sweep import run_memory_sweep
        asyncio.create_task(run_memory_sweep(db_path))
        return "已触发学习通扫描，结果将在约 1 分钟内更新。", None

    elif cmd == "/memory":
        async with aiosqlite.connect(db_path) as db:
            rows = await (await db.execute("""
                SELECT id, title, summary, action_hint, importance, kind,
                       COALESCE(content_time, expires_at, sent_at) AS date_hint,
                       expires_at
                FROM chaoxing_memory_entries
                WHERE archived_at IS NULL
                  AND (expires_at IS NULL OR expires_at > datetime('now'))
                  AND importance IN ('high', 'medium')
                ORDER BY CASE importance WHEN 'high' THEN 1 ELSE 2 END,
                         COALESCE(content_time, expires_at, sent_at) ASC
                LIMIT 15
            """)).fetchall()
            entries = [dict(r) for r in rows]
        if not entries:
            return "暂无活跃 Memory 条目。", None
        payload = {
            "chaoxing_messages": entries,
        }
        return f"共 {len(entries)} 条活跃 Memory（高优/中优）：", payload

    elif cmd == "/push":
        async with aiosqlite.connect(db_path) as db:
            sub_count = (await (await db.execute(
                "SELECT COUNT(*) FROM push_subscriptions"
            )).fetchone())[0]
            pending_rows = await (await db.execute("""
                SELECT id, title, scheduled_at FROM scheduled_notifications
                WHERE sent_at IS NULL AND cancelled_at IS NULL
                ORDER BY scheduled_at ASC LIMIT 10
            """)).fetchall()
            standby_rows = await (await db.execute("""
                SELECT decision, reason, ran_at FROM standby_agent_log
                ORDER BY ran_at DESC LIMIT 5
            """)).fetchall()
        pending = [dict(r) for r in pending_rows]
        standby = [dict(r) for r in standby_rows]
        lines = [
            f"**推送状态**\n\n",
            f"- 订阅设备: {sub_count} 个\n",
            f"- 待发通知: {len(pending)} 条\n",
        ]
        if pending:
            lines.append("\n**待发通知:**\n")
            for p in pending:
                lines.append(f"  - {p['title']} (计划 {p['scheduled_at'][:16]})\n")
        if standby:
            lines.append("\n**最近决策:**\n")
            for s in standby:
                lines.append(f"  - {s['decision']}: {s.get('reason', '')} ({s['ran_at'][:16]})\n")
        text = "".join(lines)
        return text, None

    else:
        return f"未知命令: {cmd}\n\n可用命令: /status /scan /memory /push", None


@router.post("/chat")
async def stream_schedule_chat(request: Request):
    body = await request.json()
    user_message = body.get("message", "").strip()
    session_id = body.get("session_id", "default") or "default"
    if not user_message:
        return {"error": "empty message"}

    async with db_conn() as db:
        now = datetime.utcnow().isoformat()

        # Ensure session row exists
        await _ensure_session_exists(db, session_id, now)

        # Save user message
        pos_row = await (await db.execute(
            "SELECT MAX(position) FROM schedule_messages WHERE session_id=?", (session_id,)
        )).fetchone()
        next_pos = (pos_row[0] or 0) + 1

        await db.execute(
            "INSERT INTO schedule_messages (id, session_id, role, content, timestamp, position) VALUES (?,?,?,?,?,?)",
            (str(uuid.uuid4()), session_id, "user", user_message, now, next_pos),
        )

        # Auto-set title from first user message
        title_row = await (await db.execute(
            "SELECT title FROM schedule_sessions WHERE id=?", (session_id,)
        )).fetchone()
        if title_row and title_row[0] == "新对话":
            auto_title = user_message[:30]
            await db.execute(
                "UPDATE schedule_sessions SET title=?, updated_at=? WHERE id=?",
                (auto_title, now, session_id),
            )
        else:
            await db.execute(
                "UPDATE schedule_sessions SET updated_at=? WHERE id=?",
                (now, session_id),
            )

        await db.commit()
        next_pos += 1

        # Load history (last 20 turns = 40 messages to stay within token budget)
        history_rows = await (await db.execute(
            "SELECT role, content FROM schedule_messages WHERE session_id=? ORDER BY position DESC LIMIT 40",
            (session_id,),
        )).fetchall()
        history = list(reversed([dict(r) for r in history_rows]))

    # ── Slash command router (zero LLM) ───────────────────────────────────────
    if user_message.startswith("/"):
        async def generate_slash():
            nonlocal next_pos
            text, payload = await _handle_slash_command(user_message, settings.database_path, request.app.state.chaoxing_svc)
            yield f"data: {json.dumps({'type': 'text', 'content': text}, ensure_ascii=False)}\n\n"
            if payload:
                yield f"data: {json.dumps({'type': 'schedule_payload', **payload}, ensure_ascii=False)}\n\n"
            async with db_conn() as db:
                payload_json = json.dumps(payload) if payload else None
                await db.execute(
                    "INSERT INTO schedule_messages (id, session_id, role, content, schedule_payload_json, timestamp, position) VALUES (?,?,?,?,?,?,?)",
                    (str(uuid.uuid4()), session_id, "assistant", text, payload_json, datetime.utcnow().isoformat(), next_pos),
                )
                await db.commit()
            yield f"data: {json.dumps({'type': 'done'})}\n\n"

        return StreamingResponse(
            generate_slash(),
            media_type="text/event-stream",
            headers={
                "Cache-Control": "no-cache",
                "X-Accel-Buffering": "no",
                "Connection": "keep-alive",
            },
        )

    chaoxing_svc = request.app.state.chaoxing_svc

    confirmed_pending = await execute_confirmed_pending_mutation(
        user_message, chaoxing_svc, settings.database_path
    )
    if confirmed_pending:
        async def generate_confirmed():
            nonlocal next_pos
            text = confirmed_pending["text"]
            yield f"data: {json.dumps({'type': 'text', 'content': text}, ensure_ascii=False)}\n\n"
            async with db_conn() as db:
                await db.execute(
                    "INSERT INTO schedule_messages (id, session_id, role, content, timestamp, position) VALUES (?,?,?,?,?,?)",
                    (str(uuid.uuid4()), session_id, "assistant", text, datetime.utcnow().isoformat(), next_pos),
                )
                await db.commit()
            yield f"data: {json.dumps({'type': 'done'})}\n\n"

        return StreamingResponse(
            generate_confirmed(),
            media_type="text/event-stream",
            headers={
                "Cache-Control": "no-cache",
                "X-Accel-Buffering": "no",
                "Connection": "keep-alive",
            },
        )

    # NOTE: the old keyword-based `detect_and_store_pending_mutation` pre-filter
    # was REMOVED. It guessed intent by string-matching ("提醒"/"创建" anywhere in
    # the message) BEFORE the LLM ran, which misfired badly — e.g. the question
    # "我没看到你放在提醒事项里啊" contains "提醒" and got turned into a
    # create_reminder with the user's own sentence as the title. Reminder/event
    # creation now goes exclusively through the LLM agent, where create_reminder
    # itself calls _require_confirmation and emits the pending_confirmation event
    # (rendered as confirm/cancel buttons in the UI).

    # Resolve provider from the same registry used by normal chat, so DB-saved keys
    # and built-in MiMo/custom providers work for Schedule Agent too.
    async with db_conn() as db:
        provider_id_row = await (await db.execute(
            "SELECT value FROM settings WHERE key='schedule_agent_provider_id'"
        )).fetchone()
        provider_id = provider_id_row["value"] if provider_id_row else "openai"

        # Check if custom schedule provider is configured
        sched_provider = await (await db.execute(
            "SELECT value FROM settings WHERE key='schedule_agent_provider'"
        )).fetchone()

    provider, api_key = await resolve_provider(provider_id)
    model = (provider.get("models") or ["gpt-4o-mini"])[0]

    if provider.get("id") == "openai":
        model = "gpt-4o-mini"
    if not api_key and provider.get("id") == "openai":
        fallback_provider, fallback_key = await resolve_provider("xiaomimimo")
        if fallback_key:
            provider, api_key = fallback_provider, fallback_key
            model = (provider.get("models") or ["mimo-v2.5-pro"])[0]

    if sched_provider:
        try:
            prov_data = json.loads(sched_provider[0])
            provider = {"api_type": prov_data.get("api_type", "openAI"), "base_url": prov_data.get("base_url", "")}
            api_key = prov_data.get("api_key", api_key)
            model = prov_data.get("model", model)
        except json.JSONDecodeError:
            pass

    print(f"[SCHED] provider={provider.get('id')} api_type={provider.get('api_type')} model={model} key={'SET('+str(len(api_key))+')' if api_key else 'EMPTY'} base_url={provider.get('base_url','')}", flush=True)

    async def generate():
        nonlocal next_pos
        full_response = ""
        schedule_payload = None

        try:
            print(f"[SCHED] generate() start, user_message={user_message[:60]!r}", flush=True)
            async for event in run_schedule_agent(
                user_message, history, provider, model, api_key,
                chaoxing_svc, settings.database_path,
            ):
                etype = event.get("type")
                if etype == "text":
                    full_response += event["content"]
                elif etype == "schedule_payload":
                    schedule_payload = event
                elif etype not in ("usage",):
                    print(f"[SCHED] event type={etype}", flush=True)
                yield f"data: {json.dumps(event)}\n\n"

            print(f"[SCHED] generate() done, response_len={len(full_response)}", flush=True)

            # Save assistant message
            async with db_conn() as db:
                payload_json = json.dumps(schedule_payload) if schedule_payload else None
                await db.execute(
                    "INSERT INTO schedule_messages (id, session_id, role, content, schedule_payload_json, timestamp, position) VALUES (?,?,?,?,?,?,?)",
                    (str(uuid.uuid4()), session_id, "assistant", full_response, payload_json, datetime.utcnow().isoformat(), next_pos),
                )
                await db.commit()

            yield f"data: {json.dumps({'type': 'done'})}\n\n"

        except asyncio.CancelledError:
            print(f"[SCHED] generate() cancelled", flush=True)
            yield f"data: {json.dumps({'type': 'cancelled'})}\n\n"
        except Exception as e:
            import traceback
            print(f"[SCHED] generate() EXCEPTION: {type(e).__name__}: {e}", flush=True)
            print(traceback.format_exc(), flush=True)
            yield f"data: {json.dumps({'type': 'error', 'message': str(e)})}\n\n"

    return StreamingResponse(
        generate(),
        media_type="text/event-stream",
        headers={
            "Cache-Control": "no-cache",
            "X-Accel-Buffering": "no",
            "Connection": "keep-alive",
        },
    )


@router.post("/courses/import")
async def import_courses(request: Request):
    """
    Import a weekly repeating timetable into server_courses.
    Body:
    {
        "semester_start": "2025-09-01",   # Monday of week 1
        "courses": [
            {
                "name": "高等数学",
                "day": 1,                 # 1=Monday ... 7=Sunday
                "periods": [1, 2],        # [startPeriod, endPeriod]
                "location": "A101",       # optional
                "teacher": "张老师",      # optional
                "weeks": [1, 16]          # [startWeek, endWeek], inclusive
            }
        ]
    }
    """
    from app.services.schedule_store import import_timetable

    body = await request.json()
    semester_start_str = body.get("semester_start", "")
    courses = body.get("courses", [])
    return await import_timetable(settings.database_path, semester_start_str, courses)


@router.get("/sidebar")
async def get_schedule_sidebar(request: Request):
    """Get sidebar data: courses, assignments, memory insights. Reads from local cache only."""
    chaoxing_svc = request.app.state.chaoxing_svc

    async with db_conn() as db:
        # Read chaoxing courses from cache
        courses_rows = await (await db.execute(
            "SELECT id, name, teacher, image FROM chaoxing_courses ORDER BY name"
        )).fetchall()
        courses = [dict(r) for r in courses_rows]

        # Read chaoxing assignments from cache
        assign_rows = await (await db.execute(
            "SELECT id, course_id, course_name, title, description, due_date, status FROM chaoxing_assignments ORDER BY due_date"
        )).fetchall()
        assignments = [dict(r) for r in assign_rows]

        # Unified memory: assignments + reminders + changed courses + message entries
        rows = await (await db.execute("""
            SELECT id, title, summary, importance, action_hint, kind,
                   COALESCE(content_time, expires_at, sent_at) AS date_hint,
                   expires_at, related_ids_json, dedupe_key
            FROM chaoxing_memory_entries
            WHERE archived_at IS NULL
              AND (expires_at IS NULL OR expires_at > datetime('now'))
              AND importance IN ('high', 'medium')
              AND (
                kind != 'course'
                OR (action_hint IS NOT NULL AND action_hint != '')
                OR expires_at <= datetime('now', '+24 hours')
              )
            ORDER BY
              CASE importance WHEN 'high' THEN 1 ELSE 2 END,
              CASE kind WHEN 'assignment' THEN 1 WHEN 'reminder' THEN 2
                        WHEN 'course' THEN 3 ELSE 4 END,
              COALESCE(content_time, expires_at, sent_at) ASC
            LIMIT 30
        """)).fetchall()
        memory_insights = [dict(r) for r in rows]

        # Stale metadata
        courses_stale = True
        assignments_stale = True
        if courses_rows:
            last_sync = await (await db.execute(
                "SELECT synced_at FROM chaoxing_courses ORDER BY synced_at DESC LIMIT 1"
            )).fetchone()
            if last_sync:
                try:
                    sync_dt = datetime.fromisoformat(last_sync[0])
                    courses_stale = (datetime.now(sync_dt.tzinfo) - sync_dt).total_seconds() > 86400  # 24h
                except Exception:
                    pass
        if assign_rows:
            last_sync = await (await db.execute(
                "SELECT synced_at FROM chaoxing_assignments ORDER BY synced_at DESC LIMIT 1"
            )).fetchone()
            if last_sync:
                try:
                    sync_dt = datetime.fromisoformat(last_sync[0])
                    assignments_stale = (datetime.now(sync_dt.tzinfo) - sync_dt).total_seconds() > 1800  # 30min
                except Exception:
                    pass

        # Memory scan staleness
        memory_stale = True
        last_scan_row = await (await db.execute(
            "SELECT updated_at FROM chaoxing_memory_entries WHERE kind='message' ORDER BY updated_at DESC LIMIT 1"
        )).fetchone()
        if last_scan_row and last_scan_row[0]:
            try:
                scan_dt = datetime.fromisoformat(last_scan_row[0])
                memory_stale = (datetime.now(scan_dt.tzinfo) - scan_dt).total_seconds() > 1800
            except Exception:
                pass

    courses_local = await list_courses(settings.database_path, days=14)
    events = await list_events(settings.database_path, days=14)
    reminders = await list_reminders(settings.database_path)

    from app.services.dashboard_briefing import load_briefing
    briefing = await load_briefing(settings.database_path)

    return {
        "chaoxing_logged_in": chaoxing_svc.is_logged_in,
        "courses": courses,
        "local_courses": courses_local,
        "events": events,
        "week_events": events,
        "reminders": reminders,
        "assignments": assignments,
        "memory_insights": memory_insights,
        "briefing": briefing,
        "health": {
            "courses_stale": courses_stale,
            "assignments_stale": assignments_stale,
            "memory_stale": memory_stale,
        },
    }


async def _resolve_schedule_provider():
    """Resolve the provider/model/api_key used by the schedule agent & briefing,
    mirroring the logic in the chat endpoint."""
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
    if provider.get("id") == "openai":
        model = "gpt-4o-mini"
    if not api_key and provider.get("id") == "openai":
        fallback_provider, fallback_key = await resolve_provider("xiaomimimo")
        if fallback_key:
            provider, api_key = fallback_provider, fallback_key
            model = (provider.get("models") or ["mimo-v2.5-pro"])[0]
    if sched_provider:
        try:
            prov_data = json.loads(sched_provider[0])
            provider = {"api_type": prov_data.get("api_type", "openAI"), "base_url": prov_data.get("base_url", "")}
            api_key = prov_data.get("api_key", api_key)
            model = prov_data.get("model", model)
        except json.JSONDecodeError:
            pass
    return provider, model, api_key


@router.post("/refresh-briefing")
async def refresh_briefing():
    """Force the dashboard briefing (natural-language summary + LLM todo list) to
    regenerate, then return it. Used by the overview when no briefing exists yet."""
    from app.services.dashboard_briefing import generate_and_store
    provider, model, api_key = await _resolve_schedule_provider()
    briefing = await generate_and_store(
        settings.database_path, provider, model, api_key, force=True
    )
    return {"briefing": briefing}
