"""Deterministic reminder ladder for memory items.

This module is deliberately pure business logic plus queue writes. It replaces
the old periodic "should I remind now?" LLM loop with explicit scheduled rows
that can be audited and cancelled by item id.
"""
from __future__ import annotations

from dataclasses import dataclass
from datetime import datetime, time, timedelta, timezone
from zoneinfo import ZoneInfo

import aiosqlite

LOCAL_TZ = ZoneInfo("Asia/Shanghai")


@dataclass(frozen=True)
class LadderStep:
    name: str
    trigger_iso: str
    title: str
    body: str


def build_ladder(
    kind: str,
    due: datetime | None,
    importance: str,
    now: datetime,
    *,
    title: str = "",
    body: str = "",
) -> list[LadderStep]:
    """Build future reminder steps for an item.

    The public shape stays compact and deterministic: same item fields produce
    the same stage names and trigger times, and already-past stages are skipped.
    """
    now = _aware_utc(now)
    due = _aware_utc(due) if due else None
    normalized = _normalize_kind(kind)
    title = (title or "提醒").strip()
    body = (body or title).strip()
    steps: list[tuple[str, datetime, str, str]] = []

    if normalized == "assignment" and due:
        steps.extend([
            ("t3d_2000", _local_day_at(due, -3, time(20, 0)), "作业提醒", f"{title} 还有 3 天截止。{body}"),
            ("t1d_2000", _local_day_at(due, -1, time(20, 0)), "明天截止", f"{title} 明天截止。{body}"),
            ("due_minus_2h", due - timedelta(hours=2), "快截止了", f"{title} 还有不到 2 小时截止。{body}"),
        ])
    elif normalized == "exam" and due:
        steps.extend([
            ("t7d_2000", _local_day_at(due, -7, time(20, 0)), "考试提醒", f"{title} 还有 7 天。{body}"),
            ("t1d_2000", _local_day_at(due, -1, time(20, 0)), "明天考试", f"{title} 明天进行。{body}"),
            ("due_minus_3h", due - timedelta(hours=3), "考试将近", f"{title} 还有不到 3 小时。{body}"),
        ])
    elif normalized in {"course_change", "course_cancel"}:
        steps.append(("now", now, "课程变动", body))
        if due:
            steps.append(("day_0730", _local_day_at(due, 0, time(7, 30)), "课程变动", f"今天留意：{body}"))
    elif normalized == "signup" and due:
        steps.extend([
            ("t3d_2000", _local_day_at(due, -3, time(20, 0)), "报名提醒", f"{title} 还有 3 天截止。{body}"),
            ("day_0900", _local_day_at(due, 0, time(9, 0)), "今天截止", f"{title} 今天截止。{body}"),
        ])
    elif normalized == "notice" and _is_high(importance):
        steps.append(("now", now, title[:18] or "重要通知", body))

    result: list[LadderStep] = []
    cutoff = now - timedelta(seconds=5)
    for name, trigger, step_title, step_body in steps:
        trigger = _aware_utc(trigger)
        if trigger < cutoff:
            continue
        result.append(LadderStep(
            name=name,
            trigger_iso=trigger.isoformat(),
            title=step_title[:30],
            body=step_body[:120],
        ))
    return result


async def cancel_ladder_for_item(db_path: str, item_id: str) -> int:
    """Delete unsent queued ladder rows for one item.

    Rows already sent stay as audit history. The exact prefix is part of the
    redesign contract: source_id is ``{item_id}:{stage_name}``.
    """
    if not item_id:
        return 0
    async with aiosqlite.connect(db_path) as db:
        cur = await db.execute(
            """DELETE FROM scheduled_notifications
               WHERE sent_at IS NULL
                 AND (source_id LIKE ? OR source_id = ?)""",
            (f"{item_id}:%", item_id),
        )
        await db.commit()
        return cur.rowcount


async def schedule_ladder_for_item(
    db_path: str,
    *,
    item_id: str,
    kind: str,
    due: datetime | None,
    importance: str,
    title: str,
    body: str,
    now: datetime,
    replace: bool = True,
) -> int:
    if replace:
        await cancel_ladder_for_item(db_path, item_id)

    steps = build_ladder(kind, due, importance, now, title=title, body=body)
    inserted = 0
    from app.memory.dispatch import schedule_push

    for step in steps:
        result = await schedule_push(
            db_path,
            step.title,
            step.body,
            step.trigger_iso,
            source_type="memory_ladder",
            source_id=f"{item_id}:{step.name}",
            reason=f"ladder:{kind}:{step.name}",
            now=now,
        )
        if result.get("inserted"):
            inserted += 1
    return inserted


async def schedule_ladder_for_items(
    db_path: str,
    item_ids: list[str],
    now: datetime,
    *,
    replace: bool = True,
) -> int:
    if not item_ids:
        return 0
    placeholders = ",".join("?" for _ in item_ids)
    async with aiosqlite.connect(db_path) as db:
        db.row_factory = aiosqlite.Row
        rows = await (await db.execute(
            f"""SELECT id, title, summary, action_hint, importance, kind, category,
                       expires_at, archived_at, status
                FROM chaoxing_memory_entries
                WHERE id IN ({placeholders})""",
            item_ids,
        )).fetchall()

    count = 0
    for row in rows:
        if row["archived_at"] or (row["status"] or "active") != "active":
            continue
        body = row["action_hint"] or row["summary"] or row["title"]
        kind = _normalize_kind(row["category"] or row["kind"])
        due = _parse_dt(row["expires_at"])
        count += await schedule_ladder_for_item(
            db_path,
            item_id=row["id"],
            kind=kind,
            due=due,
            importance=row["importance"] or "medium",
            title=row["title"] or "提醒",
            body=body or row["title"] or "提醒",
            now=now,
            replace=replace,
        )
    return count


def _normalize_kind(kind: str | None) -> str:
    raw = (kind or "notice").strip().lower()
    if raw in {"homework", "assignment", "reminder"}:
        return "assignment"
    if raw in {"exam", "quiz", "test"}:
        return "exam"
    if raw in {"course_change", "course_adjustment", "change"}:
        return "course_change"
    if raw in {"course_cancel", "cancel", "cancellation"}:
        return "course_cancel"
    if raw in {"signup", "registration", "competition"}:
        return "signup"
    return "notice"


def _is_high(importance: str | int | float | None) -> bool:
    if isinstance(importance, (int, float)):
        return importance >= 2
    return str(importance or "").strip().lower() in {"high", "urgent", "critical", "2", "3"}


def _local_day_at(due: datetime, day_delta: int, local_time: time) -> datetime:
    due_local = _aware_utc(due).astimezone(LOCAL_TZ)
    target_date = due_local.date() + timedelta(days=day_delta)
    local_dt = datetime.combine(target_date, local_time, tzinfo=LOCAL_TZ)
    return local_dt.astimezone(timezone.utc)


def _aware_utc(dt: datetime) -> datetime:
    if dt.tzinfo is None:
        dt = dt.replace(tzinfo=timezone.utc)
    return dt.astimezone(timezone.utc)


def _parse_dt(value: str | None) -> datetime | None:
    if not value:
        return None
    try:
        dt = datetime.fromisoformat(value.replace("Z", "+00:00"))
    except ValueError:
        return None
    return _aware_utc(dt)
