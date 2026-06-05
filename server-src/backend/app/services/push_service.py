"""Web Push notification sender via pywebpush."""

from __future__ import annotations

import json
from pywebpush import webpush, WebPushException
from app.config import settings
import aiosqlite
import asyncio
from datetime import datetime, timedelta, timezone


async def send_push_to_all_subscribers(
    db_path: str,
    title: str,
    body: str,
    data: dict = None,
    tag: str = None,
    icon: str = "/icon-192.png",
):
    if not settings.vapid_private_key:
        return {"attempted": 0, "failed": 0, "stale_removed": 0, "error": "missing_vapid_private_key"}

    async with aiosqlite.connect(db_path) as db:
        rows = await (await db.execute(
            "SELECT id, endpoint, p256dh, auth FROM push_subscriptions"
        )).fetchall()

    stale_ids = []
    delivered = 0
    errored = 0
    for row in rows:
        sub_id, endpoint, p256dh, auth = row
        status = await _send_one(endpoint, p256dh, auth, title, body, data, tag, icon)
        if status == "ok":
            delivered += 1
        elif status == "stale":
            stale_ids.append(sub_id)
        else:  # "error" — transient, keep subscription but not delivered
            errored += 1

    if stale_ids:
        async with aiosqlite.connect(db_path) as db:
            await db.execute(
                f"DELETE FROM push_subscriptions WHERE id IN ({','.join('?' * len(stale_ids))})",
                stale_ids,
            )
            await db.commit()

    if errored and not delivered:
        print(f"[Push] WARNING: 0/{len(rows)} delivered ({errored} errors) for tag={tag!r} title={title!r}")

    return {
        "attempted": len(rows),
        "delivered": delivered,
        "failed": errored,
        "stale_removed": len(stale_ids),
    }


async def _send_one(endpoint, p256dh, auth, title, body, data, tag, icon) -> str:
    """Send one push. Returns 'ok' (delivered), 'stale' (subscription gone,
    should be removed) or 'error' (transient failure — keep subscription but
    treat as NOT delivered)."""
    payload_data = data or {}
    if tag:
        payload_data = {**payload_data, "tag": tag}
    payload = json.dumps({
        "title": title,
        "body": body,
        "icon": icon,
        "tag": tag,
        "data": payload_data,
    })
    try:
        await asyncio.to_thread(
            webpush,
            subscription_info={"endpoint": endpoint, "keys": {"p256dh": p256dh, "auth": auth}},
            data=payload,
            vapid_private_key=settings.vapid_private_key,
            vapid_claims={"sub": settings.vapid_mailto},
        )
        return "ok"
    except WebPushException as e:
        status = e.response.status_code if e.response else None
        if status in (404, 410):
            return "stale"
        print(f"[Push] FAILED (status={status}) endpoint={endpoint[:40]}…: {e}")
        return "error"
    except Exception as e:
        print(f"[Push] ERROR endpoint={endpoint[:40]}…: {e!r}")
        return "error"


async def log_notification_sent(db_path: str, item_id: str, notif_type: str,
                                title: str = None, body: str = None):
    async with aiosqlite.connect(db_path) as db:
        await db.execute(
            "INSERT OR IGNORE INTO notification_log (item_id, notif_type, sent_at, push_title, push_body) VALUES (?,?,?,?,?)",
            (item_id, notif_type, datetime.now(timezone.utc).isoformat(), title, body),
        )
        await db.commit()


async def entity_recently_notified(db_path: str, item_id: str, within_hours: int = 24) -> bool:
    """Cross-channel suppression: was this entity pushed via ANY channel recently?

    ``has_notified`` is keyed by (item_id, notif_type), so each channel
    (memory_high / standby_agent / daily_*) has its own dedup namespace and the
    same real-world item can be pushed once per channel. This checks item_id
    regardless of notif_type so a thing already surfaced by one channel isn't
    immediately re-surfaced by another.
    """
    if not item_id:
        return False
    cutoff = (datetime.now(timezone.utc) - timedelta(hours=within_hours)).isoformat()
    async with aiosqlite.connect(db_path) as db:
        row = await (await db.execute(
            "SELECT 1 FROM notification_log WHERE item_id=? AND sent_at > ? LIMIT 1",
            (item_id, cutoff),
        )).fetchone()
    return row is not None


async def has_notified(db_path: str, item_id: str, notif_type: str) -> bool:
    async with aiosqlite.connect(db_path) as db:
        row = await (await db.execute(
            "SELECT sent_at, device_received_at FROM notification_log WHERE item_id=? AND notif_type=?",
            (item_id, notif_type),
        )).fetchone()
    if not row:
        return False
    # If device confirmed receipt, always dedup
    if row[1]:
        return True
    # If sent but not confirmed, dedup for 24h (prevents spam on flaky delivery)
    try:
        sent_at = datetime.fromisoformat(row[0])
        if sent_at.tzinfo is None:
            sent_at = sent_at.replace(tzinfo=timezone.utc)
        return datetime.now(timezone.utc) - sent_at < timedelta(hours=24)
    except Exception:
        return True
