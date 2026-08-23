"""DingTalk memory-provider batch tests.

Covers:
  B1 同会话多条相关消息 → 1 次 LLM 调用(打包),不再逐条调用
  B2 hash-skip       → 相同批次重复触发,0 次 LLM 调用
  B3 失败不推进游标   → reconcile 报错时 last_ts 不前进,下轮重试
"""
from __future__ import annotations

import json
from datetime import datetime, timedelta, timezone

import aiosqlite
import pytest

from app.dingtalk import memory_provider as mp
from app.services.reconciler import ReconcileResult

NOW = datetime(2026, 9, 14, 10, 0, tzinfo=timezone.utc)


async def _insert_msgs(db_path: str, msgs: list[dict]):
    from app.dingtalk.schema import ensure_schema
    ensure_schema(db_path)
    async with aiosqlite.connect(db_path) as db:
        for m in msgs:
            await db.execute(
                """INSERT OR IGNORE INTO dingtalk_messages
                   (mid, cid, conversation_title, sender_name, text,
                    is_group, verdict, created_at)
                   VALUES (?,?,?,?,?,?,?,?)""",
                (m["mid"], m.get("cid", "c1"), m["conv"], m["sender"],
                 m["text"], 1, m.get("verdict", "notify"), m["created_at"]),
            )
        await db.commit()


def _msg(mid: int, text: str, created_at: int, conv: str = "Web前端开发课程群",
         verdict: str = "notify", sender: str = "张老师") -> dict:
    return {"mid": mid, "cid": "c1", "conv": conv, "sender": sender,
            "text": text, "verdict": verdict, "created_at": created_at}


BASE_TS = int(NOW.timestamp() * 1000)


@pytest.mark.asyncio
async def test_b1_same_conversation_batches_into_one_call(db_path, mock_llm):
    """三条同会话消息(10 分钟内)→ 只调 1 次 LLM,且 sibling 出现在 prompt 里。"""
    await _insert_msgs(db_path, [
        _msg(101, "各位同学注意,周三的课停一次", BASE_TS),
        _msg(102, "补课时间下周三晚上另行通知", BASE_TS + 60_000),
        _msg(103, "收到请回复", BASE_TS + 120_000),
    ])

    mock_llm.responses = [json.dumps({"ops": [], "need_more": False})]

    result = await mp.run_dingtalk_memory_sync(
        db_path, {"id": "mock"}, "m", "k", now=NOW)

    assert len(mock_llm.calls) == 1, f"expected 1 batched call, got {len(mock_llm.calls)}"
    assert result["processed"] == 3
    # sibling messages must be visible in the single prompt
    user_content = mock_llm.calls[0]["user"]
    assert "邻近消息" in user_content and "补课时间" in user_content


@pytest.mark.asyncio
async def test_b2_hash_skip_avoids_second_llm_run(db_path, mock_llm):
    """同一批消息第二次同步(hash 未变)→ 直接跳过,0 次调用。"""
    await _insert_msgs(db_path, [
        _msg(201, "明天下午2点在教307开班会,讨论选课", BASE_TS),
    ])
    mock_llm.responses = [json.dumps({"ops": [], "need_more": False})]

    r1 = await mp.run_dingtalk_memory_sync(db_path, {"id": "mock"}, "m", "k", now=NOW)
    assert len(mock_llm.calls) == 1

    # Rewind the cursor (simulating a duplicate fetch of the same batch) while
    # KEEPING the stored hash — e.g. a crashed run between fetch and store.
    stored_hash_row = await _get_stored_hash(db_path)
    await mp._save_batch_state(db_path, BASE_TS - 1000, 3, stored_hash_row, NOW)
    r2 = await mp.run_dingtalk_memory_sync(db_path, {"id": "mock"}, "m", "k",
                                           now=NOW + timedelta(minutes=5))
    assert r2.get("skipped") == "hash_match"
    assert len(mock_llm.calls) == 1  # no new LLM call


async def _get_stored_hash(db_path: str) -> str:
    async with aiosqlite.connect(db_path) as db:
        row = await (await db.execute(
            "SELECT value FROM settings WHERE key='dingtalk_memory_last_hash'"
        )).fetchone()
    return str(row[0]) if row else ""


@pytest.mark.asyncio
async def test_b3_failure_does_not_advance_cursor(db_path, mock_llm, monkeypatch):
    """reconcile 失败 → 游标不动,下一轮还能拿到这批消息。"""
    await _insert_msgs(db_path, [
        _msg(301, "考试安排有变化,具体看通知", BASE_TS),
    ])

    async def failing_reconcile(*a, **k):
        return ReconcileResult(ok=False, errors=["boom"])

    monkeypatch.setattr(mp, "reconcile_message", failing_reconcile)
    r1 = await mp.run_dingtalk_memory_sync(db_path, {"id": "mock"}, "m", "k", now=NOW)
    assert (await mp._get_last_synced_ts(db_path)) == 0  # cursor untouched

    # recover on next run — restore the real reconciler
    from app.services.reconciler import reconcile_message as real_reconcile
    monkeypatch.setattr(mp, "reconcile_message", real_reconcile)
    mock_llm.responses = [json.dumps({"ops": [], "need_more": False})]
    r2 = await mp.run_dingtalk_memory_sync(db_path, {"id": "mock"}, "m", "k",
                                           now=NOW + timedelta(minutes=1))
    assert r2["processed"] >= 1
    assert (await mp._get_last_synced_ts(db_path)) > 0


@pytest.mark.asyncio
async def test_b4_partial_success_advances_only_past_succeeded_groups(
        db_path, mock_llm, monkeypatch):
    """组A成功+组B失败+组C未执行 → 游标只越过A,B/C下轮重试(不丢消息)。"""
    other = "另一个群"
    await _insert_msgs(db_path, [
        _msg(401, "第一组的消息,会成功", BASE_TS),
        _msg(501, "第二组第一条,会失败", BASE_TS + 30 * 60_000, conv=other),
        _msg(502, "第二组第二条", BASE_TS + 30 * 60_000 + 1000, conv=other),
        _msg(601, "第三组消息", BASE_TS + 60 * 60_000),
    ])

    calls = {"n": 0}

    async def flaky_reconcile(msg, *a, **k):
        calls["n"] += 1
        # Group B's primary is its newest message (502) — fail on that.
        if "第二组第二条" in (msg.get("text") or ""):
            return ReconcileResult(ok=False, errors=["simulated"])
        return ReconcileResult(ok=True)

    monkeypatch.setattr(mp, "reconcile_message", flaky_reconcile)
    result = await mp.run_dingtalk_memory_sync(db_path, {"id": "mock"}, "m", "k", now=NOW)

    cursor = await mp._get_last_synced_ts(db_path)
    # Cursor must sit exactly at the end of group A — NOT past failed group B.
    assert cursor == BASE_TS, f"cursor={cursor}, expected {BASE_TS}"
    assert result["processed"] == 1

    # Retry: only groups B and C remain.
    seen = []
    async with aiosqlite.connect(db_path) as db:
        rows = await (await db.execute(
            "SELECT mid FROM dingtalk_messages WHERE verdict IN ('notify','interest') "
            "AND created_at > ? AND text != '' ORDER BY created_at",
            (cursor,))).fetchall()
        seen = [r[0] for r in rows]
    assert set(seen) == {501, 502, 601}


@pytest.mark.asyncio
async def test_b5_primary_prefers_notify_over_interest(db_path, mock_llm):
    """组内最新一条是 interest、前面有 notify → primary 必须选 notify。"""
    await _insert_msgs(db_path, [
        _msg(701, "周五交实验报告的通知", BASE_TS, verdict="notify"),
        _msg(702, "顺便问下有人一起去吗", BASE_TS + 1000, verdict="interest"),
    ])

    captured = {}

    async def capture_reconcile(msg, db_path_, provider, model, api_key, now,
                                sibling_messages=None):
        captured["primary_text"] = msg.get("text")
        captured["sibling_texts"] = [s.get("text") for s in (sibling_messages or [])]
        return ReconcileResult(ok=True)

    from app.services.reconciler import reconcile_message as real
    import unittest.mock as um
    with um.patch.object(mp, "reconcile_message", capture_reconcile):
        result = await mp.run_dingtalk_memory_sync(
            db_path, {"id": "mock"}, "m", "k", now=NOW)

    assert captured["primary_text"].startswith("周五交实验报告")
    assert captured["sibling_texts"] == ["顺便问下有人一起去吗"]
