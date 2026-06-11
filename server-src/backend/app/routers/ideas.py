"""Standalone idea scratchpad.

Captured thoughts that live OUTSIDE the message/memory automation pipeline:
nothing here is created by syncs or the reconciler, nothing here gets swept or
turned into notifications. Pure user-owned CRUD, readable by the agent on demand.
"""
from __future__ import annotations

import uuid
from datetime import datetime, timezone

from fastapi import APIRouter, Request

from app.database import db_conn

router = APIRouter(prefix="/api/ideas", tags=["ideas"])


def _now() -> str:
    return datetime.now(timezone.utc).isoformat()


@router.get("")
async def list_ideas():
    async with db_conn() as db:
        rows = await (await db.execute(
            "SELECT id, text, created_at, updated_at FROM ideas "
            "WHERE archived_at IS NULL ORDER BY updated_at DESC LIMIT 500"
        )).fetchall()
        return [dict(r) for r in rows]


@router.post("")
async def create_idea(request: Request):
    body = await request.json()
    text = (body.get("text") or "").strip()
    if not text:
        return {"error": "text required"}
    idea_id = "idea_" + uuid.uuid4().hex[:10]
    now = _now()
    async with db_conn() as db:
        await db.execute(
            "INSERT INTO ideas (id, text, created_at, updated_at) VALUES (?,?,?,?)",
            (idea_id, text, now, now),
        )
        await db.commit()
    return {"id": idea_id, "text": text, "created_at": now, "updated_at": now}


@router.patch("/{idea_id}")
async def update_idea(idea_id: str, request: Request):
    body = await request.json()
    text = (body.get("text") or "").strip()
    if not text:
        return {"error": "text required"}
    async with db_conn() as db:
        cur = await db.execute(
            "UPDATE ideas SET text=?, updated_at=? WHERE id=? AND archived_at IS NULL",
            (text, _now(), idea_id),
        )
        await db.commit()
        if cur.rowcount == 0:
            return {"error": "not found"}
    return {"ok": True, "id": idea_id, "text": text}


@router.delete("/{idea_id}")
async def delete_idea(idea_id: str):
    async with db_conn() as db:
        cur = await db.execute("DELETE FROM ideas WHERE id=?", (idea_id,))
        await db.commit()
        if cur.rowcount == 0:
            return {"error": "not found"}
    return {"ok": True}
