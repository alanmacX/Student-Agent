"""app/tasks/push_review.py — Nightly semantic review of the day's pushes.

The regex guard is a fast first filter; this is the slow second look. Once a
day (before the evening digest) an LLM re-reads everything the automation path
pushed today and answers one question per item: "did this need to interrupt
the user?" Items judged non-actionable are recorded as false-positive patterns
in settings (push_fp_patterns), which:
  - feeds the digest ("这些其实不用打扰你"),
  - tightens tomorrow's budget via a simple counter (fp_rate),
  - gives the user an auditable log of what the bot pushed on its own.

This is the actual safety net against semantic leakage: it cannot prevent the
buzz (that already happened) but it measurably tightens the loop, and the
fp_rate is what auto-derates aggressive channels.
"""
from __future__ import annotations

import json
import logging
from datetime import datetime, timedelta, timezone

import aiosqlite

logger = logging.getLogger("push.review")

REVIEW_PROMPT = """你是推送质量审计员。下面是今天以"立即推送"名义打扰用户的全部通知。
逐条判断：这条通知是否需要用户【当下放下手头事情】行动？
- 已完成的对话、道歉、确认收到、纯过程记录 → 不需要（false positive）
- 有截止时间、需要当天行动、状态突变 → 需要

只输出 JSON：
{"judgements":[{"title":"...","actionable":true/false,"reason":"≤20字"}],
 "false_positive_count": N}
"""


async def run_push_review(app_state) -> dict:
    db_path = app_state.settings.database_path
    now = datetime.now(timezone.utc)
    provider_id = getattr(app_state.settings, "standby_agent_provider", None) or "openai"
    model = getattr(app_state.settings, "standby_agent_model", None) or "gpt-4o-mini"
    try:
        return await _review(db_path, now, provider_id, model)
    except Exception:
        logger.exception("Push review failed")
        return {"ok": False}


async def _review(db_path: str, now: datetime, provider_id: str, model: str) -> dict:
    from app.services.provider_registry import resolve_provider
    from app.services.agent_service import AgentMsg, agent_complete
    from app.services.budget import log_usage

    async with aiosqlite.connect(db_path) as db:
        rows = await (await db.execute(
            """SELECT push_title, push_body FROM notification_log
               WHERE notif_type='ladder_now'
                 AND substr(sent_at,1,10)=?
                 AND COALESCE(push_title,'') != ''""",
            # sent_at strings are UTC ISO; the day key must be the UTC date of
            # `now` (not local) or rows near midnight CST get silently skipped.
            (now.astimezone(timezone.utc).strftime("%Y-%m-%d"),),
        )).fetchall()
    titles = [r[0] for r in rows]
    if not titles:
        await _save_result(db_path, {"pushed": 0}, now)
        return {"ok": True, "pushed": 0}

    provider, api_key = await resolve_provider(provider_id)
    if not api_key:
        logger.info("Push review: no API key, skipping")
        return {"ok": False, "error": "no_api_key"}

    listing = "\n".join(f"{i+1}. {t}" for i, t in enumerate(titles))
    resp = await agent_complete(
        [AgentMsg(role="system", content=REVIEW_PROMPT),
         AgentMsg(role="user", content=listing)],
        [], provider, model, api_key,
    )
    if resp.usage:
        await log_usage(db_path, "push_review", provider.get("id", ""), model,
                        resp.usage, now)

    parsed = _parse(resp.text or "")
    fps = [j for j in parsed.get("judgements", []) if j.get("actionable") is False]
    fp_titles = [j.get("title", "") for j in fps]

    result = {
        "ok": True,
        "pushed": len(titles),
        "false_positives": len(fps),
        "fp_titles": fp_titles,
        "fp_rate": round(len(fps) / max(1, len(titles)), 2),
    }
    # Auto-derate: when >30% of today's pushes were noise, tighten tomorrow.
    if result["fp_rate"] > 0.3:
        async with aiosqlite.connect(db_path) as db:
            await db.execute(
                """INSERT OR REPLACE INTO settings (key,value) VALUES ('push_daily_limit','3')""")
            await db.commit()
        result["budget_tightened"] = 3
    else:
        async with aiosqlite.connect(db_path) as db:
            cur = await (await db.execute(
                "SELECT value FROM settings WHERE key='push_daily_limit'")).fetchone()
        if cur and cur[0] == "3":   # relax back after a clean day
            async with aiosqlite.connect(db_path) as db:
                await db.execute("DELETE FROM settings WHERE key='push_daily_limit'")
                await db.commit()
            result["budget_relaxed"] = True

    await _save_result(db_path, result, now)
    return result


def _parse(text: str) -> dict:
    s, e = text.find("{"), text.rfind("}")
    if s < 0 or e <= s:
        return {}
    try:
        return json.loads(text[s:e + 1])
    except Exception:
        return {}


async def _save_result(db_path: str, result: dict, now: datetime) -> None:
    async with aiosqlite.connect(db_path) as db:
        await db.execute(
            "INSERT OR REPLACE INTO settings (key, value) VALUES ('push_review_last', ?)",
            (json.dumps({**result, "reviewed_at": now.isoformat()}, ensure_ascii=False),),
        )
        await db.commit()
