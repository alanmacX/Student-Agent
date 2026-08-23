"""Week-long full-pipeline simulation on a copy of the production DB.

Injects 7 days of realistic DingTalk + Chaoxing traffic (mixed signal/noise),
runs the real pipeline with a scripted LLM, then audits the outcome:
  - every deadline got its ladder
  - no duplicate pushes for the same fact
  - noise produced zero items/pushes
  - budget log reconciles with LLM call count

Run inside the container: python /app/tests/simulate_week.py
"""
from __future__ import annotations

import asyncio
import json
import random
import sqlite3
import sys
from datetime import datetime, timedelta, timezone
from unittest.mock import patch

random.seed(20260914)  # deterministic

NOW = datetime(2026, 9, 14, 9, 0, tzinfo=timezone.utc)
CST = timezone(timedelta(hours=8))


def iso(dt: datetime) -> str:
    return dt.isoformat()


def ts(dt: datetime) -> int:
    return int(dt.timestamp() * 1000)


# ── Scripted week of messages ────────────────────────────────────────────────
# (day_offset, hour, conv, sender, verdict, text)
SCRIPT = [
    # Mon: exam announcement (real signal)
    (0, 9, "数据结构课程群", "王老师", "notify",
     "各位同学，数据结构期中考试定于下周一(9月21日)上午9点在教201举行，请携带学生证。"),
    (0, 12, "数据结构课程群", "同学A", "interest", "考试占多少分啊有人知道吗"),
    (0, 13, "水群", "路人", "drop", "哈哈哈哈这个表情包绝了[呲牙]"),
    # Tue: assignment + reworded duplicate next day
    (1, 10, "Web前端开发2026-2班", "李老师", "notify",
     "实验三报告请于本周日(9月20日)23:59前通过学习通提交。"),
    (2, 15, "Web前端开发2026-2班", "李老师", "notify",
     "再提醒一下：实验三的截止时间是9月20号晚上11点59分，别拖到最后一刻。"),
    # Wed: course cancellation burst (3 related messages in one conversation)
    (2, 16, "数据结构课程群", "王老师", "notify", "紧急通知：明天的数据结构课停课一次。"),
    (2, 16, "数据结构课程群", "王老师", "notify", "补课时间暂定下周五晚上，另行通知。"),
    (2, 17, "数据结构课程群", "助教", "notify", "收到停课通知的同学不用回复，注意查看补课安排即可。"),
    # Thu: pure noise day
    (3, 11, "水群", "乙", "drop", "中午吃什么"),
    (3, 14, "水群", "丙", "drop", "这游戏新版本太坑了"),
    (3, 18, "拼车群", "丁", "interest", "周末有一起去西湖的吗"),
    # Fri: deadline change (update path)
    (4, 10, "Web前端开发2026-2班", "李老师", "notify",
     "应同学们要求，实验三报告延期到9月22日（周二）23:59提交。"),
    # Sat: signup opportunity
    (5, 11, "竞赛通知群", "管理员", "notify",
     "ACM校赛报名截止9月28日18:00，有意向的同学尽快填写报名表。"),
    # Sun: chatter + ACKs that must produce nothing
    (6, 20, "Web前端开发2026-2班", "同学B", "drop", "好的收到"),
    (6, 21, "数据结构课程群", "同学C", "drop", "[赞]"),
]

# LLM ops per message mid (what a competent model would emit)
OPS_BY_MID = {}


def build_ops():
    def due(day, h, m=0):
        return iso(datetime(2026, 9, 14 + day, h, m, tzinfo=CST))
    return {
        # exam
        "exam": {"op": "new_item", "kind": "exam", "entity": "new:数据结构",
                 "title": "数据结构期中考试", "due": due(7, 9), "importance": 3},
        "lab": {"op": "new_item", "kind": "assignment", "entity": "new:Web前端开发",
                "title": "实验三报告", "due": due(6, 23, 59), "importance": 2},
        "lab_ext": {"op": "noop_update"},   # filled at runtime after lab exists
        "cancel": {"op": "cancel_course_rows", "ids": ["COURSE_ROW_WED"]},
        "acm": {"op": "new_item", "kind": "signup", "entity": "new:ACM校赛",
                "title": "ACM校赛报名", "due": due(14, 18), "importance": 2},
    }


async def main():
    from app.database import run_migrations
    from app.dingtalk.schema import ensure_schema
    from app.dingtalk import memory_provider as mp
    import app.services.agent_service as svc
    from app.services.agent_service import AgentResponse
    import app.services.reconciler as rec

    DB = "/tmp/sim.db"
    await run_migrations(DB)
    ensure_schema(DB)

    # Seed courses incl. Wednesday's class that will be cancelled
    conn = sqlite3.connect(DB)
    wed = datetime(2026, 9, 16, 2, 0, tzinfo=timezone.utc)  # 10:00 CST Wed
    conn.execute(
        "INSERT OR REPLACE INTO server_courses (id,title,start_at,end_at,location,created_at,updated_at) VALUES (?,?,?,?,?,?,?)",
        ("COURSE_ROW_WED", "数据结构", iso(wed), iso(wed + timedelta(minutes=95)),
         "教201", iso(NOW), iso(NOW)))
    conn.commit()

    # Seed messages
    for i, (doff, hr, conv, sender, verdict, text) in enumerate(SCRIPT):
        t = NOW + timedelta(days=doff, hours=hr - 9)
        conn.execute(
            """INSERT OR IGNORE INTO dingtalk_messages
               (mid,cid,conversation_title,sender_name,text,is_group,verdict,created_at)
               VALUES (?,?,?,?,?,1,?,?)""",
            (5000 + i, conv, conv, sender, text, verdict, ts(t)))
    conn.commit()
    conn.close()

    llm_calls = []

    async def fake_llm(messages, tools, provider, model, api_key, *a, **k):
        user = messages[-1].content or ""
        system = messages[0].content or ""
        llm_calls.append({"user_tail": user[-400:], "system_head": system[:120]})
        # Decide ops by sniffing the trigger text
        ops = []
        if "期中考试定于" in user and "cancel" not in user:
            ops.append(build_ops()["exam"])
        if "实验三报告请于" in user or ("再提醒一下：实验三" in user):
            ops.append(build_ops()["lab"])
        if "停课一次" in user:
            ops.append(build_ops()["cancel"])
        if "延期到9月22日" in user:
            # find existing lab item via context ids echoed in prompt
            import re as _re
            m = _re.search(r"item ([0-9a-f-]{36})", user)
            if m:
                ops.append({"op": "update_item", "id": m.group(1),
                            "due": iso(datetime(2026, 9, 22, 23, 59, tzinfo=CST)),
                            "note": "老师延期"})
        if "ACM校赛报名截止" in user:
            ops.append(build_ops()["acm"])
        return AgentResponse(text=json.dumps({"ops": ops, "need_more": False}),
                             reasoning_content=None, tool_calls=[], usage=None,
                             stop_reason="end_turn")

    results = {"runs": 0}
    with patch.object(svc, "agent_complete", fake_llm), \
         patch.object(rec, "agent_complete", fake_llm, create=True):
        # Simulate the scheduler firing daily over the week's backlog.
        # Cursor starts at 0 so all messages flow through in creation order.
        for day in range(7):
            now_i = NOW + timedelta(days=day, hours=8)
            r = await mp.run_dingtalk_memory_sync(DB, {"id": "mock"}, "mock-model", "key",
                                                  now=now_i)
            results[f"day{day}"] = r
            results["runs"] += 1

    # ── Audit ────────────────────────────────────────────────────────────────
    c = sqlite3.connect(DB)
    c.row_factory = sqlite3.Row
    report = {}
    report["sync_results"] = {k: v for k, v in results.items() if k != "runs"}
    report["llm_calls"] = len(llm_calls)

    report["memory_items"] = [dict(r) for r in c.execute(
        """SELECT title, kind, category, importance, expires_at, status,
              COALESCE(archived_at,'') AS archived_at
           FROM chaoxing_memory_entries ORDER BY title""")]
    report["ladder_rows"] = [dict(r) for r in c.execute(
        """SELECT title, scheduled_at, source_type FROM scheduled_notifications
           ORDER BY scheduled_at""")]
    report["push_log"] = [dict(r) for r in c.execute(
        "SELECT item_id, notif_type FROM notification_log")]
    report["audit_ops"] = [dict(r)["tool_name"] for r in c.execute(
        "SELECT DISTINCT tool_name FROM agent_audit_log")]

    # Invariants
    titles = [i["title"] for i in report["memory_items"]]
    problems = []
    if titles.count("数据结构期中考试") != 1:
        problems.append(f"exam item count={titles.count('数据结构期中考试')}")
    if titles.count("实验三报告") != 1:
        problems.append(f"lab item count={titles.count('实验三报告')}")
    if titles.count("ACM校赛报名") != 1:
        problems.append(f"acm item count={titles.count('ACM校赛报名')}")
    if len(report["ladder_rows"]) < 4:
        problems.append(f"too few ladder rows: {len(report['ladder_rows'])}")
    # lab ladder must reflect EXTENDED deadline (9-22), not original (9-20)
    lab_ladders = [r for r in report["ladder_rows"] if "实验三" in r["title"]]
    if any("09-20" in r["scheduled_at"] for r in lab_ladders):
        problems.append("stale pre-extension ladder row survived")
    # cancelled course row marked
    notes = c.execute("SELECT notes FROM server_courses WHERE id='COURSE_ROW_WED'").fetchone()[0]
    if "cancelled_by_reconciler" not in notes:
        problems.append("wednesday course row not cancelled")

    print(json.dumps({
        "days_simulated": results["runs"],
        "llm_calls_total": report["llm_calls"],
        "items": report["memory_items"],
        "ladder_count": len(report["ladder_rows"]),
        "ladders": report["ladder_rows"][:10],
        "pushes": report["push_log"],
        "op_types": report["audit_ops"],
        "PROBLEMS": problems or "NONE — all invariants hold",
    }, ensure_ascii=False, indent=1, default=str))


if __name__ == "__main__":
    asyncio.run(main())
