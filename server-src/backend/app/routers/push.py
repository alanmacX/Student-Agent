from __future__ import annotations
from fastapi import APIRouter
from app.config import settings
from app.database import db_conn
from app.models import PushSubscribe, PushUnsubscribe
from app.services.push_service import send_push_to_all_subscribers
import json
from datetime import datetime

router = APIRouter(prefix="/api/push", tags=["push"])
notifications_router = APIRouter(prefix="/api", tags=["notifications"])


@router.get("/vapid-public-key")
async def get_vapid_key():
    return {"publicKey": settings.vapid_public_key}


@router.get("/status")
async def push_status():
    async with db_conn() as db:
        row = await (await db.execute("SELECT COUNT(*) FROM push_subscriptions")).fetchone()
        return {
            "supported": bool(settings.vapid_public_key and settings.vapid_private_key),
            "hasPublicKey": bool(settings.vapid_public_key),
            "hasPrivateKey": bool(settings.vapid_private_key),
            "subscriberCount": row[0] if row else 0,
        }


@router.post("/subscribe")
async def subscribe(body: PushSubscribe):
    async with db_conn() as db:
        await db.execute(
            "INSERT OR IGNORE INTO push_subscriptions (endpoint, p256dh, auth, created_at) VALUES (?,?,?,?)",
            (body.endpoint, body.keys.get("p256dh", ""), body.keys.get("auth", ""), datetime.utcnow().isoformat()),
        )
        await db.commit()
        return {"ok": True}


@router.delete("/subscribe")
async def unsubscribe(body: PushUnsubscribe):
    async with db_conn() as db:
        await db.execute("DELETE FROM push_subscriptions WHERE endpoint=?", (body.endpoint,))
        await db.commit()
        return {"ok": True}


@router.post("/test")
async def send_test_push():
    result = await send_push_to_all_subscribers(
        settings.database_path,
        title="✅ 推送测试",
        body="Web Push 配置正确！",
        tag="test",
    )
    return {"ok": True, **result}


@router.post("/received")
async def push_received(body: dict):
    return await _mark_delivery(body.get("tag"), "device_received_at")


@router.post("/clicked")
async def push_clicked(body: dict):
    return await _mark_delivery(body.get("tag"), "clicked_at")


@router.post("/dismissed")
async def push_dismissed(body: dict):
    return await _mark_delivery(body.get("tag"), "dismissed_at")


@notifications_router.get("/notifications")
async def get_notifications(limit: int = 50):
    """Return recent notification log entries with title/body."""
    async with db_conn() as db:
        rows = await (await db.execute(
            """
            SELECT
                nl.id,
                nl.item_id,
                nl.notif_type,
                nl.sent_at,
                nl.device_received_at,
                nl.clicked_at,
                nl.dismissed_at,
                COALESCE(nl.push_title, sn1.title, sn2.title) AS title,
                COALESCE(nl.push_body, sn1.body, sn2.body) AS body
            FROM notification_log nl
            LEFT JOIN scheduled_notifications sn1 ON nl.item_id = sn1.id
            LEFT JOIN scheduled_notifications sn2 ON nl.item_id = sn2.source_id
            ORDER BY nl.sent_at DESC
            LIMIT ?
            """,
            (limit,),
        )).fetchall()
        columns = ["id", "item_id", "notif_type", "sent_at", "device_received_at",
                   "clicked_at", "dismissed_at", "title", "body"]
        return [dict(zip(columns, row)) for row in rows]


@notifications_router.get("/notifications/daily-popup")
async def get_daily_popup():
    """Return the most recent daily briefing (morning/evening) push from the last
    16 hours, for the PWA to surface as an in-app popup on open. Returns null when
    there's nothing fresh."""
    async with db_conn() as db:
        row = await (await db.execute(
            """
            SELECT id, item_id, notif_type, sent_at, push_title AS title, push_body AS body
            FROM notification_log
            WHERE notif_type IN ('daily_begin', 'daily_summary_evening')
              AND sent_at >= datetime('now', '-16 hours')
            ORDER BY sent_at DESC
            LIMIT 1
            """
        )).fetchone()
        if not row:
            return {"popup": None}
        columns = ["id", "item_id", "notif_type", "sent_at", "title", "body"]
        return {"popup": dict(zip(columns, row))}


@notifications_router.get("/notifications/scheduled")
async def get_scheduled_notifications(limit: int = 50):
    """Return pending scheduled notifications."""
    async with db_conn() as db:
        rows = await (await db.execute(
            """
            SELECT id, title, body, scheduled_at, source_type, source_id, sent_at, cancelled_at
            FROM scheduled_notifications
            WHERE sent_at IS NULL AND cancelled_at IS NULL
            ORDER BY scheduled_at ASC
            LIMIT ?
            """,
            (limit,),
        )).fetchall()
        columns = ["id", "title", "body", "scheduled_at", "source_type", "source_id", "sent_at", "cancelled_at"]
        return [dict(zip(columns, row)) for row in rows]


@notifications_router.get("/notifications/standby-log")
async def get_standby_log(limit: int = 30):
    """Return recent standby agent decisions."""
    async with db_conn() as db:
        rows = await (await db.execute(
            """
            SELECT id, decision, reason, model, input_tokens, output_tokens, duration_ms,
                   ran_at AS created_at
            FROM standby_agent_log
            ORDER BY id DESC
            LIMIT ?
            """,
            (limit,),
        )).fetchall()
        columns = ["id", "decision", "reason", "model", "input_tokens", "output_tokens", "duration_ms", "created_at"]
        return [dict(zip(columns, row)) for row in rows]


async def _mark_delivery(tag: str | None, column: str):
    if not tag:
        return {"ok": False}
    now = datetime.utcnow().isoformat()
    candidates = [tag]
    if tag.startswith("scheduled-"):
        candidates.append(tag.removeprefix("scheduled-"))
    elif tag.startswith("memory-"):
        candidates.append(tag.removeprefix("memory-"))
    elif tag.startswith("standby-"):
        candidates.append(tag.removeprefix("standby-"))
    elif tag.startswith("deadline-"):
        candidates.append(tag.removeprefix("deadline-"))
    async with db_conn() as db:
        cur = await db.execute(
            f"UPDATE notification_log SET {column}=COALESCE({column}, ?) "
            f"WHERE item_id IN ({','.join('?' for _ in candidates)})",
            (now, *candidates),
        )
        await db.commit()
    return {"ok": cur.rowcount > 0}
