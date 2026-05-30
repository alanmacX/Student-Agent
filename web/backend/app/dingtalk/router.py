import os
import signal
import sqlite3
import subprocess
import time
from datetime import datetime, timezone

from fastapi import APIRouter, Query, Request

from app.dingtalk.dingtalk_service import get_conversations
from app.dingtalk.schema import ensure_schema
from app.dingtalk.task import run_dingtalk_sync, bootstrap_to_current

router = APIRouter(prefix="/api/dingtalk", tags=["dingtalk"])

_COLS = (
    "mid, cid, conversation_title, sender_id, sender_name, content_type, "
    "media_type, category, text, raw_content, attachments, is_system, is_group, "
    "has_link, needs_ocr, ocr_status, ocr_text, verdict, verdict_reason, "
    "created_at, synced_at"
)


def _db_path(request: Request) -> str:
    return getattr(getattr(request.app.state, "settings", None), "database_path", "/data/chatbot.db")


def _query(db_path: str, where: str, params: list, limit: int):
    ensure_schema(db_path)
    with sqlite3.connect(db_path) as conn:
        conn.row_factory = sqlite3.Row
        rows = conn.execute(
            f"SELECT {_COLS} FROM dingtalk_messages WHERE {where} "
            f"ORDER BY created_at DESC, mid DESC LIMIT ?",
            (*params, limit),
        ).fetchall()
        return [dict(r) for r in rows]


@router.get("/messages")
async def get_messages(
    request: Request,
    bucket: str = Query("all", pattern="^(all|notify|interest)$"),
    since: int = Query(0, ge=0),
    limit: int = Query(50, ge=1, le=500),
):
    """List stored messages. bucket=notify (push-worthy) | interest (browse) | all."""
    if bucket == "all":
        where, params = "created_at > ?", [since]
    else:
        where, params = "verdict = ? AND created_at > ?", [bucket, since]
    return _query(_db_path(request), where, params, limit)


@router.get("/interest")
async def get_interest(
    request: Request,
    since: int = Query(0, ge=0),
    limit: int = Query(50, ge=1, le=500),
):
    """The "你可能感兴趣" bucket."""
    return _query(_db_path(request), "verdict = ? AND created_at > ?", ["interest", since], limit)


@router.get("/conversations")
async def conversations():
    return get_conversations()


@router.post("/sync")
async def sync(request: Request):
    """Trigger one sync pass (decrypt -> filter -> classify -> store)."""
    return await run_dingtalk_sync(request.app.state)


@router.post("/bootstrap")
async def bootstrap(request: Request):
    """Skip historical backlog: set last_seen to current max timestamp."""
    return bootstrap_to_current(_db_path(request))


@router.post("/memory-sync")
async def memory_sync(request: Request):
    """Run the memory automation engine over new DingTalk messages.

    Independent of the main sync — has its own cursor (memory_sync_state).
    Decrypt/filter must have already populated dingtalk_messages.
    """
    from app.dingtalk.memory_provider import run_dingtalk_memory_sync
    from app.services.provider_registry import resolve_provider
    st = request.app.state
    db_path = _db_path(request)
    provider_id = getattr(getattr(st, "settings", None), "standby_agent_provider", "openai") or "openai"
    model = getattr(getattr(st, "settings", None), "standby_agent_model", "gpt-4o-mini") or "gpt-4o-mini"
    provider, api_key = await resolve_provider(provider_id)
    return await run_dingtalk_memory_sync(db_path, provider, model, api_key)


@router.get("/status")
async def dingtalk_status(request: Request):
    db_path = _db_path(request)
    wal = os.getenv("DINGTALK_DB_SOURCE", "/dingtalk_db/dingtalk.db") + "-wal"

    # 1. WAL age — informational only.
    # WAL only updates when new messages arrive; long idle = normal, not a fault.
    try:
        mtime = os.path.getmtime(wal)
        wal_age_s = int(time.time() - mtime)
        last_wal_update = datetime.fromtimestamp(mtime, tz=timezone.utc).isoformat()
    except FileNotFoundError:
        wal_age_s = -1
        last_wal_update = None

    # 2. Process status — the authoritative liveness signal.
    process_status = "unknown"
    try:
        r = subprocess.run(["pgrep", "-f", "com.alibabainc.dingtalk"], capture_output=True, text=True)
        if r.returncode == 0:
            pid = r.stdout.strip().split()[0]
            state_line = open(f"/proc/{pid}/status").read()
            if "State:\tT" in state_line:
                # Stopped by SIGSTOP (e.g. leftover from a gdb attach)
                process_status = "stopped"
            else:
                process_status = "running"
        else:
            process_status = "not_running"
    except Exception:
        pass

    # client_alive: use last successful sync as the liveness signal.
    # The sync task runs every 60s inside the container and reads the host DB via
    # bind-mount. If it succeeded recently, the client is reachable. This avoids
    # the need to inspect host processes from inside the container (which doesn't work).
    # Fallback: if no sync record yet, treat as alive when the WAL file exists.
    ensure_schema(db_path)
    with sqlite3.connect(db_path) as _lconn:
        _sr = _lconn.execute(
            "SELECT value FROM dingtalk_sync_state WHERE key='last_sync_ok_at'"
        ).fetchone()
    last_sync_ok_ts = int(_sr[0]) if _sr else 0
    sync_age_s = int(time.time()) - last_sync_ok_ts if last_sync_ok_ts else 9999
    # alive = sync ran successfully in last 3 minutes (60s interval + buffer)
    client_alive = sync_age_s < 180 if last_sync_ok_ts else (wal_age_s >= 0)
    # process_status kept for potential future use when running outside container
    _ = process_status  # suppress unused warning

    # 3. Sync state & message stats
    ensure_schema(db_path)
    with sqlite3.connect(db_path) as conn:
        state_row = conn.execute(
            "SELECT value FROM dingtalk_sync_state WHERE key='last_seen_created_at'"
        ).fetchone()
        last_seen_ts = int(state_row[0]) if state_row else 0

        stats = conn.execute(
            """SELECT verdict, COUNT(*) as cnt FROM dingtalk_messages
               WHERE synced_at > strftime('%s','now') - 86400
               GROUP BY verdict"""
        ).fetchall()

        total = conn.execute("SELECT COUNT(*) FROM dingtalk_messages").fetchone()[0]
        unread = conn.execute(
            "SELECT COUNT(*) FROM dingtalk_messages WHERE verdict='notify' AND created_at > ?",
            (last_seen_ts - 3_600_000,),
        ).fetchone()[0]

    last_sync_dt = (
        datetime.fromtimestamp(last_seen_ts / 1000, tz=timezone.utc).isoformat()
        if last_seen_ts else None
    )

    last_sync_ok_dt = (
        datetime.fromtimestamp(last_sync_ok_ts, tz=timezone.utc).isoformat()
        if last_sync_ok_ts else None
    )

    return {
        "client_alive": client_alive,
        "process_status": process_status,
        "wal_age_seconds": wal_age_s,
        "last_wal_update": last_wal_update,
        "last_sync_ok": last_sync_ok_dt,
        "sync_age_seconds": sync_age_s if last_sync_ok_ts else None,
        "last_sync": last_sync_dt,
        "total_messages": total,
        "recent_24h": {r[0]: r[1] for r in stats},
        "recent_notify_count": unread,
    }


@router.post("/resume")
async def dingtalk_resume():
    """Send SIGCONT to DingTalk if it was stopped."""
    r = subprocess.run(["pgrep", "-f", "com.alibabainc.dingtalk"], capture_output=True, text=True)
    if r.returncode != 0:
        return {"ok": False, "error": "process not found"}
    pid = int(r.stdout.strip().split()[0])
    os.kill(pid, signal.SIGCONT)
    return {"ok": True, "pid": pid, "signal": "SIGCONT"}
