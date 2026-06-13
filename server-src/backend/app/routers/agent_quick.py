"""Non-streaming agent endpoint for Apple Shortcuts / Siri.

POST /api/agent/ask  { "text": "...", "auto_confirm": true, "session": "siri" }
  -> { "reply": "<plain text for Siri to speak>", "ok": true, "did": [...] }

Voice has no confirm button, so by default queued mutations are auto-executed
and summarised back. Pass auto_confirm=false to only describe the intent.
Auth: same access-token middleware as the rest of /api/* (Bearer header or
?token= query param), so a Shortcut can POST to /api/agent/ask?token=XXX.
"""
from __future__ import annotations

import json
import re
import uuid
from datetime import datetime, timezone

from fastapi import APIRouter, Request

from app.config import settings
from app.database import db_conn
from app.services.provider_registry import resolve_provider
from app.services.schedule_agent import (
    run_schedule_agent,
    get_pending_mutations,
    execute_pending_mutations,
)

router = APIRouter(prefix="/api/agent", tags=["agent"])

# Appended to the agent's system prompt only for the Siri/voice channel.
VOICE_SYSTEM = (
    "【语音通道】本次回复会被朗读出来。请用自然、连贯、像真人说话的一到两句中文回答，"
    "不要为了简短而输出断断续续的词组或电报式短句；要把主语、动作和结果说完整，"
    "语气可以亲近一点，像手机助手在顺口回应。绝对不要使用任何表情符号(emoji)、HTML、"
    "Markdown、列表符号、星号或代码块；不要念 URL 或长 ID。日期时间用口语说法"
    "(例如「明天下午三点」而不是 ISO 时间)。整体保持清楚、自然、适合直接朗读。"
)

# Emoji + symbol ranges that read badly aloud.
_EMOJI_RE = re.compile(
    "[\U0001F000-\U0001FAFF\U00002600-\U000027BF\U0001F1E6-\U0001F1FF"
    "\U00002190-\U000021FF\U00002B00-\U00002BFF\U0000FE00-\U0000FE0F\U00002700-\U000027BF]+"
)


def _voice_clean(text: str) -> str:
    """Strip HTML/markdown/emoji so Siri speaks clean prose."""
    text = re.sub(r"<[^>]+>", "", text)            # html tags
    text = _EMOJI_RE.sub("", text)                  # emoji + arrows + dingbats
    text = re.sub(r"(?m)^\s*[-*•·]\s+", "", text)   # leading list markers per line
    text = re.sub(r"[*_`#>|•·]", "", text)          # inline markdown markers
    text = re.sub(r"\n{2,}", "\n", text)            # collapse blank lines
    text = re.sub(r"[ \t]{2,}", " ", text)
    return text.strip()


async def _resolve_schedule_provider():
    """Mirror the resolution used by the streaming /api/schedule endpoint."""
    async with db_conn() as db:
        pid_row = await (await db.execute(
            "SELECT value FROM settings WHERE key='schedule_agent_provider_id'"
        )).fetchone()
        provider_id = pid_row["value"] if pid_row else "openai"
        model_row = await (await db.execute(
            "SELECT value FROM settings WHERE key='schedule_agent_model'"
        )).fetchone()
        schedule_model = model_row["value"] if model_row and model_row["value"] else ""
        sched = await (await db.execute(
            "SELECT value FROM settings WHERE key='schedule_agent_provider'"
        )).fetchone()

    provider, api_key = await resolve_provider(provider_id)
    model = schedule_model or (provider.get("models") or ["gpt-4o-mini"])[0]
    if provider.get("id") == "openai" and not schedule_model:
        model = "gpt-4o-mini"
    if not api_key and provider.get("id") == "openai":
        fp, fk = await resolve_provider("xiaomimimo")
        if fk:
            provider, api_key = fp, fk
            model = schedule_model or (provider.get("models") or ["mimo-v2.5-pro"])[0]
    if sched:
        try:
            d = json.loads(sched[0])
            provider = {"api_type": d.get("api_type", "openAI"), "base_url": d.get("base_url", "")}
            api_key = d.get("api_key", api_key)
            model = d.get("model", model)
        except (json.JSONDecodeError, TypeError):
            pass
    return provider, model, api_key


async def _save_msg(db, session_id: str, role: str, content: str):
    pos_row = await (await db.execute(
        "SELECT MAX(position) FROM schedule_messages WHERE session_id=?", (session_id,)
    )).fetchone()
    next_pos = (pos_row[0] or 0) + 1
    await db.execute(
        "INSERT INTO schedule_messages (id, session_id, role, content, timestamp, position) VALUES (?,?,?,?,?,?)",
        (str(uuid.uuid4()), session_id, role, content, datetime.now(timezone.utc).isoformat(), next_pos),
    )


@router.post("/ask")
async def agent_ask(request: Request):
    body = await request.json()
    text = (body.get("text") or body.get("message") or "").strip()
    if not text:
        return {"ok": False, "reply": "没有收到内容。"}
    auto_confirm = bool(body.get("auto_confirm", True))
    session_id = (body.get("session") or "siri").strip() or "siri"

    chaoxing_svc = request.app.state.chaoxing_svc
    db_path = settings.database_path

    # Ensure the Siri session exists so it shows up in the app too.
    async with db_conn() as db:
        exists = await (await db.execute(
            "SELECT 1 FROM schedule_sessions WHERE id=?", (session_id,)
        )).fetchone()
        if not exists:
            now = datetime.now(timezone.utc).isoformat()
            await db.execute(
                "INSERT INTO schedule_sessions (id, title, created_at, updated_at) VALUES (?,?,?,?)",
                (session_id, "Siri", now, now),
            )
        rows = await (await db.execute(
            "SELECT role, content FROM schedule_messages WHERE session_id=? ORDER BY position DESC LIMIT 10",
            (session_id,),
        )).fetchall()
        history = [{"role": r["role"], "content": r["content"]} for r in reversed(rows)]
        await _save_msg(db, session_id, "user", text)
        await db.commit()

    provider, model, api_key = await _resolve_schedule_provider()

    reply = ""
    async for event in run_schedule_agent(
        text, history, provider, model, api_key,
        chaoxing_svc, db_path, conversation_id=session_id,
        extra_system=VOICE_SYSTEM,
    ):
        if event.get("type") == "text":
            reply += event.get("content", "")

    did: list[str] = []
    pending = await get_pending_mutations(db_path, session_id)
    if pending and auto_confirm:
        result = await execute_pending_mutations(chaoxing_svc, db_path, session_id)
        if result.get("ok"):
            did = [p.get("tool", "操作") for p in pending]
            reply = (reply + " 已执行。").strip()
        else:
            reply = (reply + " （执行失败，请在 App 内确认）").strip()
    elif pending:
        reply = (reply + " 需要在 App 内点确认执行。").strip()

    reply = _voice_clean(reply) or "好的。"
    async with db_conn() as db:
        await _save_msg(db, session_id, "assistant", reply)
        await db.execute("UPDATE schedule_sessions SET updated_at=? WHERE id=?",
                         (datetime.now(timezone.utc).isoformat(), session_id))
        await db.commit()

    return {"ok": True, "reply": reply, "did": did, "session": session_id}
