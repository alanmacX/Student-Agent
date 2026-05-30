from __future__ import annotations
import json
from datetime import datetime, timezone
from fastapi import APIRouter, Request
from fastapi.responses import Response
import aiosqlite
from app.config import settings

router = APIRouter(prefix="/api/data", tags=["data"])

EXPORT_TABLES = [
    "settings", "conversations", "messages",
    "server_reminders", "server_events", "server_courses",
    "schedule_sessions", "schedule_messages",
    "custom_providers",
    "chaoxing_memory_entries", "chaoxing_conversation_sync",
    "chaoxing_processed_ids", "chaoxing_processed_fingerprints",
    "scheduled_notifications", "notification_log", "standby_agent_log",
]


@router.get("/export")
async def export_data():
    """Dump all user data to JSON. Excludes device-specific tables."""
    dump = {
        "version": 1,
        "exported_at": datetime.now(timezone.utc).isoformat(),
        "tables": {},
    }
    async with aiosqlite.connect(settings.database_path) as db:
        db.row_factory = aiosqlite.Row
        for table in EXPORT_TABLES:
            try:
                rows = await (await db.execute(f"SELECT * FROM {table}")).fetchall()
                dump["tables"][table] = [dict(r) for r in rows]
            except Exception as e:
                dump["tables"][table] = {"error": str(e)}

    content = json.dumps(dump, ensure_ascii=False, indent=2)
    return Response(
        content=content,
        media_type="application/json",
        headers={
            "Content-Disposition": f'attachment; filename="chatbot-export-{datetime.now(timezone.utc).strftime("%Y%m%d-%H%M")}.json"'
        },
    )


@router.post("/import")
async def import_data(request: Request):
    """Restore data from a previously exported JSON file."""
    body = await request.json()
    if body.get("version") != 1 or "tables" not in body:
        return {"error": "invalid export file format"}

    results = {}
    async with aiosqlite.connect(settings.database_path) as db:
        for table, rows in body["tables"].items():
            if table not in EXPORT_TABLES:
                results[table] = "skipped (not in allowlist)"
                continue
            if isinstance(rows, dict) and "error" in rows:
                results[table] = f"skipped (export had error: {rows['error']})"
                continue
            try:
                if not rows:
                    results[table] = "empty"
                    continue
                cols = list(rows[0].keys())
                placeholders = ",".join("?" for _ in cols)
                col_list = ",".join(cols)
                count = 0
                for row in rows:
                    await db.execute(
                        f"INSERT OR IGNORE INTO {table} ({col_list}) VALUES ({placeholders})",
                        [row.get(c) for c in cols],
                    )
                    count += 1
                await db.commit()
                results[table] = f"imported {count} rows"
            except Exception as e:
                results[table] = f"error: {e}"

    return {"ok": True, "results": results}
