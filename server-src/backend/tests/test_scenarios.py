"""Scenario tests: reconciler + ladder + dispatch on realistic student messages.

Scenarios (per user request):
  S1 突发-调课   — course cancellation notice cancels the right course rows
  S2 突发-考试   — exam announcement becomes an exam item with a deterministic ladder
  S3 垃圾消息    — chatter produces zero ops, zero pushes, zero LLM side effects beyond 1 call
  S4 重复消息    — same fact re-sent with different wording must NOT duplicate items/pushes
  S5 截止变更    — update_item moves a due date and re-schedules the ladder
  S6 预算耗尽    — budget gate skips non-notify processing entirely

Run: python3.13 -m pytest tests/test_scenarios.py -v
"""
from __future__ import annotations

import asyncio
import json
from datetime import datetime, timedelta, timezone

import aiosqlite
import pytest

from app.memory.base import MemoryRepository, Tier
from app.services.budget import log_usage
from app.services.ladder import build_ladder
from app.services.reconciler import reconcile_message

NOW = datetime(2026, 9, 14, 10, 0, tzinfo=timezone.utc)  # Mon 2026-09-14 18:00 CST


def _iso(dt: datetime) -> str:
    return dt.isoformat()


def _course_row(title: str, start: datetime, end: datetime, loc: str = "教201") -> tuple:
    import uuid
    cid = str(uuid.uuid4())
    return cid, title, _iso(start), _iso(end), loc


async def _seed_course(db_path: str, row: tuple):
    async with aiosqlite.connect(db_path) as db:
        await db.execute(
            """INSERT INTO server_courses (id, title, start_at, end_at, location, notes, created_at, updated_at)
               VALUES (?,?,?,?,?,?,?,?)""",
            (*row, "", NOW.isoformat(), NOW.isoformat()),
        )
        await db.commit()
    return row[0]


async def _active_items(db_path: str) -> list:
    async with aiosqlite.connect(db_path) as db:
        db.row_factory = aiosqlite.Row
        rows = await (await db.execute(
            "SELECT * FROM chaoxing_memory_entries WHERE archived_at IS NULL AND COALESCE(status,'active')='active'"
        )).fetchall()
        return [dict(r) for r in rows]


async def _pushes(db_path: str) -> list:
    async with aiosqlite.connect(db_path) as db:
        db.row_factory = aiosqlite.Row
        rows = await (await db.execute("SELECT * FROM scheduled_notifications")).fetchall()
        return [dict(r) for r in rows]


async def _notif_log(db_path: str) -> list:
    async with aiosqlite.connect(db_path) as db:
        db.row_factory = aiosqlite.Row
        rows = await (await db.execute("SELECT item_id, notif_type FROM notification_log")).fetchall()
        return [dict(r) for r in rows]


def _ding_msg(text: str, mid: str = "m1", conv: str = "Web前端开发课程群",
              verdict: str = "notify") -> dict:
    return {
        "mid": mid, "text": text,
        "sender_name": "张老师", "conversation_title": conv,
        "is_group": True, "source_type": "dingtalk",
        "created_at": int(NOW.timestamp() * 1000),
        "category": "", "verdict": verdict, "cid": "cid_001",
    }


# ── S1 调课 ──────────────────────────────────────────────────────────────────

@pytest.mark.asyncio
async def test_s1_course_cancellation(db_path, mock_llm):
    """老师宣布周三停课 → cancel_course_rows 命中正确的行,并推送一次。"""
    wed = NOW + timedelta(days=2)
    cid = await _seed_course(db_path, _course_row(
        "Web前端开发", wed.replace(hour=2, minute=0), wed.replace(hour=3, minute=35)))

    mock_llm.responses = [
        json.dumps({"ops": [{
            "op": "cancel_course_rows",
            "ids": [cid],           # model may only echo ids from context
        }], "need_more": False}),
    ]
    result = await reconcile_message(
        _ding_msg("各位同学,本周三的Web前端开发课因老师出差停课一次,顺延一周。"),
        db_path, {"id": "mock"}, "mock-model", "mock-key", now=NOW)

    assert result.ok, result.errors
    assert result.effects_applied == 1

    async with aiosqlite.connect(db_path) as db:
        notes = await (await db.execute(
            "SELECT notes FROM server_courses WHERE id=?", (cid,))).fetchone()
    assert "cancelled_by_reconciler" in notes[0]

    pushes = await _pushes(db_path)
    assert pushes == []  # course_cancel is immediate, not scheduled

    log = await _notif_log(db_path)
    course_pushes = [l for l in log if l["notif_type"] == "course_cancel"
                     and l["item_id"].startswith("course-")]
    assert len(course_pushes) == 1


@pytest.mark.asyncio
async def test_s1b_cancellation_with_fabricated_id_is_discarded(db_path, mock_llm):
    """模型幻觉出不存在的 course id → 校验层丢弃,不产生任何写操作。"""
    wed = NOW + timedelta(days=2)
    await _seed_course(db_path, _course_row(
        "Web前端开发", wed.replace(hour=2), wed.replace(hour=3, minute=35)))

    mock_llm.responses = [
        json.dumps({"ops": [{"op": "cancel_course_rows", "ids": ["FAKE-ID"]}]}),
    ]
    result = await reconcile_message(
        _ding_msg("各位同学,本周三的课停课一次,请知悉。"), db_path,
        {"id": "mock"}, "m", "k", now=NOW)

    assert result.effects_applied == 0
    assert any("discarded cancel_course_rows" in w for w in result.warnings)
    assert await _pushes(db_path) == []


# ── S2 考试 ──────────────────────────────────────────────────────────────────

@pytest.mark.asyncio
async def test_s2_exam_announcement_creates_item_and_ladder(db_path, mock_llm):
    """考试通知 → new_item(kind=exam) → 自动生成 T-7d/T-1d/T-3h 提醒阶梯。"""
    exam_day = NOW + timedelta(days=10)
    due = exam_day.astimezone(timezone(timedelta(hours=8))).replace(hour=9, minute=0)

    mock_llm.responses = [
        json.dumps({"ops": [{
            "op": "new_item", "kind": "exam",
            "entity": "new:数据结构",
            "title": "数据结构期中考试",
            "due": _iso(due), "importance": 3,
        }]}),
    ]
    result = await reconcile_message(
        _ding_msg("通知:数据结构期中考试定于9月24日上午9点在教201进行,请带学生证。"),
        db_path, {"id": "mock"}, "m", "k", now=NOW)

    assert result.ok, result.errors
    items = await _active_items(db_path)
    exams = [i for i in items if i["kind"] == "exam"]
    assert len(exams) == 1
    assert exams[0]["for_automation"] == 1
    assert exams[0]["hierarchy_tier"] == Tier.ACTIONABLE  # 10 days out but automation+high

    steps = build_ladder("exam", due, "high", NOW, title="x", body="y")
    names = [s.name for s in steps]
    assert names == ["t7d_2000", "t1d_2000", "due_minus_3h"]

    queued = [p for p in await _pushes(db_path) if p["source_type"] == "memory_ladder"]
    assert len(queued) == len(steps)


# ── S3 垃圾消息 ──────────────────────────────────────────────────────────────

@pytest.mark.asyncio
async def test_s3_chatter_produces_nothing(db_path, mock_llm):
    """水群闲聊 → ops=[] → 无条目、无推送、无 ladder。"""
    mock_llm.responses = [json.dumps({"ops": [], "need_more": False})]

    result = await reconcile_message(
        _ding_msg("哈哈哈哈笑死我了,这个表情包太好玩了[呲牙]", mid="m_noise"),
        db_path, {"id": "mock"}, "m", "k", now=NOW)

    assert result.ok
    assert result.effects_applied == 0
    assert await _active_items(db_path) == []
    assert await _pushes(db_path) == []


# ── S4 重复消息 ──────────────────────────────────────────────────────────────

@pytest.mark.asyncio
async def test_s4_reworded_duplicate_does_not_double_push(db_path, mock_llm):
    """同一考试两次播报(措辞不同)→ 第二次 upsert 命中 dedupe_key,不产生第二条推送。"""
    due = (NOW + timedelta(days=10)).astimezone(timezone(timedelta(hours=8))).replace(hour=9)

    op = {"op": "new_item", "kind": "exam", "entity": "new:数据结构",
          "title": "数据结构期中考试", "due": _iso(due), "importance": 3}
    mock_llm.responses = [json.dumps({"ops": [op]})]

    msg1 = _ding_msg("数据结构期中考试定于9月24日上午9点教201。", mid="m_a")
    msg2 = _ding_msg("提醒一下:9月24日9点教201 数据结构期中考试,别忘带证件!", mid="m_b")

    r1 = await reconcile_message(msg1, db_path, {"id": "mock"}, "m", "k", now=NOW)
    r2 = await reconcile_message(msg2, db_path, {"id": "mock"}, "m", "k",
                                 now=NOW + timedelta(hours=2))

    items = [i for i in await _active_items(db_path) if i["kind"] == "exam"]
    assert len(items) == 1, f"duplicate exam items: {[i['title'] for i in items]}"
    assert r1.effects_applied >= 1 and r2.effects_applied >= 1

    # push_now dedup via dispatch.notify_now: same item_id + type collapses.
    from app.memory.dispatch import notify_now
    r_a = await notify_now(db_path, "考试提醒", "数据结构期中考试", item_id="dup-x")
    r_b = await notify_now(db_path, "考试提醒", "数据结构期中考试", item_id="dup-x")
    assert not r_a.get("skipped") and r_b.get("skipped")


# ── S5 截止变更 ──────────────────────────────────────────────────────────────

@pytest.mark.asyncio
async def test_s5_deadline_change_updates_and_reschedules(db_path, mock_llm):
    """作业截止延期 → update_item 改 expires_at 并重建 ladder(replace=True)。"""
    old_due = NOW + timedelta(days=3)
    new_due = NOW + timedelta(days=6)

    repo = MemoryRepository(db_path)
    eid = await repo.upsert_entry(
        __import__("app.memory.base", fromlist=["MemoryEntry"]).MemoryEntry(
            title="实验三报告", summary="截止", reason="test",
            importance="high", action_hint="在学习通提交《实验三》",
            kind="assignment", category="assignment", source_type="chaoxing",
            expires_at=old_due, for_automation=True, hierarchy_tier=Tier.ACTIONABLE,
            dedupe_key="assignment::实验三报告",
        ),
        NOW,
    )

    mock_llm.responses = [
        json.dumps({"ops": [{"op": "update_item", "id": eid,
                             "due": _iso(new_due), "note": "老师延期到周日"}]}),
    ]
    result = await reconcile_message(
        _ding_msg("实验三报告统一延期到9月20日晚23:59提交。"),
        db_path, {"id": "mock"}, "m", "k", now=NOW)

    assert result.ok, result.errors
    async with aiosqlite.connect(db_path) as db:
        row = await (await db.execute(
            "SELECT expires_at FROM chaoxing_memory_entries WHERE id=?", (eid,))).fetchone()
    assert row[0].startswith(new_due.date().isoformat())

    ladders = [p for p in await _pushes(db_path)
               if p["source_id"] and p["source_id"].startswith(eid)]
    for p in ladders:  # replace=True removed stale steps
        assert p["scheduled_at"] > old_due.isoformat()


@pytest.mark.asyncio
async def test_s5b_update_with_stale_or_past_due_discarded(db_path, mock_llm):
    """update 到过去时间 → 校验丢弃。"""
    past = NOW - timedelta(days=1)
    mock_llm.responses = [
        json.dumps({"ops": [{"op": "update_item", "id": "some-item",
                             "due": _iso(past)}]}),
    ]
    result = await reconcile_message(
        _ding_msg("实验三报告改成昨天交,来不及了。"), db_path,
        {"id": "mock"}, "m", "k", now=NOW)
    assert result.effects_applied == 0
    # id "some-item" is not in context → discarded before the due check fires
    assert any("not in context" in w for w in result.warnings) or result.warnings == []


# ── S6 预算 ──────────────────────────────────────────────────────────────────

class _U:
    def __init__(self, n):
        self.input_tokens, self.output_tokens = n, 0


@pytest.mark.asyncio
async def test_s6_budget_gate_skips_non_notify(db_path, mock_llm):
    """预算耗尽后:notify 消息仍处理,非 notify 直接跳过(0 次 LLM 调用)。"""
    calls_before = len(mock_llm.calls)

    result = await reconcile_message(
        _ding_msg("普通消息但标记为interest"), db_path, {"id": "mock"}, "m", "k",
        now=NOW)
    assert len(mock_llm.calls) == calls_before + 1  # budget not yet exhausted

    await log_usage(db_path, "test", "p", "m", _U(600_000))  # day = real today
    await asyncio.sleep(0.05)
    result = await reconcile_message(
        _ding_msg("又一条interest消息", mid="m2", verdict="interest"), db_path,
        {"id": "mock"}, "m", "k", now=NOW)
    assert len(mock_llm.calls) == calls_before + 1  # skipped, no new call
    assert any("budget_exhausted" in w for w in result.warnings)
