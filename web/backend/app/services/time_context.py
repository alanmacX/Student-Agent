"""
Shared time-stamp utility.

Call `now_stamp()` once per request and prepend the result to every system prompt.
This ensures every LLM call in the entire app has an accurate, unambiguous
current time regardless of which agent or router is calling.

For the schedule agent `build_dynamic_context` is a richer version of this.
"""
from __future__ import annotations

import zoneinfo
from datetime import datetime

TZ = zoneinfo.ZoneInfo("Asia/Shanghai")
_WEEKDAYS = ["周一", "周二", "周三", "周四", "周五", "周六", "周日"]


def now_cn() -> datetime:
    """Current time in Asia/Shanghai."""
    return datetime.now(TZ)


def now_stamp(dt: datetime | None = None) -> str:
    """
    Return a compact, unambiguous time header to prepend to any system prompt.

    Example output:
        🕐 当前时间：2026-05-27T18:25:33+08:00（周二 18:25:33 CST）
        Unix: 1748339133  ·  今天: 2026-05-27  ·  明天: 2026-05-28
    """
    now = dt or now_cn()
    if now.tzinfo is None:
        now = now.replace(tzinfo=TZ)
    weekday = _WEEKDAYS[now.weekday()]
    unix = int(now.timestamp())
    today = now.strftime("%Y-%m-%d")
    tomorrow = (now.replace(hour=0, minute=0, second=0, microsecond=0)
                .__class__(now.year, now.month, now.day, tzinfo=now.tzinfo)
                )
    from datetime import timedelta
    tomorrow_str = (now + timedelta(days=1)).strftime("%Y-%m-%d")

    return (
        f"🕐 当前时间：{now.isoformat()}（{weekday} {now.strftime('%H:%M:%S')} CST）\n"
        f"Unix timestamp: {unix}  ·  今天: {today}  ·  明天: {tomorrow_str}\n"
        "【时间比较规则】判断某时刻是否在未来：其 Unix timestamp > 当前 Unix timestamp。"
        "例如 scheduled=18:27 → unix=X，current=18:25 → unix=Y，X>Y 说明 18:27 在未来，"
        "不可以把它当作过去。绝对不要凭直觉估算——用 timestamp 数值比较。"
    )


def inject_time(system_prompt: str, dt: datetime | None = None) -> str:
    """Prepend the time stamp to an existing system prompt."""
    stamp = now_stamp(dt)
    if not system_prompt:
        return stamp
    return f"{stamp}\n\n{system_prompt}"
