"""Health monitor for DingTalk client and Chaoxing session.

Runs every 10 minutes via APScheduler. Checks:
  1. DingTalk WAL freshness (stale > 30 min = client down)
  2. Chaoxing login status
  3. API provider consecutive failures (called externally from classifier)

Sends Web Push alerts with per-tag cooldown (1 hour) to avoid spam.
"""
from __future__ import annotations

import logging
import os
import time
from typing import List, Tuple

from app.services.push_service import (
    has_notified,
    log_notification_sent,
    send_push_to_all_subscribers,
)

logger = logging.getLogger("health_monitor")

WAL_PATH = os.getenv("DINGTALK_WAL_PATH", "/dingtalk_db/dingtalk.db-wal")
WAL_STALE_SECONDS = int(os.getenv("DINGTALK_WAL_STALE_SECONDS", "1800"))  # 30 min

# Track consecutive API failures per provider (in-memory, resets on restart)
_api_fail_count: dict[str, int] = {}


def _check_dingtalk() -> List[Tuple[str, str, str]]:
    """Return list of (tag, title, body) alerts for DingTalk issues."""
    alerts = []
    try:
        mtime = os.path.getmtime(WAL_PATH)
        age = time.time() - mtime
        if age > WAL_STALE_SECONDS:
            alerts.append((
                "dingtalk_stale",
                "钉钉可能掉线",
                f"WAL {int(age // 60)} 分钟无更新，请检查服务器钉钉客户端",
            ))
    except FileNotFoundError:
        alerts.append((
            "dingtalk_missing",
            "钉钉未运行",
            "钉钉 WAL 文件不存在，客户端可能未启动",
        ))
    return alerts


def _check_chaoxing(app_state) -> List[Tuple[str, str, str]]:
    """Return alert if Chaoxing session is logged out."""
    svc = getattr(app_state, "chaoxing_svc", None)
    if svc and not svc.is_logged_in:
        return [("chaoxing_logout", "学习通登录已失效", "请重新登录超星学习通")]
    return []


async def run_health_check(app_state) -> None:
    """Entry point for the scheduler job."""
    db_path = getattr(
        getattr(app_state, "settings", None), "database_path", "/data/chatbot.db"
    )

    alerts: List[Tuple[str, str, str]] = []
    alerts.extend(_check_dingtalk())
    alerts.extend(_check_chaoxing(app_state))

    for tag, title, body in alerts:
        if not await has_notified(db_path, tag, "health"):
            await send_push_to_all_subscribers(db_path, title, body, tag=tag)
            await log_notification_sent(db_path, tag, "health", title)
            logger.warning("Health alert sent: %s — %s", tag, title)
        else:
            logger.debug("Health alert suppressed (cooldown): %s", tag)


async def alert_api_failure(app_state, provider_id: str) -> None:
    """Called from classifier/standby_agent on LLM call failure.

    Only fires after 3 consecutive failures for the same provider.
    """
    key = f"api_fail_{provider_id}"
    _api_fail_count[key] = _api_fail_count.get(key, 0) + 1

    if _api_fail_count[key] < 3:
        return

    db_path = getattr(
        getattr(app_state, "settings", None), "database_path", "/data/chatbot.db"
    )
    if not await has_notified(db_path, key, "health"):
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
