from __future__ import annotations

from datetime import datetime, timezone
from zoneinfo import ZoneInfo

import aiosqlite


LOCAL_TZ = ZoneInfo("Asia/Shanghai")


def budget_day(now: datetime | None = None) -> str:
    now = now or datetime.now(timezone.utc)
    if now.tzinfo is None:
        now = now.replace(tzinfo=timezone.utc)
    return now.astimezone(LOCAL_TZ).date().isoformat()


async def daily_token_budget(db_path: str) -> int:
    async with aiosqlite.connect(db_path) as db:
        row = await (await db.execute(
            "SELECT value FROM settings WHERE key='daily_token_budget'"
        )).fetchone()
    try:
        return max(0, int(row[0])) if row else 500_000
    except (TypeError, ValueError):
        return 500_000


async def tokens_used_today(db_path: str, now: datetime | None = None) -> int:
    day = budget_day(now)
    async with aiosqlite.connect(db_path) as db:
        row = await (await db.execute(
            """SELECT COALESCE(SUM(input_tokens + output_tokens), 0)
               FROM llm_budget_log WHERE day=?""",
            (day,),
        )).fetchone()
    return int(row[0] or 0)


async def is_budget_exhausted(db_path: str, now: datetime | None = None) -> bool:
    limit = await daily_token_budget(db_path)
    if limit <= 0:
        return False
    return await tokens_used_today(db_path, now) >= limit


async def log_usage(
    db_path: str,
    callpoint: str,
    provider_id: str,
    model: str,
    usage,
    now: datetime | None = None,
) -> None:
    if not usage:
        return
    day = budget_day(now)
    now_iso = (now or datetime.now(timezone.utc)).isoformat()
    input_tokens = int(getattr(usage, "input_tokens", 0) or 0)
    output_tokens = int(getattr(usage, "output_tokens", 0) or 0)
    async with aiosqlite.connect(db_path) as db:
        await db.execute(
            """INSERT INTO llm_budget_log
               (day, callpoint, provider_id, model, input_tokens, output_tokens, calls, updated_at)
               VALUES (?,?,?,?,?,?,1,?)
               ON CONFLICT(day, callpoint, provider_id, model)
               DO UPDATE SET
                 input_tokens=input_tokens + excluded.input_tokens,
                 output_tokens=output_tokens + excluded.output_tokens,
                 calls=calls + 1,
                 updated_at=excluded.updated_at""",
            (
                day,
                callpoint or "unknown",
                provider_id or "",
                model or "",
                input_tokens,
                output_tokens,
                now_iso,
            ),
        )
        await db.commit()
