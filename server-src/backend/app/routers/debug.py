"""
Debug endpoints — only mounted when settings.debug == True.
NEVER expose in production.

Usage:
  curl http://localhost:8080/api/debug/sse
  curl -X POST http://localhost:8080/api/debug/agent
  curl -X POST http://localhost:8080/api/debug/push -H "Content-Type: application/json" \
       -d '{"title":"Test","body":"Hello"}'
  curl http://localhost:8080/api/debug/db
  curl http://localhost:8080/api/debug/scheduler
  curl -X POST http://localhost:8080/api/debug/standby
"""

from fastapi import APIRouter, Request
from fastapi.responses import StreamingResponse
import json
import asyncio
import time
from app.database import db_conn
from app.config import settings

router = APIRouter(prefix="/api/debug", tags=["debug"])


@router.get("/sse")
async def debug_sse():
    """Stream 10 tokens. If you see them all at once at the end, nginx is buffering — fix nginx.conf."""
    async def generate():
        for i in range(10):
            yield f"data: {json.dumps({'type': 'text', 'content': f'token_{i} '})}\n\n"
            await asyncio.sleep(0.2)
        yield f"data: {json.dumps({'type': 'done'})}\n\n"

    return StreamingResponse(
        generate(),
        media_type="text/event-stream",
        headers={"Cache-Control": "no-cache", "X-Accel-Buffering": "no"},
    )


@router.post("/agent")
async def debug_agent(body: dict = {}):
    """
    Test the agentic loop end-to-end with a fake echo tool.
    Body: {"provider_id": "openai", "model": "gpt-4o-mini", "message": "ping"}
    """
    from app.services.agent_service import AgentMsg, ToolDefinition, run_agentic_loop
    from app.services.provider_registry import resolve_provider

    provider_id = body.get("provider_id", "xiaomimimo")
    model       = body.get("model", "mimo-v2.5-pro")
    message     = body.get("message", "Call the echo tool with input 'hello'.")

    provider, api_key = await resolve_provider(provider_id)
    if not api_key:
        return {"error": f"No API key for provider: {provider_id}"}

    echo_tool = ToolDefinition(
        name="echo",
        description="Echo back the input string.",
        input_schema={
            "type": "object",
            "properties": {"input": {"type": "string"}},
            "required": ["input"],
            "additionalProperties": False,
        },
    )

    async def executor(tc):
        return f"Echo: {tc.arguments.get('input', '')}"

    events = []
    async for event in run_agentic_loop(
        [AgentMsg(role="user", content=message)],
        [echo_tool],
        executor,
        provider, model, api_key,
        max_iterations=3,
    ):
        events.append(event)

    return {"events": events, "provider": provider_id, "model": model}


@router.post("/push")
async def debug_push(body: dict = {}):
    """
    Send a test push to all subscribers.
    Body: {"title": "...", "body": "..."}
    """
    from app.services.push_service import send_push_to_all_subscribers

    title = body.get("title", "Debug Push")
    text  = body.get("body",  f"Test at {__import__('datetime').datetime.now().strftime('%H:%M:%S')}")

    result = await send_push_to_all_subscribers(
        settings.database_path,
        title=title,
        body=text,
        tag="debug-push",
        data={"type": "debug"},
    )
    return result


@router.get("/db")
async def debug_db():
    """Show table row counts and WAL mode status."""
    tables = [
        "conversations", "messages", "schedule_messages",
        "chaoxing_memory_entries", "chaoxing_processed_ids",
        "push_subscriptions", "notification_log", "standby_agent_log",
        "settings", "server_reminders",
    ]
    counts = {}
    wal_mode = None

    async with db_conn() as db:
        for t in tables:
            try:
                row = await (await db.execute(f"SELECT COUNT(*) FROM {t}")).fetchone()
                counts[t] = row[0]
            except Exception as e:
                counts[t] = f"ERROR: {e}"
        row = await (await db.execute("PRAGMA journal_mode")).fetchone()
        wal_mode = row[0] if row else "unknown"

    return {"wal_mode": wal_mode, "table_counts": counts}


@router.get("/scheduler")
async def debug_scheduler():
    """List all scheduled jobs and their next run times."""
    from app.tasks.scheduler import scheduler

    jobs = []
    for job in scheduler.get_jobs():
        jobs.append({
            "id":       job.id,
            "name":     job.name,
            "next_run": job.next_run_time.isoformat() if job.next_run_time else None,
            "trigger":  str(job.trigger),
        })
    return {"jobs": jobs, "running": scheduler.running}


@router.post("/standby")
async def debug_standby(request: Request):
    """Manually trigger one standby agent run. Returns the decision and log entry."""
    from app.tasks.standby_agent import run_standby_agent

    app_state = request.app.state
    await run_standby_agent(app_state)

    # Return last log entry
    async with db_conn() as db:
        row = await (await db.execute(
            "SELECT * FROM standby_agent_log ORDER BY id DESC LIMIT 1"
        )).fetchone()
    return dict(row) if row else {"error": "no log entry found"}


@router.get("/chaoxing")
async def debug_chaoxing(request: Request):
    """Show Chaoxing login state and last sync info."""
    svc = request.app.state.chaoxing_svc

    async with db_conn() as db:
        probe_count = (await (await db.execute(
            "SELECT COUNT(*) FROM chaoxing_probe_signatures"
        )).fetchone())[0]
        processed_count = (await (await db.execute(
            "SELECT COUNT(*) FROM chaoxing_processed_ids"
        )).fetchone())[0]
        memory_count = (await (await db.execute(
            "SELECT COUNT(*) FROM chaoxing_memory_entries WHERE archived_at IS NULL"
        )).fetchone())[0]
        sync_state = await (await db.execute(
            "SELECT key, value FROM chaoxing_sync_state"
        )).fetchall()

    return {
        "is_logged_in":      svc.is_logged_in,
        "uid":               svc.uid,
        "username":          svc.username,
        "probe_signatures":  probe_count,
        "processed_ids":     processed_count,
        "active_memories":   memory_count,
        "sync_state":        {r["key"]: r["value"] for r in sync_state},
    }
