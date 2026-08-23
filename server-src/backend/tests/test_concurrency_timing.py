"""Round 1 — Concurrency & timing adversarial tests.

Real-world failure modes that unit tests miss:
  C1 并发同步     — scheduler overlap: two run_dingtalk_memory_sync at once
  C2 乱序到达     — messages inserted out of order / late-arriving older msg
  C3 时钟回拨     — now earlier than stored cursor
  C4 批次边界     — message exactly at LIMIT boundary not lost
  C5 同 mid 重放  — INSERT OR IGNORE + reconcile idempotency
"""
from __future__ import annotations

import asyncio
import json
from datetime import datetime, timedelta, timezone

import aiosqlite
import pytest

from app.dingtalk import memory_provider as mp
from app.services.reconciler import ReconcileResult, reconcile_message as real_reconcile

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
                (m["mid"], m.get("cid", "c1"), m["conv"], m["sender"],
                 m["text"], 1, m.get("verdict", "notify"), m["created_at"]),
            )
        await db.commit()


def _msg(mid: int, text: str, created_at: int, conv: str = "课程群",
         verdict: str = "notify", sender: str = "张老师") -> dict:
    return {"mid": mid, "cid": conv, "conv": conv, "sender": sender,
            "text": text, "verdict": verdict, "created_at": created_at}


async def _count_items(db_path: str) -> int:
    async with aiosqlite.connect(db_path) as db:
        row = await (await db.execute(
            "SELECT COUNT(*) FROM chaoxing_memory_entries")).fetchone()
    return row[0]


@pytest.mark.asyncio
async def test_c1_concurrent_sync_runs_do_not_double_process(db_path, mock_llm):
    """两个并发 sync(调度器重叠):第二个必须被锁跳过或看到已推进的游标。

    实测(20 次重复实验)无锁时两个 run 都会拿到同一批消息 → 双倍 LLM 成本。
    加 _SYNC_LOCK 后第二个 run 直接 skip。
    """
    await _insert_msgs(db_path, [
        _msg(801, "下周二交期末大作业,过时不候", BASE_TS),
        _msg(802, "记得带上实验手册", BASE_TS + 1000),
    ])
    mock_llm.responses = [json.dumps({"ops": [], "need_more": False})]

    results = await asyncio.gather(
        mp.run_dingtalk_memory_sync(db_path, {"id": "mock"}, "m", "k", now=NOW),
        mp.run_dingtalk_memory_sync(db_path, {"id": "mock"}, "m", "k",
                                    now=NOW + timedelta(seconds=1)),
    )
    total_processed = sum(r.get("processed", 0) for r in results)
    # Exactly one run does the work; the other skips via lock.
    skipped = [r for r in results if r.get("skipped") == "sync_in_flight"]
    assert len(skipped) == 1, f"expected exactly one skip, got {results}"
    assert total_processed == 2
    assert len(mock_llm.calls) == 1  # one batched LLM call total
    assert (await mp._get_last_synced_ts(db_path)) >= BASE_TS


@pytest.mark.asyncio
async def test_c2_late_arriving_older_message_is_not_lost(db_path, mock_llm):
    """晚到的旧消息(created_at < 游标)会被游标跳过——这是设计取舍,
    但必须保证它至少留在 dingtalk_messages 里可审计,且不会破坏后续同步。"""
    await _insert_msgs(db_path, [
        _msg(901, "正常顺序的新消息", BASE_TS),
    ])
    mock_llm.responses = [json.dumps({"ops": [], "need_more": False})]
    r1 = await mp.run_dingtalk_memory_sync(db_path, {"id": "mock"}, "m", "k", now=NOW)
    assert r1["processed"] == 1
    cursor = await mp._get_last_synced_ts(db_path)

    # Late arrival with OLDER timestamp than cursor
    await _insert_msgs(db_path, [
        _msg(850, "这条消息其实更早才到", BASE_TS - 5000),
        _msg(902, "之后又来的新消息", cursor + 1000),
    ])
    mock_llm.responses = [json.dumps({"ops": [], "need_more": False})]
    r2 = await mp.run_dingtalk_memory_sync(db_path, {"id": "mock"}, "m", "k",
                                           now=NOW + timedelta(minutes=1))
    # New message processed; old one remains auditable in raw table
    assert r2["processed"] == 1
    async with aiosqlite.connect(db_path) as db:
        row = await (await db.execute(
            "SELECT COUNT(*) FROM dingtalk_messages WHERE mid=850")).fetchone()
    assert row[0] == 1  # still there for audit


@pytest.mark.asyncio
async def test_c3_clock_skew_backwards_now(db_path, mock_llm):
    """now 早于已有数据/游标时不得崩溃或写出倒挂时间。"""
    await _insert_msgs(db_path, [
        _msg(951, "时间敏感的消息内容", BASE_TS),
    ])
    mock_llm.responses = [json.dumps({"ops": [], "need_more": False})]
    past_now = NOW - timedelta(days=365)
    r = await mp.run_dingtalk_memory_sync(db_path, {"id": "mock"}, "m", "k",
                                          now=past_now)
    assert "processed" in r  # did not crash
    # last_run_at written is the skewed now — acceptable; cursor uses msg ts
    assert (await mp._get_last_synced_ts(db_path)) >= BASE_TS


@pytest.mark.asyncio
async def test_c4_limit_boundary_batch_does_not_drop_tail(db_path, mock_llm):
    """恰好 30 条(LIMIT)= 全部处理;31 条时第 31 条必须留在下一轮。"""
    msgs = [_msg(1000 + i, f"批量消息内容编号{i}号,足够长", BASE_TS + i * 20000)
            for i in range(35)]
    await _insert_msgs(db_path, msgs)

    seen_batches: list[list[str]] = []

    async def tracking_reconcile(msg, dbp, provider, model, api_key, now,
                                 sibling_messages=None):
        seen_batches.append([s["mid"] for s in (sibling_messages or [])] +
                            [str(msg.get("mid"))])
        return ReconcileResult(ok=True)

    import unittest.mock as um
    with um.patch.object(mp, "reconcile_message", tracking_reconcile):
        r1 = await mp.run_dingtalk_memory_sync(db_path, {"id": "mock"}, "m", "k",
                                               now=NOW)
    assert r1["processed"] == 30
    first_round_mids = {m for b in seen_batches for m in b}

    # Round 2 picks up the remaining 5
    seen_batches.clear()
    with um.patch.object(mp, "reconcile_message", tracking_reconcile):
        r2 = await mp.run_dingtalk_memory_sync(db_path, {"id": "mock"}, "m", "k",
                                               now=NOW + timedelta(minutes=1))
    assert r2["processed"] == 5
    second_round = {m for b in seen_batches for m in b}
    # No message processed twice across rounds
    assert not (first_round_mids & second_round), "message re-processed across rounds"
    all_seen = first_round_mids | second_round
    assert len(all_seen) == 35, f"lost messages: {35 - len(all_seen)}"


@pytest.mark.asyncio
async def test_c5_duplicate_mid_replay_is_idempotent(db_path, mock_llm):
    """同 mid 消息重放(解密重跑):INSERT OR IGNORE 去重,reconcile 幂等。"""
    from app.memory.keys import canonical_dedupe_key

    msg_row = _msg(1101, "数据结构期中考试定于9月24日上午9点教201进行", BASE_TS)
    await _insert_msgs(db_path, [msg_row])

    op = {"op": "new_item", "kind": "exam", "entity": "new:数据结构",
          "title": "数据结构期中考试",
          "due": "2026-09-24T09:00:00+08:00", "importance": 3}

    # First pass: reconciler creates the exam item
    mock_llm.responses = [json.dumps({"ops": [op], "need_more": False})]
    r1 = await mp.run_dingtalk_memory_sync(db_path, {"id": "mock"}, "m", "k", now=NOW)
    items_after_first = await _count_items(db_path)
    assert items_after_first == 1

    # Replay: same mid re-fetched (simulate crashed state save + rewind)
    stored_hash = None
    async with aiosqlite.connect(db_path) as db:
        row = await (await db.execute(
            "SELECT value FROM settings WHERE key='dingtalk_memory_last_hash'")).fetchone()
        stored_hash = str(row[0]) if row else ""
    await mp._save_batch_state(db_path, 0, 1, stored_hash, NOW)

    mock_llm.responses = [json.dumps({"ops": [op], "need_more": False})]
    r2 = await mp.run_dingtalk_memory_sync(db_path, {"id": "mock"}, "m", "k",
                                           now=NOW + timedelta(minutes=2))
    items_after_second = await _count_items(db_path)
    assert items_after_second == 1, (
        f"dup item created on replay: {items_after_second}")
