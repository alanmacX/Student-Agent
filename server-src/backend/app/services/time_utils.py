from __future__ import annotations

from datetime import datetime, time, timedelta, timezone
from typing import Any
from zoneinfo import ZoneInfo

LOCAL_TZ = ZoneInfo("Asia/Shanghai")
UTC = timezone.utc


def utc_now() -> datetime:
    return datetime.now(UTC)


def local_now() -> datetime:
    return utc_now().astimezone(LOCAL_TZ)


def parse_any_time(value: Any, default_tz: ZoneInfo = LOCAL_TZ) -> datetime | None:
    if value is None or value == "":
        return None
    if isinstance(value, datetime):
        dt = value
    elif isinstance(value, (int, float)):
        dt = _epoch_to_datetime(float(value))
    else:
        raw = str(value).strip()
        if not raw:
            return None
        if raw.isdigit():
            dt = _epoch_to_datetime(float(raw))
        else:
            try:
                dt = datetime.fromisoformat(raw.replace("Z", "+00:00"))
            except ValueError:
                return None
    if dt.tzinfo is None:
        dt = dt.replace(tzinfo=default_tz)
    return dt


def normalize_to_utc_iso(value: Any, default_tz: ZoneInfo = LOCAL_TZ) -> str | None:
    dt = parse_any_time(value, default_tz=default_tz)
    return to_utc_iso(dt) if dt else None


def to_utc_iso(dt: datetime) -> str:
    if dt.tzinfo is None:
        dt = dt.replace(tzinfo=LOCAL_TZ)
    return dt.astimezone(UTC).isoformat()


def to_local_iso(dt: datetime, tz: ZoneInfo = LOCAL_TZ) -> str:
    if dt.tzinfo is None:
        dt = dt.replace(tzinfo=UTC)
    return dt.astimezone(tz).isoformat()


def local_day_window(value: datetime | None = None, tz: ZoneInfo = LOCAL_TZ) -> tuple[datetime, datetime]:
    now = value or utc_now()
    if now.tzinfo is None:
        now = now.replace(tzinfo=tz)
    local = now.astimezone(tz)
    start = datetime.combine(local.date(), time.min, tzinfo=tz)
    end = start + timedelta(days=1)
    return start.astimezone(UTC), end.astimezone(UTC)


def local_week_window(value: datetime | None = None, tz: ZoneInfo = LOCAL_TZ) -> tuple[datetime, datetime]:
    now = value or utc_now()
    if now.tzinfo is None:
        now = now.replace(tzinfo=tz)
    local = now.astimezone(tz)
    start_date = local.date() - timedelta(days=local.weekday())
    start = datetime.combine(start_date, time.min, tzinfo=tz)
    end = start + timedelta(days=7)
    return start.astimezone(UTC), end.astimezone(UTC)


def coerce_sql_time(value: Any, default_tz: ZoneInfo = LOCAL_TZ) -> str:
    normalized = normalize_to_utc_iso(value, default_tz=default_tz)
    return normalized or ""


def _epoch_to_datetime(value: float) -> datetime:
    # 13-digit timestamps are milliseconds; 10-digit timestamps are seconds.
    if abs(value) > 1_000_000_000_000:
        value = value / 1000
    return datetime.fromtimestamp(value, tz=UTC)
