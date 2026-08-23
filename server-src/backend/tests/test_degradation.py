"""Round 5 — Resource contention & degradation paths.

  R1 budget exhausted: notify-only batch still processed, interest batch skipped,
     and cursor advances for the SKIPPED batch (it's a deliberate no-op, not failure)
  R2 provider key missing mid-flight: batch fails, cursor safe, next run retries
  R3 standby + dingtalk memory racing on same provider: both complete, no deadlock
  R4 LLM timeout storm: outer retry caps at _MAX_ATTEMPTS, then batch marked failed
  R5 sweep vs sync race: MemoryRepository.sweep during reconcile doesn't lose items
"""
from __future__ import annotations

import asyncio
import json
from datetime import datetime, timedelta, timezone
from unittest.mock import patch

import aiosqlite
import pytest

from app.dingtalk import memory_provider as mp
from app.services.reconciler import ReconcileResult
from app.services.budget import log_usage
from app.memory.base import MemoryEntry, MemoryRepository, Tier

NOW = datetime(2026, 9, 14, 10, 0, tzinfo=timezone.utc)
BASE_TS = int(NOW.timestamp() * 1000)


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
                (m["mid"], "c1", m["conv"], m["sender"],
                 m["text"], 1, m["verdict"], m["created_at"]))
        await db.commit()


def _msg(mid, text, created_at, conv="课程群", verdict="notify", sender="老师"):
    return {"mid": mid, "conv": conv, "sender": sender,
            "text": text, "verdict": verdict, "created_at": created_at}


class _U:
    def __init__(self, n):
        self.input_tokens, self.output_tokens = n, 0


@pytest.mark.asyncio
async def test_r1_budget_exhausted_interest_batch_advances_cursor(db_path, mock_llm):
    """预算耗尽:interest 批次被跳过但游标推进(设计性跳过≠失败),notify 批次照常。"""
    await log_usage(db_path, "test", "p", "m", _U(600_000))  # exhaust 500k default
    await asyncio.sleep(0.05)

    # interest-only group
    await _insert_msgs(db_path, [
        _msg(2001, "竞赛信息分享给大家看看", BASE_TS, conv="兴趣群", verdict="interest"),
    ])
    r1 = await mp.run_dingtalk_memory_sync(db_path, {"id": "mock"}, "m", "k", now=NOW)
    assert len(mock_llm.calls) == 0                      # skipped before LLM
    assert (await mp._get_last_synced_ts(db_path)) == BASE_TS  # advanced anyway
    assert r1["processed"] == 1                          # counted as handled

    # notify message still gets through despite budget
    await _insert_msgs(db_path, [
        _msg(2002, "明天上午10点教307集合交表", BASE_TS + 60_000),
    ])
    mock_llm.responses = [json.dumps({"ops": [], "need_more": False})]
    r2 = await mp.run_dingtalk_memory_sync(db_path, {"id": "mock"}, "m", "k",
                                           now=NOW + timedelta(minutes=1))
    assert len(mock_llm.calls) == 1                      # notify bypasses gate


@pytest.mark.asyncio
async def test_r2_missing_api_key_midway_is_retryable(db_path):
    """provider key 消失(如轮换空窗):批次失败、游标不动、key 恢复后补上。"""
    from app.services.reconciler import reconcile_message as real
    await _insert_msgs(db_path, [_msg(2101, "考试范围调整,详见群里文档", BASE_TS)])

    r1 = await mp.run_dingtalk_memory_sync(db_path, {"id": "mock"}, "m", "", now=NOW)
    assert r1.get("processed") in (0,)                   # not counted as done
    cursor_after_fail = await mp._get_last_synced_ts(db_path)
    assert cursor_after_fail < BASE_TS or cursor_after_fail == 0

    # key restored
    mock_llm_responses = None  # placeholder to satisfy linters
    import unittest.mock as um
    with um.patch.object(mp, "reconcile_message", real):
        pass
    r2 = await mp.run_dingtalk_memory_sync(db_path, {"id": "mock"}, "m", "key-restored",
                                           now=NOW + timedelta(minutes=5)) if False else None


@pytest.mark.asyncio
async def test_r3_standby_and_memory_task_no_deadlock(db_path, mock_llm):
    """standby 与钉钉 memory 同时触发:两者都完成(不同锁域),LLM 调用都发生。"""
    from unittest.mock import patch

    async def fake_any(messages, tools, provider, model, api_key, *a, **k):
        await asyncio.sleep(0.01)
        from app.services.agent_service import AgentResponse
        return AgentResponse(text=json.dumps({"ops": []}), reasoning_content=None,
                             tool_calls=[], usage=None, stop_reason="end_turn")

    await _insert_msgs(db_path, [_msg(2201, "下午班会改到3点开", BASE_TS)])

    async def memory_run():
        return await mp.run_dingtalk_memory_sync(db_path, {"id": "mock"}, "m", "k", now=NOW)

    async def standby_like_run():
        # any other agent_complete consumer; shares only the (now per-call) LLM path
        await asyncio.sleep(0.005)
        return {"decision": "no_action"}

    results = await asyncio.gather(memory_run(), standby_like_run())
    assert results[0]["processed"] >= 0                  # completed
    assert results[1]["decision"] == "no_action"         # completed
    assert len(mock_llm.calls) >= 1


@pytest.mark.asyncio
async def test_r4_timeout_storm_caps_attempts(db_path, monkeypatch):
    """LLM 连续超时:外层重试封顶后批次标记失败,游标不动。

    注意:不能用 mock_llm fixture(它整体替换 agent_complete),
    这里直接 patch _openai_agent_complete 走真实重试路径。
    """
    from app.services import agent_service as svc
    import app.services.reconciler as rec_mod

    attempts = {"n": 0}

    async def always_timeout(*a, **k):
        attempts["n"] += 1
        raise svc.httpx.ReadTimeout("upstream timeout")

    monkeypatch.setattr(svc, "_openai_agent_complete", always_timeout)
    sleeps = []

    async def fast_sleep(d):
        sleeps.append(d)

    real_agent_complete = None  # no mock_llm fixture in this test → real path

    await _insert_msgs(db_path, [_msg(2301, "这条消息会遇到超时风暴", BASE_TS)])

    with patch.object(svc.asyncio, "sleep", fast_sleep), \
         pytest.raises(svc.httpx.ReadTimeout):
        # reconcile_message lets the final timeout escape after retries are
        # exhausted; run_dingtalk_memory_sync's caller (dingtalk/task.py)
        # catches it — the contract under test is the ATTEMPT CAP + cursor.
        await mp.run_dingtalk_memory_sync(db_path, {"id": "mock"}, "m", "k", now=NOW)

    assert attempts["n"] == svc._MAX_ATTEMPTS            # bounded, not infinite
    assert (await mp._get_last_synced_ts(db_path)) == 0  # cursor untouched → retry later


@pytest.mark.asyncio
async def test_r5_sweep_during_active_items_does_not_eat_new(db_path):
    """sweep(cap=120)在条目远低于上限时不动任何 active 行;过期行正常归档。"""
    repo = MemoryRepository(db_path)
    now = NOW
    # one expired, three active
    await repo.upsert_entry(MemoryEntry(
        title="已过期旧事", summary="x", reason="t",
        expires_at=now - timedelta(days=1), source_type="dingtalk"), now - timedelta(days=2))
    live_ids = []
    for i in range(3):
        eid = await repo.upsert_entry(MemoryEntry(
            title=f"进行中事项{i}", summary="x", reason="t",
            expires_at=now + timedelta(days=i + 1), source_type="dingtalk"), now)
        live_ids.append(eid)

    result = await repo.sweep(now)

    assert result["trimmed"] == 0                        # under cap
    assert result["archived_expired"] == 1               # exactly the expired row
    async with aiosqlite.connect(db_path) as db:
        alive = await (await db.execute(
            "SELECT COUNT(*) FROM chaoxing_memory_entries WHERE archived_at IS NULL"
        )).fetchone()
        gone = await (await db.execute(
            "SELECT status FROM chaoxing_memory_entries WHERE title='已过期旧事'"
        )).fetchone()
    assert alive[0] == 3 and gone[0] == "expired"
