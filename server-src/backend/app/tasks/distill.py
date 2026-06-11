from __future__ import annotations

import json
from datetime import datetime, timedelta, timezone

import aiosqlite


async def run_distill(app_state) -> dict:
    db_path = getattr(getattr(app_state, "settings", None), "database_path", "/data/chatbot.db")
    now = datetime.now(timezone.utc)
    card = await build_screening_card(db_path, now)
    result = {
        "ok": True,
        "screening_card_chars": len(card),
        "updated_at": now.isoformat(),
    }
    async with aiosqlite.connect(db_path) as db:
        await db.execute(
            "INSERT OR REPLACE INTO settings (key, value) VALUES ('screening_card', ?)",
            (card,),
        )
        await db.execute(
            "INSERT OR REPLACE INTO settings (key, value) VALUES ('distill_last_result', ?)",
            (json.dumps(result, ensure_ascii=False),),
        )
        await db.commit()
    return result


async def build_screening_card(db_path: str, now: datetime | None = None) -> str:
    now = now or datetime.now(timezone.utc)
    since = (now - timedelta(days=7)).isoformat()
    async with aiosqlite.connect(db_path) as db:
        db.row_factory = aiosqlite.Row
        courses = await (await db.execute(
            """SELECT name, aliases, attrs, notes
               FROM entities
               WHERE status='active' AND etype='course'
               ORDER BY name LIMIT 80"""
        )).fetchall()
        watches = await (await db.execute(
            """SELECT name, aliases, attrs, notes
               FROM entities
               WHERE status='active' AND etype='watch'
               ORDER BY updated_at DESC LIMIT 40"""
        )).fetchall()
        feedback = await (await db.execute(
            """SELECT action, COUNT(*) AS count
               FROM notification_feedback
               WHERE created_at >= ?
               GROUP BY action""",
            (since,),
        )).fetchall()
        if await _table_exists(db, "message_drop_log"):
            drops = await (await db.execute(
                """SELECT reason, text_preview
                   FROM message_drop_log
                   WHERE dropped_at >= ?
                   ORDER BY RANDOM() LIMIT 10""",
                (since,),
            )).fetchall()
        else:
            drops = []

    lines = [
        "screening_card_v1",
        "目标: 钉钉 F2 只决定 notify/interest/drop。",
        "",
        "课程实体:",
    ]
    if courses:
        for row in courses:
            aliases = _loads(row["aliases"], [])
            attrs = _loads(row["attrs"], {})
            detail = " ".join(str(v) for v in attrs.values() if v)[:80]
            lines.append(f"- {row['name']} aliases={','.join(aliases[:5])} {detail} {row['notes'] or ''}".strip())
    else:
        lines.append("- 暂无")

    lines.extend(["", "关注/watch:"])
    if watches:
        for row in watches:
            aliases = _loads(row["aliases"], [])
            attrs = _loads(row["attrs"], {})
            keywords = attrs.get("keywords") if isinstance(attrs, dict) else None
            if not isinstance(keywords, list):
                keywords = aliases
            lines.append(f"- {row['name']} keywords={','.join(str(k) for k in keywords[:8])} note={row['notes'] or ''}".strip())
    else:
        lines.append("- 暂无")

    lines.extend([
        "",
        "固定判例:",
        "- 作业/实验/考试/ddl/截止/调课/停课/补课/老师/助教/课程群直接相关 => notify",
        "- CS 竞赛/算法/AI/CTF/技术讲座/专业实习科研但无需立刻行动 => interest",
        "- 文体志愿/行政学风通报/失物招领/水群/非专业招聘活动 => drop",
    ])
    if feedback:
        lines.append("")
        lines.append("最近反馈统计:")
        for row in feedback:
            lines.append(f"- {row['action']}: {row['count']}")
    if drops:
        lines.append("")
        lines.append("最近 drop 抽样:")
        for row in drops:
            lines.append(f"- {row['reason']}: {(row['text_preview'] or '')[:80]}")

    return "\n".join(lines)[:8000]


async def _table_exists(db: aiosqlite.Connection, name: str) -> bool:
    row = await (await db.execute(
        "SELECT 1 FROM sqlite_master WHERE type='table' AND name=?",
        (name,),
    )).fetchone()
    return row is not None


def _loads(raw: str | None, default):
    try:
        return json.loads(raw or "")
    except Exception:
        return default
