"""Safety-net tests: guarantees that don't depend on understanding content.

The user's critique: regex against human semantics is a sieve. Correct — so
these mechanisms make no semantic claims at all:
  G1 daily budget     — hard cap on pushes/day, holds under total hallucination
  G2 cooldown         — burst degrades to trickle
  G3 overflow parking — gated items surface in digest instead of vanishing
  G4 digest bypass    — daily_* channels unaffected by the gate
  G5 nightly review   — LLM audit tightens budget when fp_rate > 30%
  G6 incident replay  — with the gate live, the 9-push incident day is capped
"""
from __future__ import annotations

import json
from datetime import datetime, timedelta, timezone
from types import SimpleNamespace

import aiosqlite
import pytest

from app.memory.dispatch import notify_now
from app.services.push_gate import check_push_budget

NOW = datetime(2026, 9, 14, 10, 0, tzinfo=timezone.utc)


async def _log_push(db_path: str, item_id: str, sent_at: datetime):
    from app.services.push_service import log_notification_sent
    async with aiosqlite.connect(db_path) as db:
        await db.execute(
            "INSERT INTO notification_log (item_id, notif_type, sent_at) VALUES (?,?,?)",
            (item_id, "test", sent_at.isoformat()))
        await db.commit()


@pytest.mark.asyncio
async def test_g1_daily_budget_hard_cap(db_path):
    """第 7 条(默认上限 6)被闸,即使内容完全合法。"""
    for i in range(6):
        await _log_push(db_path, f"cap-{i}", NOW - timedelta(hours=6 - i))
    r = await check_push_budget(db_path, notif_type="automation", now=NOW)
    assert not r["allowed"] and "daily_budget" in r["reason"]
    assert r["queued_for_digest"]


@pytest.mark.asyncio
async def test_g1b_gate_fails_open_on_error(db_path, monkeypatch):
    """闸本身出错 → notify_now 放行(fail-open),不能因保底机制故障而吞掉真通知。"""
    import app.services.push_gate as pg

    async def boom(db_path, **k):
        raise RuntimeError("gate down")

    monkeypatch.setattr(pg, "check_push_budget", boom)
    # No mock_llm fixture here; patch the actual send so nothing hits network.
    import unittest.mock as um

    async def fake_send(*a, **k):
        return {"attempted": 1}

    with um.patch("app.services.push_service.send_push_to_all_subscribers", fake_send):
        r = await notify_now(db_path, "真通知", "内容", item_id="g1b",
                             notif_type="ladder_now")
    assert not r.get("skipped"), f"gate error must fail open, got {r}"


@pytest.mark.asyncio
async def test_g2_cooldown_trickles_burst(db_path):
    """20 分钟内连推:第 2 条起被冷却闸住。"""
    await _log_push(db_path, "cool-first", NOW - timedelta(minutes=5))
    r = await check_push_budget(db_path, notif_type="automation", now=NOW)
    assert not r["allowed"] and "cooldown" in r["reason"]

    # after cooldown passes → allowed again (budget still has room)
    r2 = await check_push_budget(db_path, notif_type="automation",
                                 now=NOW + timedelta(minutes=20))
    assert r2["allowed"]


@pytest.mark.asyncio
async def test_g3_notify_now_parks_gated_items_for_digest(db_path):
    """被闸的推送进 overflow(digest 可见),不静默丢弃。"""
    for i in range(6):  # exhaust budget
        await _log_push(db_path, f"g3-{i}", NOW - timedelta(hours=5))

    r = await notify_now(db_path, "催促刷课：加紧补刷", "老师催了",
                         item_id="g3-item", notif_type="ladder_now")
    assert r.get("gated") and r.get("queued_for_digest")

    async with aiosqlite.connect(db_path) as db:
        row = await (await db.execute(
            "SELECT text FROM ideas WHERE text LIKE '%[push-overflow]%'")).fetchone()
    assert row and "催促刷课" in row[0]


@pytest.mark.asyncio
async def test_g4_digest_channels_bypass_gate(db_path):
    """daily_* 通道不受预算限制——闸防的是自动化爆发,不是应用自己的简报。"""
    for i in range(8):
        await _log_push(db_path, f"g4-{i}", NOW - timedelta(hours=i))
    r = await check_push_budget(db_path, notif_type="daily_summary_evening", now=NOW)
    assert r["allowed"] and r["reason"] == "digest_channel"


@pytest.mark.asyncio
async def test_g5_review_tightens_budget_after_noisy_day(db_path, mock_llm):
    """夜间复审:fp_rate>30% → 明日预算自动收紧到 3;干净日恢复默认。"""
    from unittest.mock import patch
    from app.tasks.push_review import run_push_review

    # Review scopes rows to *today* — use real now, not the fixed NOW.
    # Anchor to CST midnight+noon so substr(sent_at,1,10) (UTC) always lands
    # on the review's local-day string regardless of when the test runs.
    titles = ["向老师道歉", "已读群消息", "收到请回复",   # 3 noise
              "明天考试", "作业截止提醒"]                  # 2 real
    for i, t in enumerate(titles):
        # Review keys on the UTC date of now — real-now minus minutes always
        # lands on that same date (test never runs across a UTC midnight).
        stamp = datetime.now(timezone.utc) - timedelta(minutes=i)
        await _log_push(db_path, f"rev-{i}", stamp)

    async with aiosqlite.connect(db_path) as db:  # review reads push_title
        await db.executemany(
            "UPDATE notification_log SET push_title=? WHERE item_id=?",
            [(t, f"rev-{i}") for i, t in enumerate(titles)])
        await db.commit()

    async with aiosqlite.connect(db_path) as db:  # tag them as ladder_now rows
        await db.execute(
            "UPDATE notification_log SET notif_type='ladder_now' WHERE item_id LIKE 'rev-%'")
        await db.commit()

    state = SimpleNamespace(settings=SimpleNamespace(database_path=db_path,
                                                     standby_agent_provider=None,
                                                     standby_agent_model=None))

    import app.services.provider_registry as registry_mod

    async def fake_resolve(provider_id):
        return {"id": "mock"}, "mock-key"

    mock_llm.responses = [json.dumps({
        "judgements": [
            {"title": titles[0], "actionable": False, "reason": "已完成对话"},
            {"title": titles[1], "actionable": False, "reason": "回执"},
            {"title": titles[2], "actionable": False, "reason": "回执"},
            {"title": titles[3], "actionable": True},
            {"title": titles[4], "actionable": True},
        ],
        "false_positive_count": 3})]

    with patch.object(registry_mod, "resolve_provider", fake_resolve):
        result = await run_push_review(state)
    assert result["ok"] and result["pushed"] == 5
    assert result["false_positives"] == 3
    assert result.get("budget_tightened") == 3      # fp_rate 0.6 > 0.3

    async with aiosqlite.connect(db_path) as db:
        row = await (await db.execute(
            "SELECT value FROM settings WHERE key='push_daily_limit'")).fetchone()
    assert row and row[0] == "3"

    # clean day → relaxes back to default (row deleted)
    mock_llm.responses = [json.dumps({"judgements": [], "false_positive_count": 0})]
    with patch.object(registry_mod, "resolve_provider", fake_resolve):
        result2 = await run_push_review(state)
    assert result2.get("budget_relaxed")
    async with aiosqlite.connect(db_path) as db:
        row2 = await (await db.execute(
            "SELECT value FROM settings WHERE key='push_daily_limit'")).fetchone()
    assert row2 is None


@pytest.mark.asyncio
async def test_g6_incident_replay_budget_caps_that_day(db_path):
    """历史重放:事故当天 9 连推,在预算闸下只有前 6 条能出去,
    且后 3 条进 overflow——数学上封顶,与语义无关。"""

    incident_titles = [
        "计算机工程实践/数据库系统课程设计已结课",
        "向数据库系统课程设计老师道歉",
        "网课未刷课联系老师",
        "催促刷课：网课加紧补刷",
        "逾期未刷可能导致重修",
        "刷课不显示完成",
        "已读群消息",
        "回复老师：没有网络课程不知要刷课",
        "网课刷课进展：下午内刷完",
    ]
    allowed, gated = [], []
    t = datetime(2026, 7, 2, 6, 16, tzinfo=timezone.utc)
    for i, title in enumerate(incident_titles):
        decision = await check_push_budget(db_path, notif_type="ladder_now", now=t)
        if decision["allowed"]:
            allowed.append(title)
            await _log_push(db_path, f"inc-{i}", t)  # simulate it going out
        else:
            gated.append(title)

    assert len(allowed) <= 6                          # hard cap held
    assert len(gated) >= 3                            # rest parked for digest
    # The apology push specifically lands within the first 6 here — which is
    # exactly why the gate is the LAST layer, not the only one (X1-X4 catch it
    # earlier). Defense in depth: each layer shrinks the blast radius.
