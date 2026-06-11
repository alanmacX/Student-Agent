from __future__ import annotations

from fastapi import APIRouter, Request
from app.models import ChaoxingLogin, ChaoxingVerify
from app.database import db_conn

router = APIRouter(prefix="/api/chaoxing", tags=["chaoxing"])


@router.get("/status")
async def get_status(request: Request):
    chaoxing_svc = request.app.state.chaoxing_svc
    return {
        "logged_in": chaoxing_svc.is_logged_in,
        "uid": chaoxing_svc.uid,
        "username": chaoxing_svc.username,
    }


@router.post("/login")
async def request_otp(body: ChaoxingLogin, request: Request):
    chaoxing_svc = request.app.state.chaoxing_svc
    ok = await chaoxing_svc.request_otp(body.phone)
    return {"ok": ok}


@router.post("/verify")
async def verify_otp(body: ChaoxingVerify, request: Request):
    chaoxing_svc = request.app.state.chaoxing_svc
    ok = await chaoxing_svc.verify_otp(body.phone, body.code)
    return {"ok": ok}


@router.post("/logout")
async def logout(request: Request):
    chaoxing_svc = request.app.state.chaoxing_svc
    await chaoxing_svc.logout()
    return {"ok": True}


@router.post("/qr/start")
async def start_qr_login(request: Request):
    chaoxing_svc = request.app.state.chaoxing_svc
    try:
        return await chaoxing_svc.create_qr_session()
    except Exception as e:
        return {"error": str(e)}


@router.post("/qr/poll")
async def poll_qr_login(body: dict, request: Request):
    chaoxing_svc = request.app.state.chaoxing_svc
    try:
        return await chaoxing_svc.poll_qr(body.get("uuid", ""), body.get("enc", ""))
    except Exception as e:
        return {"status": "failed", "message": str(e)}


@router.get("/courses")
async def get_courses(request: Request):
    chaoxing_svc = request.app.state.chaoxing_svc
    return await chaoxing_svc.fetch_courses()


@router.get("/assignments")
async def get_assignments(request: Request):
    chaoxing_svc = request.app.state.chaoxing_svc
    return await chaoxing_svc.fetch_all_pending_assignments()


@router.get("/memory")
async def get_memory():
    async with db_conn() as db:
        rows = await (await db.execute("""
            SELECT id, title, summary, importance, action_hint, sent_at, expires_at, archived_at
            FROM chaoxing_memory_entries
            WHERE archived_at IS NULL
            ORDER BY CASE importance WHEN 'high' THEN 1 WHEN 'medium' THEN 2 ELSE 3 END, sent_at DESC
        """)).fetchall()
        return [dict(r) for r in rows]


@router.post("/memory/sync")
async def sync_memory(request: Request):
    """Trigger Chaoxing memory reconciliation manually."""
    from app.chaoxing.memory_provider import run_chaoxing_memory_sync
    from app.services.provider_registry import resolve_provider
    from app.config import settings

    chaoxing_svc = request.app.state.chaoxing_svc
    if not chaoxing_svc.is_logged_in:
        return {"error": "not logged in"}

    provider, api_key = await resolve_provider(
        settings.standby_agent_provider or "openai"
    )
    model = settings.standby_agent_model or "gpt-4o-mini"
    try:
        result = await run_chaoxing_memory_sync(
            chaoxing_svc, settings.database_path,
            provider, model, api_key,
        )
        return result
    except Exception as e:
        return {"error": str(e), "candidate_count": 0, "processed_count": 0}


@router.post("/memory/{memory_id}/archive")
async def archive_memory(memory_id: str):
    """Archive a memory entry by setting archived_at."""
    from datetime import datetime, timezone
    now = datetime.now(timezone.utc).isoformat()
    async with db_conn() as db:
        cur = await db.execute(
            "UPDATE chaoxing_memory_entries SET archived_at=? WHERE id=? AND archived_at IS NULL",
            (now, memory_id),
        )
        await db.commit()
    if cur.rowcount == 0:
        return {"ok": False, "error": "not_found_or_archived"}
    return {"ok": True, "id": memory_id, "archived_at": now}


@router.get("/muted-conversations")
async def get_muted():
    async with db_conn() as db:
        row = await (await db.execute("SELECT value FROM settings WHERE key='chaoxing_muted_conversations'")).fetchone()
        if row:
            try:
                return {"muted": __import__("json").loads(row[0])}
            except Exception:
                pass
        return {"muted": []}


@router.put("/muted-conversations")
async def set_muted(body: dict):
    import json
    async with db_conn() as db:
        await db.execute(
            "INSERT OR REPLACE INTO settings (key, value) VALUES ('chaoxing_muted_conversations', ?)",
            (json.dumps(body.get("muted", [])),),
        )
        await db.commit()
        return {"ok": True}
