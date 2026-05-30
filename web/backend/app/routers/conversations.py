from fastapi import APIRouter
from app.models import ConversationCreate, ConversationUpdate
from app.database import db_conn
import uuid
from datetime import datetime

router = APIRouter(prefix="/api/conversations", tags=["conversations"])


@router.get("")
async def list_conversations():
    async with db_conn() as db:
        rows = await (await db.execute(
            "SELECT id, title, provider_id, model, agent_mode, system_prompt, created_at, updated_at "
            "FROM conversations ORDER BY updated_at DESC"
        )).fetchall()
        return [dict(r) for r in rows]


@router.post("")
async def create_conversation(body: ConversationCreate):
    async with db_conn() as db:
        now = datetime.utcnow().isoformat()
        conv_id = str(uuid.uuid4())
        await db.execute(
            "INSERT INTO conversations (id, title, provider_id, model, created_at, updated_at) VALUES (?,?,?,?,?,?)",
            (conv_id, body.title, body.provider_id, body.model, now, now),
        )
        await db.commit()
        return {"id": conv_id, "title": body.title, "provider_id": body.provider_id, "model": body.model}


@router.get("/{conv_id}")
async def get_conversation(conv_id: str):
    async with db_conn() as db:
        row = await (await db.execute(
            "SELECT id, title, provider_id, model, agent_mode, system_prompt, created_at, updated_at "
            "FROM conversations WHERE id=?", (conv_id,)
        )).fetchone()
        if not row:
            return {"error": "not found"}
        return dict(row)


@router.put("/{conv_id}")
async def update_conversation(conv_id: str, body: ConversationUpdate):
    async with db_conn() as db:
        updates = []
        params = []
        for field, value in body.model_dump(exclude_none=True).items():
            updates.append(f"{field}=?")
            params.append(value)
        if not updates:
            return {"ok": True}
        updates.append("updated_at=?")
        params.append(datetime.utcnow().isoformat())
        params.append(conv_id)
        await db.execute(f"UPDATE conversations SET {','.join(updates)} WHERE id=?", params)
        await db.commit()
        return {"ok": True}


@router.delete("/{conv_id}")
async def delete_conversation(conv_id: str):
    async with db_conn() as db:
        await db.execute("DELETE FROM conversations WHERE id=?", (conv_id,))
        await db.commit()
        return {"ok": True}


@router.get("/{conv_id}/messages")
async def list_messages(conv_id: str):
    async with db_conn() as db:
        rows = await (await db.execute(
            "SELECT id, role, content, reasoning_content, usage_json, schedule_payload_json, "
            "chat_list_payload_json, timestamp, position "
            "FROM messages WHERE conversation_id=? ORDER BY position", (conv_id,)
        )).fetchall()
        return [dict(r) for r in rows]
