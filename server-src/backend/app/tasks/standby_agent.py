"""
Standby Agent — LLM-driven push decision maker.

Runs on a schedule (default: every 15 minutes).
Reads current context from DB, calls LLM, executes its tool call.

The agent has two tools:
  - send_push_notification: push a notification to all subscribers
  - no_action: do nothing (model must always call one of the two)

Design goals:
  - Low cost: use the cheapest available model (economical_model())
  - Low latency: context is pre-built from DB, no Chaoxing network calls
  - Auditable: every run is logged to standby_agent_log table
  - Safe: no_action is always valid; never push the same item twice
"""
from __future__ import annotations

import asyncio
import hashlib
import json
import uuid
from datetime import datetime, timezone, timedelta
import aiosqlite

from app.database import db_conn
from app.config import settings
from app.services.agent_service import AgentMsg, ToolDefinition, ToolCall, agent_complete
from app.services.push_service import send_push_to_all_subscribers, has_notified, log_notification_sent


# ── Tool definitions ──────────────────────────────────────────────────────────

async def _compute_context_hash(db_path: str) -> str:
    """Hash of the 3 tables + system metrics that affect standby decisions."""
    async with aiosqlite.connect(db_path) as db:
        r1 = await (await db.execute(
            "SELECT MAX(updated_at) FROM server_reminders WHERE is_completed=0"
        )).fetchone()
        r2 = await (await db.execute(
            "SELECT MAX(updated_at) FROM chaoxing_memory_entries WHERE archived_at IS NULL"
        )).fetchone()
        r3 = await (await db.execute(
            "SELECT MAX(sent_at) FROM notification_log"
        )).fetchone()
    # Include system metrics in hash so *meaningful* health changes trigger
    # re-evaluation — but bucket them, otherwise the raw per-run jitter in
    # cpu/mem% changes the hash every time and defeats the skip optimization.
    try:
        import psutil
        # CPU: only "pressured" vs not (instantaneous % is pure noise).
        cpu_band = "hi" if psutil.cpu_percent(interval=0) >= 85 else "ok"
        # Mem/disk: coarse 10% buckets.
        mem_band = int(psutil.virtual_memory().percent) // 10
        disk_band = int(psutil.disk_usage('/').percent) // 10
        health_sig = f"{cpu_band}:{mem_band}:{disk_band}"
    except Exception:
        health_sig = "na"

    raw = f"{r1[0]}|{r2[0]}|{r3[0]}|{health_sig}"
    return hashlib.md5(raw.encode()).hexdigest()

STANDBY_TOOLS = [
    ToolDefinition(
        name="send_push_notification",
        description=(
            "向用户手机发送一条推送通知。"
            "仅当有真正需要用户立即知道的事情时调用。"
        ),
        input_schema={
            "type": "object",
            "properties": {
                "title":   {"type": "string", "description": "通知标题（15字以内）"},
                "body":    {"type": "string", "description": "通知正文（50字以内）"},
                "item_id": {"type": "string", "description": "关联条目的唯一ID，用于去重"},
                "urgency": {
                    "type": "string",
                    "enum": ["low", "normal", "high"],
                },
            },
            "required": ["title", "body", "item_id"],
            "additionalProperties": False,
        },
    ),
    ToolDefinition(
        name="no_action",
        description=(
            "不发送任何通知。"
            "当没有需要提醒用户的事项、或该事项已经通知过时，调用此工具。"
        ),
        input_schema={
            "type": "object",
            "properties": {
                "reason": {"type": "string", "description": "简要说明不推送的原因"},
            },
            "required": ["reason"],
            "additionalProperties": False,
        },
    ),
]


# ── System prompt ─────────────────────────────────────────────────────────────

def _build_system_prompt(now: datetime) -> str:
    from app.services.time_context import now_stamp as _now_stamp
    return f"""{_now_stamp(now)}

你是一个后台日程助理，每隔一段时间被唤醒，检查用户的日程和消息，决定是否需要主动推送通知提醒用户。

你必须调用以下两个工具之一：
- send_push_notification：向用户手机推送通知（只在真正需要时使用）
- no_action：不做任何操作

决策标准：
1. 作业/任务截止时间在 3 小时内 → 推送（高优先级）
2. 截止时间在 24 小时内且尚未推送过 → 推送（普通优先级）
3. 有未处理的高重要度学习通消息（action_hint 非空）→ 考虑推送
4. 系统指标异常（CPU>90%、RAM>85%、磁盘>90%）且最近 30 分钟内未告警 → 推送（高优先级），item_id 用 health_alert_{{metric}}_{{时间}}
5. 以上都没有 → 调用 no_action
6. 已经推送过的条目（已在通知记录中）→ no_action，不要重复打扰

你只能发送一条通知，选最重要的一件事。绝对不要发送多条。
不要向用户解释你在做什么——直接调用工具。""".strip()


def _weekday_cn(dt: datetime) -> str:
    return ["周一","周二","周三","周四","周五","周六","周日"][dt.weekday()]


# ── Context builder ───────────────────────────────────────────────────────────

async def _build_context(db_path: str, now: datetime) -> str:
    """
    Build a text summary of current context from DB.
    Does NOT make any network calls — all data comes from local cache.
    """
    lines = []

    async with aiosqlite.connect(db_path) as db:
        db.row_factory = aiosqlite.Row

        # Pending reminders
        reminder_rows = await (await db.execute("""
            SELECT id, title, due_at, is_important
            FROM server_reminders
            WHERE is_completed = 0
            AND (due_at IS NULL OR datetime(due_at) > datetime('now'))
            ORDER BY due_at ASC
            LIMIT 10
        """)).fetchall()

        # High/medium memory entries (not archived, not expired)
        memory_rows = await (await db.execute("""
            SELECT id, title, action_hint, importance, sent_at
            FROM chaoxing_memory_entries
            WHERE importance IN ('high', 'medium')
            AND archived_at IS NULL
            AND (expires_at IS NULL OR datetime(expires_at) > datetime('now'))
            ORDER BY CASE importance WHEN 'high' THEN 0 ELSE 1 END, extracted_at DESC
            LIMIT 5
        """)).fetchall()

        undelivered_rows = await (await db.execute("""
            SELECT item_id, notif_type, sent_at
            FROM notification_log
            WHERE device_received_at IS NULL
            AND datetime(sent_at) > datetime('now', '-1 hour')
            ORDER BY sent_at DESC
            LIMIT 5
        """)).fetchall()

    # System health metrics
    health_info = {}
    try:
        import psutil as _psutil
        health_info = {
            "cpu": round(_psutil.cpu_percent(interval=0.3)),
            "ram": round(_psutil.virtual_memory().percent),
            "disk": round(_psutil.disk_usage("/").percent),
        }
    except Exception:
        pass

    # User memory (notification preferences)
    user_mem_rows = []
    try:
        async with aiosqlite.connect(db_path) as _db2:
            _db2.row_factory = aiosqlite.Row
            user_mem_rows = await (await _db2.execute(
                "SELECT key, value FROM user_memory ORDER BY updated_at DESC LIMIT 10"
            )).fetchall()
    except Exception:
        pass

    if not reminder_rows and not memory_rows and not undelivered_rows and not health_info:
        return "当前没有待办事项或重要消息。"

    if reminder_rows:
        lines.append("【待办事项】")
        for r in reminder_rows:
            r = dict(r)
            due = _fmt_due(r.get("due_at"), now)
            imp = "⭐ " if r.get("is_important") else ""
            lines.append(f"  - {imp}{r['title']}  {due}  [id:{r['id']}]")

    if memory_rows:
        lines.append("【重要学习通消息】")
        for r in memory_rows:
            r = dict(r)
            hint = f"→ {r['action_hint']}" if r.get("action_hint") else ""
            lines.append(f"  - [{r['importance']}] {r['title']}  {hint}  [id:{r['id']}]")

    if undelivered_rows:
        lines.append("【最近未确认到达的通知】")
        for r in undelivered_rows:
            r = dict(r)
            lines.append(f"  - {r['notif_type']} {r['item_id']} sent_at={r['sent_at']}")

    if health_info:
        lines.append("【系统健康】")
        lines.append(f"  CPU {health_info['cpu']}% | RAM {health_info['ram']}% | 磁盘 {health_info['disk']}%")

    if user_mem_rows:
        lines.append("【用户偏好】")
        for r in user_mem_rows:
            r = dict(r)
            lines.append(f"  - {r['key']}: {r['value']}")

    return "\n".join(lines)


def _fmt_due(due_str: str | None, now: datetime) -> str:
    if not due_str:
        return "(无截止时间)"
    try:
        due = datetime.fromisoformat(due_str)
        if due.tzinfo is None:
            due = due.replace(tzinfo=timezone.utc)
        delta = due - now
        total = int(delta.total_seconds())
        if total < 0:
            return "(已过期)"
        h, m = divmod(total // 60, 60)
        if delta <= timedelta(hours=3):
            return f"⚠️ 还剩 {h}h{m}m"
        if delta <= timedelta(hours=24):
            return f"还剩 {h}h{m}m"
        return f"截止 {due.strftime('%m-%d %H:%M')}"
    except Exception:
        return ""


# ── Tool executor ─────────────────────────────────────────────────────────────

async def _execute_standby_tool(tc: ToolCall, db_path: str, now: datetime) -> tuple[str, str, str | None]:
    """
    Returns (decision, push_title_or_none, push_body_or_none).
    decision = "push" | "no_action" | "error"
    """
    if tc.name == "no_action":
        return "no_action", None, None

    if tc.name == "send_push_notification":
        title   = tc.arguments.get("title", "").strip()
        body    = tc.arguments.get("body", "").strip()
        item_id = tc.arguments.get("item_id", uuid.uuid4().hex)
        urgency = tc.arguments.get("urgency", "normal")

        if not title or not body:
            return "error", None, None

        # Dedup: don't push same item twice with standby_agent type
        if await has_notified(db_path, item_id, "standby_agent"):
            return "no_action", None, None

        await send_push_to_all_subscribers(
            db_path,
            title=title,
            body=body,
            tag=f"standby-{item_id[:12]}",
            data={"type": "standby_push", "urgency": urgency, "item_id": item_id},
        )
        await log_notification_sent(db_path, item_id, "standby_agent", title=title, body=body)
        return "push", title, body

    return "error", None, None


# ── Main entry point ──────────────────────────────────────────────────────────

async def run_standby_agent(app_state):
    """
    Called by APScheduler every N minutes.
    Runs an LLM call with context, executes its tool decision, logs result.
    """
    from app.services.provider_registry import resolve_provider
    from app.services.agent_service import merge_system_messages

    db_path = app_state.settings.database_path
    now = datetime.now(timezone.utc)
    t0 = asyncio.get_event_loop().time()

    # Check if there are any push subscribers — skip if none
    async with aiosqlite.connect(db_path) as db:
        sub_count = (await (await db.execute(
            "SELECT COUNT(*) FROM push_subscriptions"
        )).fetchone())[0]

    if sub_count == 0:
        return  # No subscribers, nothing to do

    # Context hash skip: if nothing changed since last run, skip LLM
    current_hash = await _compute_context_hash(db_path)
    async with aiosqlite.connect(db_path) as db:
        last_hash_row = await (await db.execute("""
            SELECT push_body FROM standby_agent_log
            WHERE decision IN ('no_action', 'skipped_no_change')
            ORDER BY ran_at DESC LIMIT 1
        """)).fetchone()
    last_hash = (last_hash_row[0] or "") if last_hash_row else ""
    if last_hash == current_hash:
        async with aiosqlite.connect(db_path) as db:
            await db.execute(
                "INSERT INTO standby_agent_log (ran_at, decision, reason, model, input_tokens, output_tokens, duration_ms) VALUES (?,?,?,?,?,?,?)",
                (now.isoformat(), "skipped_no_change", "context_hash_match", "", 0, 0, 0),
            )
            await db.commit()
        print(f"[StandbyAgent] {now.strftime('%H:%M')} → skipped_no_change (hash match)")
        return

    # Build context and messages
    context = await _build_context(db_path, now)
    system_prompt = _build_system_prompt(now)

    messages = [
        AgentMsg(role="system", content=system_prompt),
        AgentMsg(role="user", content=f"当前状态：\n{context}\n\n请根据以上信息决定是否推送通知。"),
    ]
    messages = merge_system_messages(messages)

    # Resolve provider — use configured standby provider
    provider, api_key = await resolve_provider(
        app_state.settings.standby_agent_provider or "openai"
    )
    model = app_state.settings.standby_agent_model or "gpt-4o-mini"

    decision = "error"
    reason = None
    push_title = None
    push_body = None
    input_tokens = 0
    output_tokens = 0

    try:
        response = await agent_complete(
            messages, STANDBY_TOOLS, provider, model, api_key,
            thinking_budget=0,
        )
        if response.usage:
            input_tokens  = response.usage.input_tokens
            output_tokens = response.usage.output_tokens

        if response.tool_calls:
            tc = response.tool_calls[0]  # Only process first tool call
            decision, push_title, push_body = await _execute_standby_tool(tc, db_path, now)
            reason = f"tool:{tc.name}"
        else:
            # Model generated text but no tool call — treat as no_action
            decision = "no_action"
            reason = "模型判断无需推送"

    except Exception as e:
        decision = "error"
        reason = f"{type(e).__name__}: {str(e)[:200]}"
        print(f"[StandbyAgent] Error: {e}")

    # Log result — store context hash in push_body when no_action for skip comparison
    duration_ms = int((asyncio.get_event_loop().time() - t0) * 1000)
    log_body = current_hash if decision == "no_action" else push_body
    async with aiosqlite.connect(db_path) as db:
        await db.execute(
            """INSERT INTO standby_agent_log
               (ran_at, decision, reason, push_title, push_body, model, input_tokens, output_tokens, duration_ms)
               VALUES (?,?,?,?,?,?,?,?,?)""",
            (now.isoformat(), decision, reason, push_title, log_body,
             model, input_tokens, output_tokens, duration_ms),
        )
        await db.commit()

    print(f"[StandbyAgent] {now.strftime('%H:%M')} → {decision}"
          + (f": {push_title}" if push_title else ""))
