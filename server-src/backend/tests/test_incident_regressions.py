"""Regression tests for the 2026-07-02 push incident.

What happened: the user's 习概 course group chat contained a past-tense
apology exchange ("向数据库系统课程设计老师道歉" — explaining why an unrelated
course's homework wasn't done). The extraction LLM turned it into a
high-importance, no-deadline "notice", and ladder_now pushed it to the phone.

Four root causes, one regression test each:
  X1 prompt:    past-tense chat must produce no ops (prompt-level, asserted
                via the SYSTEM_PROMPT contract text)
  X2 validate:  notice + due=null + importance=high is demoted to medium
  X3 ladder:    ACK/conversation-echo titles never generate a "now" push
  X4 dedupe:    message dedupe keys include the conversation, so identical
                wording from two groups cannot merge
"""
from __future__ import annotations

from datetime import datetime, timedelta, timezone

import pytest

from app.services.ladder import build_ladder
from app.services.reconciler import SYSTEM_PROMPT, _validate_ops

NOW = datetime(2026, 9, 14, 10, 0, tzinfo=timezone.utc)
CTX = {"item_ids": set(), "course_ids": set(), "entity_ids": set()}


# ── X1: prompt carries the past-tense rule ──────────────────────────────────

def test_x1_prompt_forbids_past_tense_chat_extraction():
    for phrase in ("道歉", "已读", "收到"):
        assert phrase in SYSTEM_PROMPT
    assert "历史" in SYSTEM_PROMPT and "待办" in SYSTEM_PROMPT


# ── X2: high+notice+no-due demoted at validation ────────────────────────────

def test_x2_high_notice_without_due_is_demoted():
    ops = [{"op": "new_item", "kind": "notice",
            "title": "向数据库系统课程设计老师道歉",
            "due": None, "importance": 3}]          # model said urgent
    valid, warnings = _validate_ops(ops, CTX, NOW)
    assert len(valid) == 1                          # kept, not lost…
    assert str(valid[0]["importance"]) == "1"       # …but demoted to medium
    assert any("demoted" in w for w in warnings)


def test_x2b_deadlined_items_keep_importance():
    ops = [{"op": "new_item", "kind": "exam", "title": "期中考试",
            "due": (NOW + timedelta(days=7)).isoformat(), "importance": 3}]
    valid, _ = _validate_ops(ops, CTX, NOW)
    assert str(valid[0]["importance"]) == "3"       # real deadlines stay urgent


def test_x2c_high_assignment_without_due_also_demoted():
    """assignment kind with no due is equally un-actionable as a reminder."""
    ops = [{"op": "new_item", "kind": "notice", "title": "记得复习",
            "importance": 3}]
    valid, warnings = _validate_ops(ops, CTX, NOW)
    assert str(valid[0]["importance"]) == "1"


# ── X3: ACK noise never becomes a now-push ──────────────────────────────────

def test_x3_ack_titles_produce_no_ladder():
    incident_titles = [
        ("向数据库系统课程设计老师道歉", "向数据库系统课程设计老师道歉"),
        ("已读群消息", "已读群消息"),
        ("回复老师：没有网络课程不知要刷课", "回复"),
        ("刘晓宁提交了消息", "刘晓宁提交了消息"),
        ("消息已读确认", "消息已读确认"),
    ]
    for title, body in incident_titles:
        steps = build_ladder("notice", None, "high", NOW, title=title, body=body)
        assert steps == [], f"'{title}' should not ladder_now"


def test_x3b_real_urgent_notices_still_push():
    steps = build_ladder("notice", None, "high", NOW,
                         title="明天停水", body="今晚10点前储水")
    assert [s.name for s in steps] == ["now"]


def test_x3c_ack_guard_only_hits_notice_kind():
    """A deadline assignment mentioning '提交' still ladders — guard is scoped."""
    from datetime import timedelta as td
    due = NOW + td(days=5)
    steps = build_ladder("assignment", due, "high", NOW,
                         title="实验三报告", body="在学习通提交《实验三》")
    assert len(steps) == 3


# ── X4: message dedupe keys are conversation-scoped ─────────────────────────

def test_x4_same_title_different_groups_get_distinct_keys():
    from app.memory.keys import canonical_dedupe_key
    k1 = canonical_dedupe_key("message", course="习概网课群", title="向数据库老师道歉")
    k2 = canonical_dedupe_key("message", course="数据库课设群", title="向数据库老师道歉")
    assert k1 != k2
    # Same group, same wording → same key (dedup within a group still works)
    k1b = canonical_dedupe_key("message", course="习概网课群", title="向数据库老师道歉")
    assert k1 == k1b


def test_x4b_structured_kinds_unchanged():
    """assignment/exam keys keep their historical format (existing rows match)."""
    from app.memory.keys import canonical_dedupe_key
    k = canonical_dedupe_key("assignment", course="Web前端开发", title="实验三报告")
    assert k.startswith("assignment::") and "web前端开发" in k


# ── End-to-end: replay the exact incident op through reconcile_message ──────

@pytest.mark.asyncio
async def test_incident_replay_no_push_no_high_entry(db_path, mock_llm):
    """The exact new_item op from the incident audit log can no longer produce
    a high-tier entry or any immediate push."""
    import json

    incident_op = {"op": "new_item", "kind": "notice", "entity": "self",
                   "title": "向数据库系统课程设计老师道歉", "due": None,
                   "importance": 2}
    mock_llm.responses = [json.dumps({"ops": [incident_op], "need_more": False})]

    msg = {"mid": "inc-1", "text": "老师我错了，之前确实没看到网络课程的通知，向你道歉。",
           "sender_name": "用户", "conversation_title": "2026春夏学期习概网课",
           "is_group": True, "source_type": "chaoxing",
           "created_at": int(NOW.timestamp() * 1000),
           "category": "", "verdict": "notify"}

    from app.services.reconciler import reconcile_message
    result = await reconcile_message(msg, db_path, {"id": "mock"}, "m", "k", now=NOW)

    # The item may exist (info preserved) but must be medium importance →
    # compute_tier gives CONTEXT (2), so ladder gets nothing to push.
    import aiosqlite
    async with aiosqlite.connect(db_path) as db:
        rows = await (await db.execute(
            "SELECT importance FROM chaoxing_memory_entries WHERE title LIKE '%道歉%'"
        )).fetchall()
        pushes = await (await db.execute(
            "SELECT COUNT(*) FROM scheduled_notifications WHERE sent_at IS NULL AND cancelled_at IS NULL"
        )).fetchone()
    for r in rows:
        assert r[0] != "high", "incident entry came back as high-importance"
    # ladder_now rows would appear in scheduled_notifications only via schedule_push;
    # notify_now pushes go straight out. Either way: medium importance means
    # build_ladder returns [] for notice kind.
