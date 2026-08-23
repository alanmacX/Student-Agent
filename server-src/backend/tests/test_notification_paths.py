"""Round 4 — Notification delivery path edge cases.

  N1 quiet hours wrap-around (23:30→07:00) and delay-to-morning
  N2 ladder vs deadline-channel double push for same assignment
  N3 has_notified 24h window: re-push after window expiry is allowed
  N4 cancelled/sent rows never fire
  N5 malformed due strings in chaoxing assignments don't crash the sweep
"""
from __future__ import annotations

import asyncio
from datetime import datetime, timedelta, timezone
from types import SimpleNamespace
from zoneinfo import ZoneInfo

import aiosqlite
import pytest

from app.tasks.notification_sender import (
    _in_quiet_hours,
    _parse_quiet_hours,
    check_scheduled_notifications,
)
from app.services.push_service import has_notified, log_notification_sent

CST = ZoneInfo("Asia/Shanghai")


def _local(h, m):
    from datetime import time as _t
    return datetime(2026, 9, 14, h, m, tzinfo=CST)


def test_n1_quiet_wraparound():
    start, end = _parse_quiet_hours("23:30-07:00")
    assert _in_quiet_hours(_local(23, 45), start, end)      # late night
    assert _in_quiet_hours(_local(3, 0), start, end)        # small hours
    assert not _in_quiet_hours(_local(12, 0), start, end)   # midday
    assert not _in_quiet_hours(_local(7, 0), start, end)    # boundary exclusive end
    assert not _in_quiet_hours(_local(23, 29), start, end)

    # same-day range still works
    s2, e2 = _parse_quiet_hours("12:00-14:00")
    assert _in_quiet_hours(_local(13, 0), s2, e2)
    assert not _in_quiet_hours(_local(15, 0), s2, e2)
    # garbage falls back to default
    s3, e3 = _parse_quiet_hours("garbage")
    assert (s3, e3) == (_parse_quiet_hours(None)[0], _parse_quiet_hours(None)[1])


@pytest.mark.asyncio
async def test_n1b_quiet_hours_delay_moves_to_morning(db_path):
    """深夜到期的 ladder 行被顺延到 07:00,且原行不被发送。"""
    # 02:00 CST = 18:00 UTC prev day
    night_utc = datetime(2026, 9, 13, 18, 0, tzinfo=timezone.utc)
    async with aiosqlite.connect(db_path) as db:
        await db.execute(
            """INSERT INTO scheduled_notifications
               (id, title, body, scheduled_at, source_type, created_at)
               VALUES ('n1row', '考试提醒', '明天考试', ?, 'memory_ladder', ?)""",
            (night_utc.isoformat(), night_utc.isoformat()))
        await db.commit()

    state = SimpleNamespace(settings=SimpleNamespace(database_path=db_path),
                            chaoxing_svc=SimpleNamespace(is_logged_in=True))

    async def no_send(*a, **k):
        return {"attempted": 1}

    import unittest.mock as um
    with um.patch("app.tasks.notification_sender.send_push_to_all_subscribers", no_send), \
         um.patch("app.tasks.notification_sender.datetime") as mock_dt:
        mock_dt.now.return_value = night_utc + timedelta(seconds=30)
        mock_dt.fromisoformat = datetime.fromisoformat
        await check_scheduled_notifications(state)

    async with aiosqlite.connect(db_path) as db:
        row = await (await db.execute(
            "SELECT sent_at, scheduled_at FROM scheduled_notifications WHERE id='n1row'"
        )).fetchone()
    assert row[0] is None                       # NOT sent at night
    delayed_local = datetime.fromisoformat(row[1]).astimezone(CST)
    assert delayed_local.hour == 7 and delayed_local.minute == 0


@pytest.mark.asyncio
async def test_n2_ladder_and_deadline_channel_dedup_by_type(db_path):
    """同一作业:ladder 推过一次后,deadline_24h 通道仍会推(notif_type 不同),
    但同通道内绝不重复 — 验证这是'每通道一次'的契约而非 bug。"""
    await log_notification_sent(db_path, "asg-1", "deadline_24h")
    assert await has_notified(db_path, "asg-1", "deadline_24h")
    assert not await has_notified(db_path, "asg-1", "ladder_now")
    # cross-channel suppression helper sees it though
    from app.services.push_service import entity_recently_notified
    assert await entity_recently_notified(db_path, "asg-1")


@pytest.mark.asyncio
async def test_n3_has_notified_window_expiry(db_path):
    """24h 未确认送达 → 允许重推(flaky delivery 自愈)。"""
    old = (datetime.now(timezone.utc) - timedelta(hours=25)).isoformat()
    async with aiosqlite.connect(db_path) as db:
        await db.execute(
            "INSERT INTO notification_log (item_id, notif_type, sent_at) VALUES (?,?,?)",
            ("item-x", "standby_agent", old))
        await db.commit()
    assert not await has_notified(db_path, "item-x", "standby_agent")
    # with device confirmation → always dedup
    async with aiosqlite.connect(db_path) as db:
        await db.execute(
            "UPDATE notification_log SET device_received_at=? WHERE item_id='item-x'",
            (datetime.now(timezone.utc).isoformat(),))
        await db.commit()
    assert await has_notified(db_path, "item-x", "standby_agent")


@pytest.mark.asyncio
async def test_n4_cancelled_and_sent_never_fire(db_path):
    past = (datetime.now(timezone.utc) - timedelta(minutes=5)).isoformat()
    async with aiosqlite.connect(db_path) as db:
        await db.executemany(
            """INSERT INTO scheduled_notifications
               (id, title, body, scheduled_at, sent_at, cancelled_at, source_type, created_at)
               VALUES (?,?,?,?,?,?,?,?)""",
            [("sent-row", "t1", "b", past, past, None, "memory_ladder", past),
             ("cancelled-row", "t2", "b", past, None, past, "memory_ladder", past)])
        await db.commit()

    sent_calls = []

    async def spy_send(*a, **k):
        sent_calls.append(1)
        return {"attempted": 1}

    state = SimpleNamespace(settings=SimpleNamespace(database_path=db_path),
                            chaoxing_svc=SimpleNamespace(is_logged_in=True))
    import unittest.mock as um
    with um.patch("app.tasks.notification_sender.send_push_to_all_subscribers", spy_send):
        await check_scheduled_notifications(state)
    assert sent_calls == []


@pytest.mark.asyncio
async def test_n5_malformed_assignment_due_does_not_crash(db_path):
    """学习通返回畸形截止时间 → deadline sweep 跳过而非崩掉整轮。"""
    from datetime import datetime as dt

    bad_assignments = [
        {"id": "a1", "title": "坏日期作业", "courseName": "课A",
         "dueDate": "下周三之前交", "status": "未交"},
        {"id": "a2", "title": "空截止作业", "courseName": "课A",
         "dueDate": None, "status": "未交"},
        {"id": "a3", "title": "正常作业", "courseName": "课B",
         "dueDate": (dt.now(timezone.utc) + timedelta(hours=2)).isoformat(),
         "status": "未交"},
    ]
    pushes = []

    async def fake_send(*a, **k):
        pushes.append(a[1] if len(a) > 1 else k.get("title"))
        return {"attempted": 1}

    class Svc:
        is_logged_in = True

        async def fetch_all_pending_assignments(self):
            return bad_assignments

    state = SimpleNamespace(settings=SimpleNamespace(database_path=db_path),
                            chaoxing_svc=Svc())
    from app.tasks.notification_sender import check_and_send_deadline_notifications
    import unittest.mock as um
    with um.patch("app.tasks.notification_sender.send_push_to_all_subscribers", fake_send):
        await check_and_send_deadline_notifications(state)  # must not raise
    # Only the valid one pushed (1h channel)
    assert len(pushes) == 1
