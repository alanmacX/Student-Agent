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
    from datetime import datetime as dt

    await _insert_msgs(db_path, [
        _msg(301, "考试安排有变化,具体看通知", BASE_TS),
    ])

    async def failing_reconcile(*a, **k):
        return ReconcileResult(ok=False, errors=["boom"])

    monkeypatch.setattr(mp, "reconcile_message", failing_reconcile)
    r1 = await mp.run_dingtalk_memory_sync(db_path, {"id": "mock"}, "m", "k", now=NOW)
    ts_after_fail = await mp._get_last_synced_ts(db_path)
    assert ts_after_fail == 0  # cursor untouched

    # recover on next run
    monkeypatch.setattr(mp, "reconcile_message", None) if False else None

    import unittest.mock as um
    with um.patch.object(mp, "reconcile_message", side_effect=None):
        pass
    # restore real function via fresh import object
    import importlib
    import app.services.reconciler as rec_mod
    real = rec_mod.reconcile_message
    monkeypatch.setattr(mp, "reconcile_message", real)
    mock_llm.responses = [json.dumps({"ops": [], "need_more": False})]
    r2 = await mp.run_dingtalk_memory_sync(db_path, {"id": "mock"}, "m", "k",
                                           now=NOW + timedelta(minutes=1))
    assert r2["processed"] >= 1
    assert (await mp._get_last_synced_ts(db_path)) > 0
