"""Health monitor for DingTalk client and Chaoxing session.

Runs every 10 minutes via APScheduler. Checks:
  1. DingTalk liveness — the client writes to its own message DB regularly while
     connected; once the session dies the file simply stops changing. We detect
     death by the DB file's mtime going stale, then push an alert.
  2. Chaoxing login status
  3. API provider consecutive failures (called externally from classifier)

Alerts re-fire on a fixed cooldown for as long as the problem persists — they
are NOT one-shot. (The previous version relied on
``has_notified``, which permanently de-duplicates once a push is device-acked,
so a single early alert silenced DingTalk-down forever — which is exactly why an
8-day outage went unreported.)
"""
from __future__ import annotations

import logging
import os
import sqlite3
import time
from datetime import datetime, timezone
from typing import List, Tuple

from app.services.push_service import (
    log_notification_sent,
    send_push_to_all_subscribers,
)

logger = logging.getLogger("health_monitor")

# Stale threshold: a connected DingTalk client touches its DB far more often than
# this, so crossing it means the session is almost certainly dead. Kept generous
# to avoid false alarms during genuinely quiet stretches (e.g. overnight).
DINGTALK_STALE_SECONDS = int(os.getenv("DINGTALK_STALE_SECONDS", str(6 * 3600)))
# How often a still-unresolved alert is allowed to re-fire.
HEALTH_COOLDOWN_SECONDS = int(os.getenv("HEALTH_COOLDOWN_SECONDS", str(6 * 3600)))
CHAOXING_COOLDOWN_SECONDS = int(os.getenv("CHAOXING_COOLDOWN_SECONDS", str(12 * 3600)))

# Track consecutive API failures per provider (in-memory, resets on restart)
_api_fail_count: dict[str, int] = {}
_chaoxing_last_logged_in: bool | None = None


def _dingtalk_db_age() -> float | None:
    """Seconds since the DingTalk message DB (or its WAL) last changed.

    Uses the same discovery the status endpoint uses so we always look at the
    real account DB, not a guessed path. Returns None if no DB is found
    (treated as 'not logged in' by the caller).
    """
    try:
        from app.dingtalk.dingtalk_service import _discover_db_path
        db = _discover_db_path()
    except Exception:
        db = None
    if not db:
        return None
    newest = 0.0
    for p in (db, db + "-wal"):
        try:
            newest = max(newest, os.path.getmtime(p))
        except OSError:
            pass
    if newest <= 0:
        return None
    return time.time() - newest


def _check_dingtalk() -> List[Tuple[str, str, str, int]]:
    """Return list of (tag, title, body, cooldown_seconds) alerts."""
    age = _dingtalk_db_age()
    if age is None:
        return [(
            "dingtalk_missing",
            "钉钉未登录",
            "未找到钉钉账号数据，客户端可能未运行或从未登录，请在设置中扫码登录。",
            HEALTH_COOLDOWN_SECONDS,
        )]
    if age > DINGTALK_STALE_SECONDS:
        hours = int(age // 3600)
        span = f"{hours} 小时" if hours >= 1 else f"{int(age // 60)} 分钟"
        return [(
            "dingtalk_stale",
            "钉钉可能已掉线",
            f"消息库已 {span} 无更新，登录态可能已失效，请到「设置 → 钉钉」重新扫码登录。",
            HEALTH_COOLDOWN_SECONDS,
        )]
    return []


def _check_chaoxing(app_state) -> List[Tuple[str, str, str, int]]:
    """Return alert if Chaoxing session is logged out."""
    global _chaoxing_last_logged_in
    svc = getattr(app_state, "chaoxing_svc", None)
    if not svc:
        return []
    logged_in = bool(svc.is_logged_in)
    was_logged_in = _chaoxing_last_logged_in
    _chaoxing_last_logged_in = logged_in
    if logged_in:
        return []
    cooldown = 0 if was_logged_in is True else CHAOXING_COOLDOWN_SECONDS
    return [(
        "chaoxing_logout",
        "⚠️ 学习通已掉线，点开重新扫码",
        "点开应用到「设置 → 学习通」重新扫码；恢复前我会每 12 小时提醒一次。",
        cooldown,
    )]


def _seconds_since_last_alert(db_path: str, tag: str) -> float | None:
    """Seconds since this tag was last pushed, or None if never."""
    try:
        with sqlite3.connect(db_path) as conn:
            row = conn.execute(
                "SELECT MAX(sent_at) FROM notification_log WHERE item_id=? AND notif_type='health'",
                (tag,),
            ).fetchone()
    except Exception:
        return None
    if not row or not row[0]:
        return None
    try:
        dt = datetime.fromisoformat(row[0])
        if dt.tzinfo is None:
            dt = dt.replace(tzinfo=timezone.utc)
        return (datetime.now(timezone.utc) - dt).total_seconds()
    except Exception:
        return None


async def run_health_check(app_state) -> None:
    """Entry point for the scheduler job."""
    db_path = getattr(
        getattr(app_state, "settings", None), "database_path", "/data/chatbot.db"
    )

    alerts: List[Tuple[str, str, str, int]] = []
    alerts.extend(_check_dingtalk())
    alerts.extend(_check_chaoxing(app_state))

    for tag, title, body, cooldown in alerts:
        since = _seconds_since_last_alert(db_path, tag)
        if since is not None and since < cooldown:
            logger.debug("Health alert on cooldown (%.0fs ago): %s", since, tag)
            continue
        await send_push_to_all_subscribers(db_path, title, body, tag=tag)
        await log_notification_sent(db_path, tag, "health", title, body)
        logger.warning("Health alert sent: %s — %s", tag, title)


async def alert_api_failure(app_state, provider_id: str) -> None:
    """Called from classifier or other LLM call sites on LLM call failure.

    Only fires after 3 consecutive failures for the same provider.
    """
    key = f"api_fail_{provider_id}"
    _api_fail_count[key] = _api_fail_count.get(key, 0) + 1

    if _api_fail_count[key] < 3:
        return

    db_path = getattr(
        getattr(app_state, "settings", None), "database_path", "/data/chatbot.db"
    )
    since = _seconds_since_last_alert(db_path, key)
    if since is None or since >= HEALTH_COOLDOWN_SECONDS:
        await send_push_to_all_subscribers(
            db_path,
            "AI 接口不可达",
            f"{provider_id} 连续 {_api_fail_count[key]} 次调用失败",
            tag=key,
        )
        await log_notification_sent(db_path, key, "health", key)
        logger.warning("API failure alert sent: %s (%d consecutive)", key, _api_fail_count[key])

    _api_fail_count[key] = 0  # reset after alerting


def reset_api_failure_count(provider_id: str) -> None:
    """Call on successful LLM response to reset the failure counter."""
    key = f"api_fail_{provider_id}"
    _api_fail_count.pop(key, None)
