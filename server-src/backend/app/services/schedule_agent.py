"""
Schedule Agent orchestrator.
Port of ScheduleHarness.swift + ScheduleSkill.swift.
"""
from __future__ import annotations

import json
import re
import time
from datetime import datetime, timedelta, timezone
from typing import AsyncGenerator
import zoneinfo
import aiosqlite

STATIC_SYSTEM_PROMPT = """你是 ChatBot 的日程 Agent，主要管理 Reminders（提醒事项）和日历事件（Calendar），也能读取课程表、学习通作业和学习通消息，以及钉钉群聊/私聊消息。
你可以读取、创建、更新、完成、删除提醒事项，也可以读取、创建、更新、删除日历事件；可以读取学习通作业、学习通 memory，并在 memory 不足时触发 refresh_message_memory。如果你认为某条 memory 不重要或用户明确要求删除，可以使用 delete_message_memory 工具将其删除。只有在用户明确要求修改、完成或删除时才执行写操作。
课程表是 App 内本地导入的数据，不属于系统 Calendar；需要了解上课时间时使用 list_courses。不要为了导入、查看或规划课程表而创建 Calendar 事件。
当用户用自然语言描述课程表（课程名、星期几、第几节、第几周、教室）并希望录入时，使用 import_timetable 工具按周次展开写入本地课程表。先把解析出的课程清单和学期开始日（第 1 周周一）用一句话向用户复述并等待确认，确认后再调用。缺少星期、节次或学期开始日时要主动追问。
不要因为"考试、期中、作业截止、会议、活动、通知"自动查询课程表；只有用户明确提到具体课程名、课程表、上课安排、调课、停课、补课或换教室时，才读取课程表。
需要操作具体提醒事项或日历事件时，先通过工具查到 ID。
工具结果默认只给你阅读。只有用户明确要看列表，才在工具参数里设置 show_in_ui=true。
最终回复使用中文，只写一句简洁摘要；不要重复完整列表，不要输出 Markdown 列表、表格、标题或代码块。"""

BARE_COMPLETION = {"完成", "done", "ok", "好的", "已完成"}


async def run_schedule_agent(
    user_message: str,
    history: list[dict],
    provider: dict,
    model: str,
    api_key: str,
    chaoxing_svc,
    db_path: str,
    thinking_budget: int = 0,
    conversation_id: str = "default",
) -> AsyncGenerator[dict, None]:
    from .agent_service import AgentMsg, ToolDefinition, run_agentic_loop

    now = datetime.now(zoneinfo.ZoneInfo("Asia/Shanghai"))
    custom_prompt = await _get_setting(db_path, "schedule_agent_prompt")
    system_prompt = custom_prompt or STATIC_SYSTEM_PROMPT
    plan = orchestrator_plan(user_message)
    dynamic_context = build_dynamic_context(now)
    turn_context = await build_turn_context(db_path, chaoxing_svc, now, user_message=user_message)
    reports = await collect_reports(plan, db_path, chaoxing_svc, now)

    merged_system = f"{dynamic_context}\n\n{system_prompt}\n\n{turn_context}"

    trimmed_history = history[-(10 * 2):]   # 10 turns is plenty; 20 bloats context
    messages = [AgentMsg(role="system", content=merged_system)]
    for m in trimmed_history:
        messages.append(AgentMsg(role=m["role"], content=m["content"]))
    if not trimmed_history or trimmed_history[-1].get("role") != "user" or trimmed_history[-1].get("content") != user_message:
        messages.append(AgentMsg(role="user", content=f"{reports}\n\n用户消息：{user_message}"))
    elif messages[-1].role == "user":
        messages[-1].content = f"{reports}\n\n用户消息：{messages[-1].content}"

    all_tools = _build_schedule_tools()
    tools = _filter_schedule_tools(all_tools, user_message)
    print(f"[SCHEDULE] tools filtered: {len(tools)}/{len(all_tools)} for msg={user_message[:40]!r}", flush=True)

    # Payload collector: gather structured data from tool results
    payload_collector: dict = {
        "courses": [], "chaoxing_assignments": [], "chaoxing_messages": [],
        "reminders": [], "events": [], "actions": [],
    }
    _TOOL_PAYLOAD_MAP = {
        "list_courses": "courses",
        "get_chaoxing_assignments": "chaoxing_assignments",
        "read_chaoxing_assignments": "chaoxing_assignments",
        "get_memory_insights": "chaoxing_messages",
        "read_message_memory": "chaoxing_messages",
        "get_chaoxing_memory": "chaoxing_messages",
        "list_reminders": "reminders",
        "list_calendar_events": "events",
    }
    _ACTION_TOOLS = {
        "create_reminder", "update_reminder", "complete_reminder", "delete_reminder",
        "create_calendar_event", "update_calendar_event", "delete_calendar_event",
        "schedule_notification", "cancel_scheduled_notification",
        "send_push_notification", "set_push_config", "trigger_memory_scan",
        "import_timetable", "db_execute",
    }

    async def execute_tool(tc):
        result = await _execute_schedule_tool(
            tc, chaoxing_svc, db_path, user_message, provider, model, api_key,
            conversation_id=conversation_id,
        )
        # Collect structured data from read tools
        target = _TOOL_PAYLOAD_MAP.get(tc.name)
        if target:
            try:
                parsed = json.loads(result)
                if isinstance(parsed, list):
                    payload_collector[target].extend(parsed)
                elif isinstance(parsed, dict) and parsed.get("entries"):
                    payload_collector[target].extend(parsed["entries"])
            except (json.JSONDecodeError, TypeError):
                pass
        elif tc.name in _ACTION_TOOLS:
            # A mutation that's only QUEUED for confirmation hasn't happened yet —
            # it surfaces as the confirm button, so don't also dump its raw JSON
            # into the "操作" payload view.
            if isinstance(result, str) and "已加入待确认队列" in result:
                pass
            else:
                try:
                    parsed = json.loads(result)
                except (json.JSONDecodeError, TypeError):
                    parsed = {"result": result}
                await _audit_schedule_tool(db_path, conversation_id, tc.name, tc.arguments, result)
                payload_collector["actions"].append({
                    "tool": tc.name,
                    "arguments": tc.arguments,
                    "result": parsed,
                })
        return result

    async for event in run_agentic_loop(
        messages, tools, execute_tool, provider, model, api_key,
        max_iterations=8, thinking_budget=thinking_budget,
    ):
        yield event

    # If pending mutations were queued this turn, tell the frontend to show the
    # confirm button. (Pending is now a LIST; the old code called .get() on it
    # and threw, silently swallowing the event — which is why no button showed.)
    pending_items = await get_pending_mutations(db_path, conversation_id)
    if pending_items and not is_confirmation_text(user_message):
        tools = [it.get("tool", "") for it in pending_items if isinstance(it, dict)]
        yield {
            "type": "pending_confirmation",
            "tool": tools[0] if tools else "",
            "tools": tools,
            "count": len(pending_items),
        }

    # Yield collected payload if any data was gathered
    has_data = any(len(v) > 0 for v in payload_collector.values())
    if has_data:
        yield {"type": "schedule_payload", **payload_collector}


async def _get_setting(db_path: str, key: str) -> str | None:
    async with aiosqlite.connect(db_path) as db:
        row = await (await db.execute("SELECT value FROM settings WHERE key=?", (key,))).fetchone()
        return row[0] if row else None


async def _set_setting(db_path: str, key: str, value: str | None) -> None:
    async with aiosqlite.connect(db_path) as db:
        if value is None:
            await db.execute("DELETE FROM settings WHERE key=?", (key,))
        else:
            await db.execute(
                "INSERT OR REPLACE INTO settings (key, value) VALUES (?, ?)",
                (key, value),
            )
        await db.commit()


def build_dynamic_context(now: datetime | None = None) -> str:
    from app.services.time_context import now_stamp as _now_stamp
    tz = zoneinfo.ZoneInfo("Asia/Shanghai")
    now = now or datetime.now(tz)
    if now.tzinfo is None:
        now = now.replace(tzinfo=tz)
    weekdays = ["周一", "周二", "周三", "周四", "周五", "周六", "周日"]
    unix = int(now.timestamp())
    example_iso = now.replace(hour=9, minute=0, second=0, microsecond=0).isoformat()
    return (
        _now_stamp(now) + "\n\n"
        f"【日程 Agent 时间规范】\n"
        f"当前 Unix: {unix}。判断是否是未来：target_unix > {unix}。\n"
        f"当用户说今天/明天/下周一，以上方基准时间换算。\n"
        f"所有工具的时间参数必须用带时区偏移的 ISO-8601，例如 {example_iso}。\n"
        f"schedule_notification 的 scheduled_at 必须对应 unix > {unix}，否则是过去时间，须拒绝并请用户重选。"
    )


_build_dynamic_context = build_dynamic_context


async def build_turn_context(db_path, chaoxing_svc, now, window_hours=48, user_message: str = "") -> str:
    end = now + timedelta(hours=window_hours)
    rows = {}
    async with aiosqlite.connect(db_path) as db:
        db.row_factory = aiosqlite.Row
        rows["reminders"] = await (await db.execute("""
            SELECT id, title, due_at, is_important FROM server_reminders
            WHERE is_completed=0 AND due_at IS NOT NULL AND due_at >= ? AND due_at <= ?
            ORDER BY due_at ASC LIMIT 16
        """, (now.isoformat(), end.isoformat()))).fetchall()
        rows["events"] = await (await db.execute("""
            SELECT id, title, start_at, end_at FROM server_events
            WHERE end_at >= ? AND start_at <= ?
            ORDER BY start_at ASC LIMIT 16
        """, (now.isoformat(), end.isoformat()))).fetchall()
        rows["courses"] = await (await db.execute("""
            SELECT title, start_at, end_at, location FROM server_courses
            WHERE end_at >= ? AND start_at <= ?
            ORDER BY start_at ASC LIMIT 16
        """, (now.isoformat(), end.isoformat()))).fetchall()
        rows["memory"] = await (await db.execute("""
            SELECT title, action_hint, importance FROM chaoxing_memory_entries
            WHERE archived_at IS NULL AND importance IN ('high','medium')
            AND (expires_at IS NULL OR expires_at > ?)
            ORDER BY CASE importance WHEN 'high' THEN 1 ELSE 2 END, COALESCE(updated_at, extracted_at, sent_at) DESC
            LIMIT 8
        """, (now.isoformat(),))).fetchall()

    # User memory (preferences, habits)
    user_mem_rows = []
    try:
        async with aiosqlite.connect(db_path) as _db:
            _db.row_factory = aiosqlite.Row
            user_mem_rows = await (await _db.execute(
                "SELECT key, value, category FROM user_memory ORDER BY updated_at DESC LIMIT 20"
            )).fetchall()
    except Exception:
        pass

    lines = [
        "Turn context snapshot. 如需精确完整数据，请调用工具。",
        f"Chaoxing logged in: {bool(getattr(chaoxing_svc, 'is_logged_in', False))}",
    ]
    if user_mem_rows:
        lines.append("【用户记忆】" + "；".join(
            f"{r['key']}: {r['value']} ({r['category']})" for r in user_mem_rows
        ))
    if rows["reminders"]:
        lines.append("未来 48 小时提醒：" + "；".join(
            f"{r['id']} {r['title']} {r['due_at']} important={bool(r['is_important'])}" for r in rows["reminders"]
        ))
    if rows["events"]:
        lines.append("未来 48 小时日历：" + "；".join(
            f"{r['id']} {r['title']} {r['start_at']}-{r['end_at']}" for r in rows["events"]
        ))
    if rows["courses"]:
        lines.append("未来 48 小时课程：" + "；".join(
            f"{r['title']} {r['start_at']}-{r['end_at']} {r['location'] or ''}" for r in rows["courses"]
        ))
    # ── Unified memory: tier-based injection (replaces raw chaoxing + dingtalk snippets) ──
    # Uses MemoryRepository.query_for_agent():
    #   Layer A — tier 0/1 (CRITICAL/ACTIONABLE): always inject
    #   Layer B — tier 2 (CONTEXT): keyword-matched to current turn
    # Legacy rows["memory"] still used as fallback if new repo has nothing.
    try:
        from app.memory.base import MemoryRepository
        # Layer A (tier 0/1) always injects; Layer B (tier 2) is keyword-matched
        # against the current user message so dynamic context surfaces per-turn.
        repo = MemoryRepository(db_path)
        mem_entries = await repo.query_for_agent(now, user_message=user_message, max_tier=2, limit=8)
        if mem_entries:
            def _tier_label(t):
                return {0:"🔴", 1:"🟡", 2:"⚪"}.get(t, "⚪")
            lines.append("Memory（重要程度递减）：" + "；".join(
                f"{_tier_label(r['hierarchy_tier'])}[{r['source_type']}] id={r['id']} {r['title']}"
                f"{' → '+r['action_hint'] if r.get('action_hint') else ''}"
                for r in mem_entries
            ))
        elif rows["memory"]:
            # fallback to legacy query
            lines.append("重要消息：" + "；".join(
                f"[{r['importance']}] {r['title']} {r['action_hint'] or ''}"
                for r in rows["memory"]
            ))
    except Exception:
        if rows["memory"]:
            lines.append("重要学习通消息：" + "；".join(
                f"[{r['importance']}] {r['title']} {r['action_hint'] or ''}"
                for r in rows["memory"]
            ))
    return "\n".join(lines)


def orchestrator_plan(user_text: str) -> dict:
    # Routing lives in intent.py (synonym-expanded, scored). Greetings / generic
    # messages still get an empty plan → minimal context (no fallback to all 4).
    from .intent import plan_subagents
    return plan_subagents(user_text)


async def collect_reports(plan, db_path, chaoxing_svc, now, window_hours=48) -> str:
    end = now + timedelta(hours=window_hours)
    lines = [f"日程 Orchestrator 已先做了轻量只读汇总。注意力窗口：未来 {window_hours} 小时。"]
    async with aiosqlite.connect(db_path) as db:
        db.row_factory = aiosqlite.Row
        if "calendar" in plan["sub_agents"]:
            rows = await (await db.execute("""
                SELECT title, start_at, end_at FROM server_events
                WHERE end_at >= ? AND start_at <= ? ORDER BY start_at ASC LIMIT 5
            """, (now.isoformat(), end.isoformat()))).fetchall()
            lines.append("Calendar: " + ("；".join(f"{r['title']} {r['start_at']}-{r['end_at']}" for r in rows) or "无未来 48 小时事件。"))
        if "reminders" in plan["sub_agents"]:
            rows = await (await db.execute("""
                SELECT title, due_at FROM server_reminders
                WHERE is_completed=0 AND (due_at IS NULL OR due_at <= ?) ORDER BY due_at IS NULL, due_at ASC LIMIT 5
            """, (end.isoformat(),))).fetchall()
            lines.append("Reminders: " + ("；".join(f"{r['title']} {r['due_at'] or '无截止'}" for r in rows) or "无待办。"))
        if "courses" in plan["sub_agents"]:
            rows = await (await db.execute("""
                SELECT title, start_at, end_at, location FROM server_courses
                WHERE end_at >= ? AND start_at <= ? ORDER BY start_at ASC LIMIT 5
            """, (now.isoformat(), end.isoformat()))).fetchall()
            lines.append("Courses: " + ("；".join(f"{r['title']} {r['start_at']}-{r['end_at']} {r['location'] or ''}" for r in rows) or "无未来 48 小时课程。"))
        if "chaoxing" in plan["sub_agents"]:
            rows = await (await db.execute("""
                SELECT title, action_hint, importance FROM chaoxing_memory_entries
                WHERE archived_at IS NULL AND importance IN ('high','medium')
                ORDER BY CASE importance WHEN 'high' THEN 1 ELSE 2 END, COALESCE(updated_at, extracted_at, sent_at) DESC LIMIT 5
            """)).fetchall()
            lines.append("Chaoxing memory: " + ("；".join(f"[{r['importance']}] {r['title']} {r['action_hint'] or ''}" for r in rows) or "为空；如用户需要最新消息，调用 refresh_message_memory。"))
    if plan.get("expects_mutation"):
        lines.append("Mutation note: 写操作必须调用工具并经过确认。")
    return "\n".join(lines)


def _filter_schedule_tools(tools: list, user_message: str) -> list:
    """Return the full tool set.

    The redesign gives the schedule agent a broad, auditable tool surface. The
    earlier keyword pre-screen is intentionally disabled so multi-turn replies
    and unusual phrasing cannot silently remove the exact tool the model needs.
    """
    return tools


def _build_schedule_tools() -> list:
    from .agent_service import ToolDefinition
    return [
        ToolDefinition(
            name="get_schedule_context",
            description="获取当前日程上下文：今日课程、作业截止、重要学习通消息、备忘录",
            input_schema={"type": "object", "properties": {}, "additionalProperties": False},
        ),
        ToolDefinition(
            name="read_message_memory",
            description="读取学习通消息语义记忆库，返回重要/中等重要度的已提取记忆",
            input_schema={
                "type": "object",
                "properties": {
                    "importance_filter": {
                        "type": "string",
                        "enum": ["all", "high", "medium", "high_and_medium"],
                        "description": "过滤重要度",
                    }
                },
                "additionalProperties": False,
            },
        ),
        ToolDefinition(
            name="refresh_message_memory",
            description=(
                "触发学习通 Memory Agent 扫描近期消息并提取记忆。"
                "scope=changed（默认，推荐）只扫描自上次以来有变化的会话，最快最省；"
                "scope=all 重扫全部会话（用户明确要‘全部重扫一遍’时才用）；"
                "scope=conversation 只扫描指定的某个会话（需配合 conversation_id）。"
            ),
            input_schema={
                "type": "object",
                "properties": {
                    "scope": {
                        "type": "string",
                        "enum": ["changed", "all", "conversation"],
                        "description": "扫描范围，默认 changed",
                    },
                    "conversation_id": {
                        "type": "string",
                        "description": "scope=conversation 时指定的会话 ID",
                    },
                },
                "additionalProperties": False,
            },
        ),
        ToolDefinition(
            name="get_chaoxing_assignments",
            description="从学习通实时拉取待提交作业列表",
            input_schema={"type": "object", "properties": {}, "additionalProperties": False},
        ),
        ToolDefinition(
            name="get_chaoxing_messages",
            description="实时读取学习通近期消息；优先使用 read_message_memory，只有用户明确要看原始近期消息时调用。",
            input_schema={
                "type": "object",
                "properties": {
                    "max_conversations": {"type": "integer"},
                    "per_conversation": {"type": "integer"},
                },
                "additionalProperties": False,
            },
        ),
        ToolDefinition(
            name="read_dingtalk_messages",
            description=(
                "读取钉钉消息记录。bucket=notify 返回课程/私聊等重要消息；"
                "bucket=interest 返回 CS 相关竞赛/讲座等可能感兴趣的消息；"
                "bucket=all 返回两者。用户问钉钉消息/群消息/私信时调用。"
            ),
            input_schema={
                "type": "object",
                "properties": {
                    "bucket": {
                        "type": "string",
                        "enum": ["all", "notify", "interest"],
                        "description": "消息桶：all/notify/interest",
                    },
                    "limit": {"type": "integer", "description": "最多返回条数，默认20，最大50"},
                    "since": {"type": "integer", "description": "只返回 created_at > since 的消息（毫秒时间戳），0 表示不限"},
                },
                "additionalProperties": False,
            },
        ),
        ToolDefinition(
            name="delete_message_memory",
            description="删除一条学习通 memory。只有用户明确要求删除某条 memory 时调用。",
            input_schema={
                "type": "object",
                "properties": {"id": {"type": "string"}},
                "required": ["id"],
                "additionalProperties": False,
            },
        ),
        ToolDefinition(
            name="list_watches",
            description="列出用户正在关注/追踪的关键词、比赛、项目或通知主题。",
            input_schema={"type": "object", "properties": {}, "additionalProperties": False},
        ),
        ToolDefinition(
            name="create_watch",
            description="创建一个关注项。用户要求关注、追踪、留意某类消息时调用。需要用户确认。",
            input_schema={
                "type": "object",
                "properties": {
                    "name": {"type": "string", "description": "关注项名称，如 蓝桥杯、数学建模、保研通知"},
                    "keywords": {"type": "array", "items": {"type": "string"}, "description": "触发关键词"},
                    "until": {"type": "string", "description": "ISO8601 到期时间，可为空"},
                    "note": {"type": "string", "description": "关注原因或补充说明"},
                },
                "required": ["name"],
                "additionalProperties": False,
            },
        ),
        ToolDefinition(
            name="delete_watch",
            description="删除/停止一个关注项。需要用户确认。",
            input_schema={
                "type": "object",
                "properties": {
                    "id": {"type": "string", "description": "watch entity id"},
                    "name": {"type": "string", "description": "不知道 id 时可按名称删除"},
                },
                "additionalProperties": False,
            },
        ),
        ToolDefinition(
            name="kb_search",
            description="检索新知识库中的 entities、facts 和活跃事项。用户问知识、课程实体、关注项、历史事实或事项时调用。",
            input_schema={
                "type": "object",
                "properties": {
                    "query": {"type": "string", "description": "搜索词"},
                    "limit": {"type": "integer", "description": "最多返回条数，默认 8，最大 20"},
                },
                "required": ["query"],
                "additionalProperties": False,
            },
        ),
        ToolDefinition(
            name="list_agent_audit",
            description="查看最近 Agent 实际执行过的写操作审计记录。",
            input_schema={
                "type": "object",
                "properties": {
                    "limit": {"type": "integer", "description": "最多返回条数，默认 10，最大 50"}
                },
                "additionalProperties": False,
            },
        ),
        ToolDefinition(
            name="db_query",
            description="只读查询本地 SQLite 数据库。仅允许 SELECT/PRAGMA，结果会限制条数。",
            input_schema={
                "type": "object",
                "properties": {
                    "sql": {"type": "string", "description": "SELECT 或 PRAGMA 查询"},
                    "limit": {"type": "integer", "description": "最多返回行数，默认 20，最大 100"},
                },
                "required": ["sql"],
                "additionalProperties": False,
            },
        ),
        ToolDefinition(
            name="db_execute",
            description="执行受限数据库写操作。只在用户明确要求底层修正数据时使用，必须先进入确认队列并写审计。",
            input_schema={
                "type": "object",
                "properties": {
                    "sql": {"type": "string", "description": "单条 INSERT/UPDATE/DELETE SQL"},
                    "params": {"type": "array", "items": {"type": "string"}, "description": "参数数组"},
                    "reason": {"type": "string", "description": "为什么要执行这条写操作"},
                },
                "required": ["sql", "reason"],
                "additionalProperties": False,
            },
        ),
        ToolDefinition(
            name="list_reminders",
            description="读取服务器维护的提醒事项列表",
            input_schema={
                "type": "object",
                "properties": {
                    "include_completed": {"type": "boolean", "description": "是否包含已完成提醒"}
                },
                "additionalProperties": False,
            },
        ),
        ToolDefinition(
            name="create_reminder",
            description="在服务器维护的提醒事项中创建一条提醒。只有用户明确确认执行后才调用；否则先向用户复述变更并等待确认。",
            input_schema={
                "type": "object",
                "properties": {
                    "title": {"type": "string"},
                    "dueDate": {"type": "string", "description": "ISO8601 截止时间，可为空"},
                    "notes": {"type": "string"},
                    "listName": {"type": "string"},
                },
                "required": ["title"],
                "additionalProperties": False,
            },
        ),
        ToolDefinition(
            name="update_reminder",
            description="按 ID 修改服务器维护的提醒事项。需要用户明确确认。",
            input_schema={
                "type": "object",
                "properties": {
                    "id": {"type": "string"},
                    "title": {"type": "string"},
                    "dueDate": {"type": "string", "description": "ISO8601 截止时间；传空字符串可清空"},
                    "notes": {"type": "string"},
                    "listName": {"type": "string"},
                    "isImportant": {"type": "boolean"},
                },
                "required": ["id"],
                "additionalProperties": False,
            },
        ),
        ToolDefinition(
            name="complete_reminder",
            description="完成服务器维护的一条提醒事项。需要先知道 reminder id，且需要用户明确确认。",
            input_schema={
                "type": "object",
                "properties": {"id": {"type": "string"}},
                "required": ["id"],
                "additionalProperties": False,
            },
        ),
        ToolDefinition(
            name="delete_reminder",
            description="删除服务器维护的一条提醒事项。需要先知道 reminder id，且需要用户明确确认。",
            input_schema={
                "type": "object",
                "properties": {"id": {"type": "string"}},
                "required": ["id"],
                "additionalProperties": False,
            },
        ),
        ToolDefinition(
            name="list_courses",
            description="读取 app 本地课程表。课程不属于 Calendar 日历事件。",
            input_schema={
                "type": "object",
                "properties": {
                    "days": {"type": "integer", "description": "从当前时间起查询多少天，默认 14"},
                    "query": {"type": "string", "description": "按课程名、地点、备注过滤"},
                },
                "additionalProperties": False,
            },
        ),
        ToolDefinition(
            name="import_timetable",
            description=(
                "导入或重建本周/本学期的【课程表】（写入本地课程表，不是 Calendar 日历事件）。"
                "当用户用自然语言描述了上课安排（课程名、星期几、第几节、周次、教室）并确认导入时调用。"
                "会覆盖之前导入的课程表。需要先与用户确认课程清单和学期开始日（第 1 周的周一）。"
                "节次时间表：1=08:00,2=08:55,3=10:00,4=10:55,5=14:00,6=14:55,7=16:00,8=16:55,9=19:00,10=19:55,11=20:50,12=21:45。"
            ),
            input_schema={
                "type": "object",
                "properties": {
                    "semester_start": {
                        "type": "string",
                        "description": "第 1 周周一的日期，格式 YYYY-MM-DD",
                    },
                    "courses": {
                        "type": "array",
                        "description": "课程列表",
                        "items": {
                            "type": "object",
                            "properties": {
                                "name": {"type": "string", "description": "课程名"},
                                "day": {"type": "integer", "description": "星期几，1=周一 ... 7=周日"},
                                "periods": {
                                    "type": "array",
                                    "items": {"type": "integer"},
                                    "description": "[起始节, 结束节]，如第3-4节为 [3,4]",
                                },
                                "location": {"type": "string", "description": "教室，可空"},
                                "teacher": {"type": "string", "description": "老师，可空"},
                                "weeks": {
                                    "type": "array",
                                    "items": {"type": "integer"},
                                    "description": "[起始周, 结束周]，如 1-16 周为 [1,16]，缺省 [1,16]",
                                },
                            },
                            "required": ["name", "day", "periods"],
                            "additionalProperties": False,
                        },
                    },
                },
                "required": ["semester_start", "courses"],
                "additionalProperties": False,
            },
        ),
        ToolDefinition(
            name="list_calendar_events",
            description="读取服务器维护的日历事件，可按日期范围和关键词过滤。",
            input_schema={
                "type": "object",
                "properties": {
                    "days": {"type": "integer", "description": "从当前时间起查询多少天，默认 14"},
                    "query": {"type": "string", "description": "按标题、地点、备注过滤"},
                    "calendarName": {"type": "string", "description": "按日历名过滤"},
                },
                "additionalProperties": False,
            },
        ),
        ToolDefinition(
            name="create_calendar_event",
            description="创建服务器维护的日历事件。需要用户明确确认。不要用它导入或表示课程表。",
            input_schema={
                "type": "object",
                "properties": {
                    "title": {"type": "string"},
                    "startDate": {"type": "string", "description": "ISO8601 开始时间"},
                    "endDate": {"type": "string", "description": "ISO8601 结束时间，缺省为开始后一小时"},
                    "notes": {"type": "string"},
                    "location": {"type": "string"},
                    "calendarName": {"type": "string"},
                    "isAllDay": {"type": "boolean"},
                },
                "required": ["title", "startDate"],
                "additionalProperties": False,
            },
        ),
        ToolDefinition(
            name="update_calendar_event",
            description="按 ID 修改服务器维护的日历事件。需要用户明确确认。",
            input_schema={
                "type": "object",
                "properties": {
                    "id": {"type": "string"},
                    "title": {"type": "string"},
                    "startDate": {"type": "string"},
                    "endDate": {"type": "string"},
                    "notes": {"type": "string"},
                    "location": {"type": "string"},
                    "calendarName": {"type": "string"},
                    "isAllDay": {"type": "boolean"},
                },
                "required": ["id"],
                "additionalProperties": False,
            },
        ),
        ToolDefinition(
            name="delete_calendar_event",
            description="按 ID 删除服务器维护的日历事件。需要用户明确确认。",
            input_schema={
                "type": "object",
                "properties": {"id": {"type": "string"}},
                "required": ["id"],
                "additionalProperties": False,
            },
        ),
        ToolDefinition(
            name="list_scheduled_notifications",
            description="读取尚未发送、未取消的定时推送。",
            input_schema={"type": "object", "properties": {}, "additionalProperties": False},
        ),
        ToolDefinition(
            name="schedule_notification",
            description=(
                "创建一条定时推送通知。用户明确要求'提醒我'或'安排推送'时使用，需要用户确认后才执行。"
                "【重要时间规则】scheduled_at 必须是未来的时间。"
                "判断方法：把 scheduled_at 和当前基准时间做数值比较——scheduled_at > now 才是未来。"
                "例如：now=18:25, scheduled_at=18:27 → 18:27 > 18:25 → 是未来，应该执行；"
                "now=18:30, scheduled_at=18:27 → 18:27 < 18:30 → 才是过去，应拒绝并请用户重选时间。"
                "绝对不可以因为时间'快到了'就改为立即发送——用户要定时就定时，距离再近也要安排。"
            ),
            input_schema={
                "type": "object",
                "properties": {
                    "title": {"type": "string"},
                    "body": {"type": "string"},
                    "scheduled_at": {"type": "string", "description": "带时区偏移的 ISO-8601 时间，必须是未来时间"},
                    "reason": {"type": "string"},
                },
                "required": ["title", "body", "scheduled_at"],
                "additionalProperties": False,
            },
        ),
        ToolDefinition(
            name="cancel_scheduled_notification",
            description="取消一条尚未发送的定时推送，需要确认。",
            input_schema={
                "type": "object",
                "properties": {"id": {"type": "string"}},
                "required": ["id"],
                "additionalProperties": False,
            },
        ),
        ToolDefinition(
            name="send_push_notification",
            description=(
                "向用户手机发送推送通知。"
                "仅当以下情况使用：用户明确要求提醒、有重要截止日期、"
                "或需要在用户不看屏幕时告知重要信息。"
                "不要滥用——只在真正需要打扰用户时调用。"
                "每次调用发送一条通知。"
            ),
            input_schema={
                "type": "object",
                "properties": {
                    "title": {
                        "type": "string",
                        "description": "通知标题，简短（15字以内）",
                    },
                    "body": {
                        "type": "string",
                        "description": "通知正文，具体说明事项（50字以内）",
                    },
                    "urgency": {
                        "type": "string",
                        "enum": ["low", "normal", "high"],
                        "description": "high=截止/紧急，normal=一般提醒，low=仅供参考",
                    },
                },
                "required": ["title", "body"],
                "additionalProperties": False,
            },
        ),
        ToolDefinition(
            name="get_memory_insights",
            description="查询学习通 Memory，返回最近重要的通知和事项。用户问到学习通消息、最近通知、重要事项时调用。",
            input_schema={
                "type": "object",
                "properties": {
                    "limit": {"type": "integer", "description": "返回条数，默认 10"},
                    "importance": {"type": "string", "enum": ["high", "medium", "all"], "description": "重要度过滤"},
                },
                "additionalProperties": False,
            },
        ),
        ToolDefinition(
            name="get_system_status",
            description="查看系统运行状态：CPU、内存、磁盘使用率，钉钉连接状态，学习通登录状态，standby agent 最近决策，待发通知数，内存条目数，系统运行时间。",
            input_schema={"type": "object", "properties": {}, "additionalProperties": False},
        ),
        ToolDefinition(
            name="save_memory",
            description="保存用户偏好、习惯或上下文信息到长期记忆。当用户说'记住XXX'、'我喜欢XXX'、'我习惯XXX'时调用。",
            input_schema={
                "type": "object",
                "properties": {
                    "key": {"type": "string", "description": "记忆键名，如 wake_up_time、preferred_remind_advance"},
                    "value": {"type": "string", "description": "记忆值"},
                    "category": {"type": "string", "enum": ["preference", "habit", "context"], "description": "分类：偏好/习惯/上下文"},
                },
                "required": ["key", "value"],
                "additionalProperties": False,
            },
        ),
        ToolDefinition(
            name="delete_memory",
            description="删除一条用户记忆。当用户说'忘记XXX'、'删除偏好'时调用。",
            input_schema={
                "type": "object",
                "properties": {
                    "key": {"type": "string", "description": "要删除的记忆键名"},
                },
                "required": ["key"],
                "additionalProperties": False,
            },
        ),
        ToolDefinition(
            name="list_memories",
            description="列出所有用户记忆（偏好、习惯等）。",
            input_schema={"type": "object", "properties": {}, "additionalProperties": False},
        ),
        ToolDefinition(
            name="trigger_memory_scan",
            description="立刻触发一次学习通消息扫描（异步，不等结果）。用户说'立刻检查学习通'或'帮我扫一下'时调用。",
            input_schema={"type": "object", "properties": {}, "additionalProperties": False},
        ),
        ToolDefinition(
            name="set_push_config",
            description="设置推送静默时段或调整 standby 间隔。",
            input_schema={
                "type": "object",
                "properties": {
                    "quiet_until": {"type": "string", "description": "ISO-8601 datetime，到这个时间之前不推送"},
                    "standby_interval_minutes": {"type": "integer", "description": "standby agent 检查间隔（分钟），最小 5"},
                },
                "additionalProperties": False,
            },
        ),
    ]


async def _execute_schedule_tool(
    tc,
    chaoxing_svc,
    db_path: str,
    user_message: str,
    provider: dict = None,
    model: str | None = None,
    api_key: str | None = None,
    conversation_id: str = "default",
) -> str:
    if tc.name == "get_schedule_context":
        return await _get_schedule_context(chaoxing_svc, db_path)
    elif tc.name in ("read_message_memory", "get_chaoxing_memory"):
        importance = tc.arguments.get("importance_filter", "high_and_medium")
        return await _get_chaoxing_memory(db_path, importance)
    elif tc.name in ("refresh_message_memory", "refresh_chaoxing_memory"):
        if not provider or not model or not api_key:
            return "错误: 缺少模型配置，无法刷新学习通 memory。"
        from app.chaoxing.memory_provider import run_chaoxing_memory_sync

        result = await run_chaoxing_memory_sync(
            chaoxing_svc, db_path, provider, model, api_key,
        )
        return json.dumps(result, ensure_ascii=False)
    elif tc.name in ("get_chaoxing_assignments", "read_chaoxing_assignments"):
        return await _get_assignments(chaoxing_svc)
    elif tc.name == "get_chaoxing_messages":
        max_conversations = max(1, min(int(tc.arguments.get("max_conversations") or 6), 12))
        per_conversation = max(1, min(int(tc.arguments.get("per_conversation") or 10), 30))
        messages = await chaoxing_svc.fetch_recent_messages(max_conversations=max_conversations, per_conversation=per_conversation)
        return json.dumps(messages, ensure_ascii=False)
    elif tc.name == "read_dingtalk_messages":
        bucket = tc.arguments.get("bucket", "all")
        if bucket not in ("all", "notify", "interest"):
            bucket = "all"
        limit = max(1, min(int(tc.arguments.get("limit") or 20), 50))
        since = int(tc.arguments.get("since") or 0)
        async with aiosqlite.connect(db_path) as _dtdb:
            _dtdb.row_factory = aiosqlite.Row
            if bucket == "all":
                _rows = await (await _dtdb.execute(
                    "SELECT mid, sender_name, conversation_title, text, verdict, category, created_at "
                    "FROM dingtalk_messages WHERE verdict IN ('notify','interest') AND created_at > ? "
                    "ORDER BY created_at DESC LIMIT ?", (since, limit)
                )).fetchall()
            else:
                _rows = await (await _dtdb.execute(
                    "SELECT mid, sender_name, conversation_title, text, verdict, category, created_at "
                    "FROM dingtalk_messages WHERE verdict=? AND created_at > ? "
                    "ORDER BY created_at DESC LIMIT ?", (bucket, since, limit)
                )).fetchall()
        import datetime as _dt
        _tz_sh = zoneinfo.ZoneInfo("Asia/Shanghai")
        result = []
        for r in _rows:
            try:
                ts = _dt.datetime.fromtimestamp(r["created_at"] / 1000, tz=_dt.timezone.utc).astimezone(_tz_sh).strftime("%m-%d %H:%M")
            except Exception:
                ts = str(r["created_at"])
            result.append({
                "time": ts,
                "sender": r["sender_name"] or "?",
                "conversation": r["conversation_title"] or "私聊",
                "text": r["text"] or "",
                "bucket": r["verdict"],
                "category": r["category"] or "",
            })
        return json.dumps(result, ensure_ascii=False, indent=2)
    elif tc.name == "delete_message_memory":
        memory_id = tc.arguments.get("id", "")
        if not memory_id:
            return "错误: 缺少 memory id。"
        import datetime as _dt
        now_iso = _dt.datetime.now(_dt.timezone.utc).isoformat()
        async with aiosqlite.connect(db_path) as db:
            cur = await db.execute(
                """UPDATE chaoxing_memory_entries
                   SET archived_at=COALESCE(archived_at, ?),
                       status='superseded',
                       updated_at=?
                   WHERE id=?""",
                (now_iso, now_iso, memory_id),
            )
            if cur.rowcount > 0:
                from app.services.knowledge import sync_item_fts

                await sync_item_fts(db, memory_id)
            await db.commit()
        if cur.rowcount > 0:
            from app.services.ladder import cancel_ladder_for_item

            await cancel_ladder_for_item(db_path, memory_id)
        return json.dumps({"ok": cur.rowcount > 0}, ensure_ascii=False)
    elif tc.name == "list_watches":
        async with aiosqlite.connect(db_path) as db:
            db.row_factory = aiosqlite.Row
            rows = await (await db.execute(
                """SELECT id, name, aliases, attrs, notes, updated_at
                   FROM entities
                   WHERE etype='watch' AND status='active'
                   ORDER BY updated_at DESC"""
            )).fetchall()
        return json.dumps({"ok": True, "watches": [dict(r) for r in rows]}, ensure_ascii=False)
    elif tc.name == "create_watch":
        confirmation = _require_confirmation(tc.name, user_message, tc.arguments)
        if confirmation:
            await _store_pending_mutation(db_path, tc.name, tc.arguments, conversation_id)
            return confirmation
        from app.services.knowledge import upsert_entity

        name = (tc.arguments.get("name") or "").strip()
        if not name:
            return "错误: 缺少关注项名称。"
        attrs = {
            "keywords": tc.arguments.get("keywords") or [name],
            "until": tc.arguments.get("until"),
            "note": tc.arguments.get("note") or "",
        }
        import datetime as _dt
        now_iso = _dt.datetime.now(_dt.timezone.utc).isoformat()
        async with aiosqlite.connect(db_path) as db:
            eid = await upsert_entity(
                db,
                etype="watch",
                name=name,
                aliases=[k for k in (tc.arguments.get("keywords") or []) if k and k != name],
                attrs=attrs,
                notes=tc.arguments.get("note") or "",
                now=now_iso,
            )
            await db.commit()
        return json.dumps({"ok": True, "id": eid, "name": name}, ensure_ascii=False)
    elif tc.name == "delete_watch":
        confirmation = _require_confirmation(tc.name, user_message, tc.arguments)
        if confirmation:
            await _store_pending_mutation(db_path, tc.name, tc.arguments, conversation_id)
            return confirmation
        import datetime as _dt
        from app.services.knowledge import sync_entity_fts

        now_iso = _dt.datetime.now(_dt.timezone.utc).isoformat()
        watch_id = tc.arguments.get("id")
        name = tc.arguments.get("name")
        async with aiosqlite.connect(db_path) as db:
            db.row_factory = aiosqlite.Row
            if watch_id:
                cur = await db.execute(
                    "UPDATE entities SET status='archived', updated_at=? WHERE id=? AND etype='watch'",
                    (now_iso, watch_id),
                )
                affected_id = watch_id
            elif name:
                row = await (await db.execute(
                    "SELECT id FROM entities WHERE etype='watch' AND status='active' AND name=? LIMIT 1",
                    (name,),
                )).fetchone()
                if not row:
                    return json.dumps({"ok": False, "message": "未找到关注项"}, ensure_ascii=False)
                affected_id = row["id"]
                cur = await db.execute(
                    "UPDATE entities SET status='archived', updated_at=? WHERE id=?",
                    (now_iso, affected_id),
                )
            else:
                return "错误: 缺少 id 或 name。"
            if cur.rowcount > 0:
                await sync_entity_fts(db, affected_id)
            await db.commit()
        return json.dumps({"ok": cur.rowcount > 0}, ensure_ascii=False)
    elif tc.name == "kb_search":
        query = (tc.arguments.get("query") or "").strip()
        limit = max(1, min(int(tc.arguments.get("limit") or 8), 20))
        if not query:
            return "错误: 缺少 query。"
        return await _kb_search(db_path, query, limit)
    elif tc.name == "list_agent_audit":
        limit = max(1, min(int(tc.arguments.get("limit") or 10), 50))
        async with aiosqlite.connect(db_path) as db:
            db.row_factory = aiosqlite.Row
            rows = await (await db.execute(
                """SELECT id, conversation_id, tool_name, sql_or_op, result_summary, created_at
                   FROM agent_audit_log
                   ORDER BY created_at DESC LIMIT ?""",
                (limit,),
            )).fetchall()
        return json.dumps([dict(r) for r in rows], ensure_ascii=False, indent=2)
    elif tc.name == "db_query":
        sql = (tc.arguments.get("sql") or "").strip()
        limit = max(1, min(int(tc.arguments.get("limit") or 20), 100))
        ok, reason = _validate_read_sql(sql)
        if not ok:
            return f"错误: {reason}"
        return await _db_query(db_path, sql, limit)
    elif tc.name == "db_execute":
        confirmation = _require_confirmation(tc.name, user_message, tc.arguments)
        if confirmation:
            await _store_pending_mutation(db_path, tc.name, tc.arguments, conversation_id)
            return confirmation
        sql = (tc.arguments.get("sql") or "").strip()
        params = tc.arguments.get("params") or []
        ok, reason = _validate_write_sql(sql)
        if not ok:
            return f"错误: {reason}"
        async with aiosqlite.connect(db_path) as db:
            cur = await db.execute(sql, tuple(params))
            await db.commit()
        result = json.dumps({"ok": True, "rows_affected": cur.rowcount}, ensure_ascii=False)
        return result
    elif tc.name == "list_reminders":
        from .schedule_store import list_reminders
        reminders = await list_reminders(db_path, include_completed=bool(tc.arguments.get("include_completed", False)))
        return json.dumps(reminders, ensure_ascii=False)
    elif tc.name == "create_reminder":
        confirmation = _require_confirmation(tc.name, user_message, tc.arguments)
        if confirmation:
            await _store_pending_mutation(db_path, tc.name, tc.arguments, conversation_id)
            return confirmation
        from .schedule_store import create_reminder
        reminder = await create_reminder(
            db_path,
            title=tc.arguments.get("title", ""),
            due_at=tc.arguments.get("dueDate"),
            notes=tc.arguments.get("notes"),
            list_name=tc.arguments.get("listName") or "默认",
        )
        return json.dumps(reminder, ensure_ascii=False)
    elif tc.name == "update_reminder":
        confirmation = _require_confirmation(tc.name, user_message, tc.arguments)
        if confirmation:
            await _store_pending_mutation(db_path, tc.name, tc.arguments, conversation_id)
            return confirmation
        from .schedule_store import update_reminder
        updates = {k: v for k, v in tc.arguments.items() if k != "id"}
        reminder = await update_reminder(db_path, tc.arguments.get("id", ""), **updates)
        return json.dumps(reminder or {"error": "not found"}, ensure_ascii=False)
    elif tc.name == "complete_reminder":
        confirmation = _require_confirmation(tc.name, user_message, tc.arguments)
        if confirmation:
            await _store_pending_mutation(db_path, tc.name, tc.arguments, conversation_id)
            return confirmation
        from .schedule_store import update_reminder
        reminder = await update_reminder(db_path, tc.arguments.get("id", ""), isCompleted=True)
        return json.dumps(reminder or {"error": "not found"}, ensure_ascii=False)
    elif tc.name == "delete_reminder":
        confirmation = _require_confirmation(tc.name, user_message, tc.arguments)
        if confirmation:
            await _store_pending_mutation(db_path, tc.name, tc.arguments, conversation_id)
            return confirmation
        from .schedule_store import delete_reminder
        return json.dumps({"ok": await delete_reminder(db_path, tc.arguments.get("id", ""))}, ensure_ascii=False)
    elif tc.name == "list_courses":
        from .schedule_store import list_courses
        courses = await list_courses(db_path, days=_days_arg(tc.arguments))
        return json.dumps(_filter_items(courses, tc.arguments.get("query")), ensure_ascii=False)
    elif tc.name == "import_timetable":
        confirmation = _require_confirmation(tc.name, user_message, tc.arguments)
        if confirmation:
            await _store_pending_mutation(db_path, tc.name, tc.arguments, conversation_id)
            return confirmation
        from .schedule_store import import_timetable
        result = await import_timetable(
            db_path,
            tc.arguments.get("semester_start", ""),
            tc.arguments.get("courses") or [],
        )
        return json.dumps(result, ensure_ascii=False)
    elif tc.name == "list_calendar_events":
        from .schedule_store import list_events
        events = await list_events(db_path, days=_days_arg(tc.arguments))
        calendar_name = (tc.arguments.get("calendarName") or "").strip().lower()
        if calendar_name:
            events = [e for e in events if (e.get("calendarName") or "").lower() == calendar_name]
        return json.dumps(_filter_items(events, tc.arguments.get("query")), ensure_ascii=False)
    elif tc.name == "create_calendar_event":
        confirmation = _require_confirmation(tc.name, user_message, tc.arguments)
        if confirmation:
            await _store_pending_mutation(db_path, tc.name, tc.arguments, conversation_id)
            return confirmation
        from .schedule_store import create_event
        start = tc.arguments.get("startDate")
        if not start:
            return "错误: 缺少 startDate。"
        end = tc.arguments.get("endDate") or _default_end_date(start)
        event = await create_event(
            db_path,
            title=tc.arguments.get("title", ""),
            start_at=start,
            end_at=end,
            notes=tc.arguments.get("notes"),
            location=tc.arguments.get("location"),
            calendar_name=tc.arguments.get("calendarName") or "Web 日程",
            is_all_day=bool(tc.arguments.get("isAllDay", False)),
        )
        return json.dumps(event, ensure_ascii=False)
    elif tc.name == "update_calendar_event":
        confirmation = _require_confirmation(tc.name, user_message, tc.arguments)
        if confirmation:
            await _store_pending_mutation(db_path, tc.name, tc.arguments, conversation_id)
            return confirmation
        from .schedule_store import update_event
        updates = {k: v for k, v in tc.arguments.items() if k != "id"}
        event = await update_event(db_path, tc.arguments.get("id", ""), **updates)
        return json.dumps(event or {"error": "not found"}, ensure_ascii=False)
    elif tc.name == "delete_calendar_event":
        confirmation = _require_confirmation(tc.name, user_message, tc.arguments)
        if confirmation:
            await _store_pending_mutation(db_path, tc.name, tc.arguments, conversation_id)
            return confirmation
        from .schedule_store import delete_event
        return json.dumps({"ok": await delete_event(db_path, tc.arguments.get("id", ""))}, ensure_ascii=False)
    elif tc.name == "list_scheduled_notifications":
        async with aiosqlite.connect(db_path) as db:
            db.row_factory = aiosqlite.Row
            rows = await (await db.execute("""
                SELECT id, title, body, scheduled_at, reason, source_type
                FROM scheduled_notifications
                WHERE sent_at IS NULL AND cancelled_at IS NULL
                ORDER BY scheduled_at ASC
                LIMIT 50
            """)).fetchall()
        return json.dumps([dict(r) for r in rows], ensure_ascii=False)
    elif tc.name == "schedule_notification":
        import uuid as _uuid
        import zoneinfo as _zi
        # Parse and normalize scheduled_at to UTC (SQLite does string comparison,
        # so all timestamps must be in the same format/timezone to compare correctly)
        scheduled_at_str = tc.arguments.get("scheduled_at", "")
        try:
            _sch = datetime.fromisoformat(scheduled_at_str)
            if _sch.tzinfo is None:
                _sch = _sch.replace(tzinfo=_zi.ZoneInfo("Asia/Shanghai"))
            _now = datetime.now(timezone.utc)
            if (_now - _sch).total_seconds() > 30:
                sch_local = _sch.astimezone(_zi.ZoneInfo("Asia/Shanghai"))
                now_local = _now.astimezone(_zi.ZoneInfo("Asia/Shanghai"))
                return json.dumps({
                    "error": "past_time",
                    "message": (
                        f"scheduled_at {sch_local.strftime('%H:%M')} 已过去"
                        f"（当前 {now_local.strftime('%H:%M')}）。"
                        "请告知用户并让他重选一个未来的时间，不要改为立即发送。"
                    ),
                }, ensure_ascii=False)
            # Normalize to UTC for consistent SQLite string comparison
            scheduled_at_str = _sch.astimezone(timezone.utc).isoformat()
        except Exception:
            pass  # If parsing fails, store as-is and scheduler will skip it
        notif_id = str(_uuid.uuid4())
        now_iso = datetime.now(timezone.utc).isoformat()
        async with aiosqlite.connect(db_path) as db:
            await db.execute("""
                INSERT INTO scheduled_notifications
                (id, title, body, scheduled_at, source_id, source_type, reason, created_at)
                VALUES (?,?,?,?,?,?,?,?)
            """, (
                notif_id,
                tc.arguments.get("title", ""),
                tc.arguments.get("body", ""),
                scheduled_at_str,
                notif_id,
                "user",
                tc.arguments.get("reason"),
                now_iso,
            ))
            await db.commit()
        result = {"ok": True, "id": notif_id}
        try:
            sch_local = _sch.astimezone(_zi.ZoneInfo("Asia/Shanghai"))
            result["scheduled_at_local"] = sch_local.strftime("%Y-%m-%d %H:%M CST")
            result["message"] = f"通知已安排在 {sch_local.strftime('%m月%d日 %H:%M')}"
        except Exception:
            pass
        return json.dumps(result, ensure_ascii=False)
    elif tc.name == "cancel_scheduled_notification":
        async with aiosqlite.connect(db_path) as db:
            cur = await db.execute(
                "UPDATE scheduled_notifications SET cancelled_at=? WHERE id=? AND sent_at IS NULL AND cancelled_at IS NULL",
                (datetime.now(timezone.utc).isoformat(), tc.arguments.get("id", "")),
            )
            await db.commit()
        return json.dumps({"ok": cur.rowcount > 0}, ensure_ascii=False)
    elif tc.name == "get_memory_insights":
        limit = int(tc.arguments.get("limit") or 10)
        importance = tc.arguments.get("importance", "all")
        async with aiosqlite.connect(db_path) as db:
            where = "" if importance == "all" else f"AND importance='{importance}'"
            rows = await (await db.execute(f"""
                SELECT title, summary, action_hint, importance, category,
                       content_time, expires_at
                FROM chaoxing_memory_entries
                WHERE archived_at IS NULL
                AND (expires_at IS NULL OR expires_at > datetime('now'))
                {where}
                ORDER BY CASE importance WHEN 'high' THEN 1 WHEN 'medium' THEN 2 ELSE 3 END,
                         COALESCE(content_time, updated_at, sent_at) DESC
                LIMIT ?
            """, (limit,))).fetchall()
        entries = [dict(zip(["title","summary","action_hint","importance","category","content_time","expires_at"], r)) for r in rows]
        if not entries:
            return json.dumps({"ok": True, "count": 0, "message": "暂无未过期的 Memory 条目。"})
        return json.dumps({"ok": True, "count": len(entries), "entries": entries}, ensure_ascii=False)
    elif tc.name == "get_system_status":
        # Server metrics (psutil)
        cpu_percent = ram_percent = disk_percent = uptime_hours = None
        try:
            import psutil
            cpu_percent = psutil.cpu_percent(interval=0.5)
            ram_percent = psutil.virtual_memory().percent
            disk_percent = psutil.disk_usage("/").percent
            uptime_hours = round((time.time() - psutil.boot_time()) / 3600, 1)
        except ImportError:
            pass

        # DingTalk WAL freshness
        dingtalk_status = {"status": "unknown"}
        try:
            from app.tasks.health_monitor import WAL_PATH, WAL_STALE_SECONDS
            import os as _os
            mtime = _os.path.getmtime(WAL_PATH)
            age_min = int((time.time() - mtime) / 60)
            dingtalk_status = {
                "status": "alive" if (time.time() - mtime) < WAL_STALE_SECONDS else "stale",
                "wal_age_minutes": age_min,
            }
        except (FileNotFoundError, Exception):
            dingtalk_status = {"status": "not_running"}

        # Chaoxing login
        chaoxing_logged_in = False
        if chaoxing_svc:
            chaoxing_logged_in = getattr(chaoxing_svc, "is_logged_in", False)

        async with aiosqlite.connect(db_path) as db:
            standby_rows = await (await db.execute(
                "SELECT ran_at, decision, push_title, input_tokens FROM standby_agent_log ORDER BY ran_at DESC LIMIT 3"
            )).fetchall()
            pending_notifs = (await (await db.execute(
                "SELECT COUNT(*) FROM scheduled_notifications WHERE sent_at IS NULL AND cancelled_at IS NULL"
            )).fetchone())[0]
            memory_count = (await (await db.execute(
                "SELECT COUNT(*) FROM chaoxing_memory_entries WHERE archived_at IS NULL"
            )).fetchone())[0]
            sub_count = (await (await db.execute("SELECT COUNT(*) FROM push_subscriptions")).fetchone())[0]
        return json.dumps({
            "ok": True,
            "cpu_percent": cpu_percent,
            "ram_percent": ram_percent,
            "disk_percent": disk_percent,
            "uptime_hours": uptime_hours,
            "dingtalk": dingtalk_status,
            "chaoxing": {"logged_in": chaoxing_logged_in},
            "push_subscribers": sub_count,
            "pending_notifications": pending_notifs,
            "active_memory_entries": memory_count,
            "recent_standby_decisions": [
                {"ran_at": r[0], "decision": r[1], "push_title": r[2], "tokens": r[3]}
                for r in standby_rows
            ],
        }, ensure_ascii=False)
    elif tc.name == "trigger_memory_scan":
        # Fire-and-forget an incremental (changed-only) message scan. (Previously
        # this wrongly called run_memory_sweep(db_path) — wrong fn + wrong arg type,
        # so it silently AttributeError'd and never scanned anything.)
        if not provider or not model or not api_key:
            return "错误: 缺少模型配置，无法触发学习通扫描。"
        import asyncio as _asyncio
        from app.chaoxing.memory_provider import run_chaoxing_memory_sync

        async def _bg_scan():
            try:
                await run_chaoxing_memory_sync(
                    chaoxing_svc, db_path, provider, model, api_key,
                )
            except Exception as e:
                print(f"[trigger_memory_scan] background scan failed: {e}", flush=True)

        _asyncio.create_task(_bg_scan())
        return json.dumps({"ok": True, "message": "已触发学习通增量扫描，结果将在约 1 分钟内更新。"})
    elif tc.name == "set_push_config":
        quiet_until = tc.arguments.get("quiet_until")
        interval = tc.arguments.get("standby_interval_minutes")
        async with aiosqlite.connect(db_path) as db:
            if quiet_until:
                await db.execute(
                    "INSERT OR REPLACE INTO settings (key, value) VALUES (?, ?)",
                    ("push_quiet_until", quiet_until),
                )
            if interval and int(interval) >= 5:
                await db.execute(
                    "INSERT OR REPLACE INTO settings (key, value) VALUES (?, ?)",
                    ("standby_interval_minutes", str(interval)),
                )
            await db.commit()
        parts = []
        if quiet_until:
            parts.append(f"已设置静默到 {quiet_until}")
        if interval:
            parts.append(f"standby 间隔改为 {interval} 分钟")
        return json.dumps({"ok": True, "message": "；".join(parts) or "配置已更新。"})
    elif tc.name == "save_memory":
        key = tc.arguments.get("key", "").strip()
        value = tc.arguments.get("value", "").strip()
        category = tc.arguments.get("category", "preference")
        if not key or not value:
            return "错误: key 和 value 不能为空"
        async with aiosqlite.connect(db_path) as db:
            await db.execute(
                "INSERT INTO user_memory (category, key, value, source, updated_at) VALUES (?, ?, ?, 'user_told', datetime('now')) ON CONFLICT(key) DO UPDATE SET value=excluded.value, category=excluded.category, source='user_told', updated_at=datetime('now')",
                (category, key, value),
            )
            await db.commit()
        return json.dumps({"ok": True, "message": f"已记住：{key} = {value}"}, ensure_ascii=False)
    elif tc.name == "delete_memory":
        key = tc.arguments.get("key", "").strip()
        if not key:
            return "错误: key 不能为空"
        async with aiosqlite.connect(db_path) as db:
            cursor = await db.execute("DELETE FROM user_memory WHERE key = ?", (key,))
            await db.commit()
            if cursor.rowcount == 0:
                return json.dumps({"ok": False, "message": f"未找到记忆：{key}"}, ensure_ascii=False)
        return json.dumps({"ok": True, "message": f"已删除记忆：{key}"}, ensure_ascii=False)
    elif tc.name == "list_memories":
        async with aiosqlite.connect(db_path) as db:
            db.row_factory = aiosqlite.Row
            rows = await (await db.execute("SELECT key, value, category, source, updated_at FROM user_memory ORDER BY updated_at DESC")).fetchall()
        if not rows:
            return "暂无用户记忆。"
        entries = [dict(r) for r in rows]
        return json.dumps({"ok": True, "memories": entries}, ensure_ascii=False)
    elif tc.name == "send_push_notification":
        from .push_service import send_push_to_all_subscribers
        import uuid as _uuid

        title   = tc.arguments.get("title", "").strip()
        body    = tc.arguments.get("body", "").strip()
        urgency = tc.arguments.get("urgency", "normal")

        if not title or not body:
            return "错误: title 和 body 不能为空"

        result = await send_push_to_all_subscribers(
            db_path,
            title=title,
            body=body,
            tag=f"agent-{_uuid.uuid4().hex[:8]}",
            data={"type": "agent_push", "urgency": urgency},
        )
        attempted = result.get("attempted", 0)
        if attempted == 0:
            return "推送未发出：没有已注册的订阅设备（用户未开启推送）"
        return f"推送已发送到 {attempted} 台设备：{title}"
    else:
        return f"错误: 未知工具 {tc.name}"


# Only genuinely destructive / bulk-overwrite actions warrant an explicit
# confirm round-trip. Everyday creates and updates are reversible and the agent
# already states what it's doing in natural language — gating those behind a
# second "确认吗?" made the assistant feel broken (user describes tasks → agent
# offers → user says "对的" → agent STILL asks to confirm). Those just run now.
_NEEDS_CONFIRMATION = {
    "create_reminder",
    "update_reminder",
    "delete_reminder",
    "create_watch",
    "delete_watch",
    "create_calendar_event",
    "update_calendar_event",
    "delete_calendar_event",
    "import_timetable",      # wipes + replaces the whole timetable
    "schedule_notification",
    "db_execute",
}


def _require_confirmation(tool_name: str, user_message: str, arguments: dict) -> str | None:
    if tool_name not in _NEEDS_CONFIRMATION:
        return None
    if is_confirmation_text(user_message):
        return None
    # The op is now QUEUED (界面会显示确认按钮). Tell the agent to keep queuing
    # any further requested mutations, then ask for confirmation ONCE — so a
    # "create 3 reminders" request collects all three before the buttons appear,
    # instead of the agent stopping after the first.
    return (
        "该操作已加入待确认队列（用户界面会显示「确认执行」按钮，无需用户打字）。"
        "如果用户还要求了其他操作，请继续调用对应工具把它们也加入队列；"
        "全部加入后，用一句简短中文说明将要执行哪些操作并提示用户点击确认，"
        "不要输出任何 JSON 或参数细节。"
    )


def is_confirmation_text(user_message: str) -> bool:
    lowered = (user_message or "").strip().lower()
    if not lowered:
        return False
    # Strong confirmation phrases — match anywhere in the message.
    strong = ("确认", "确定", "可以执行", "执行吧", "就这样", "没问题", "confirm")
    if any(w in lowered for w in strong):
        return True
    # Short affirmatives — only count when the message is essentially just that
    # word, so "你好" / "对了，删掉全部" don't accidentally read as a yes.
    compact = lowered.rstrip("。.!！～~、, ")
    short = {
        "对", "对的", "对啊", "好", "好的", "好啊", "是", "是的", "可以",
        "行", "行的", "嗯", "嗯嗯", "ok", "okay", "yes", "yep", "sure",
        "创建吧", "加吧", "就这样吧", "确认执行",
    }
    return compact in short


def _pending_key(conversation_id: str = "default") -> str:
    safe = re.sub(r"[^a-zA-Z0-9_.:-]", "_", conversation_id or "default")[:120]
    return f"schedule_pending_mutation:{safe}"


async def _store_pending_mutation(db_path: str, tool_name: str, arguments: dict, conversation_id: str = "default") -> None:
    """Append a mutation to the pending queue (a LIST).

    Stored as a list so a single "create 3 reminders" turn produces 3 pending
    items that one tap of 确认 executes together — the old single-slot store made
    each new mutation clobber the previous one, so batches were impossible.
    """
    items = await get_pending_mutations(db_path, conversation_id)
    items.append({"tool": tool_name, "arguments": arguments})
    await _set_setting(
        db_path, _pending_key(conversation_id),
        json.dumps(items, ensure_ascii=False),
    )


async def get_pending_mutations(db_path: str, conversation_id: str = "default") -> list[dict]:
    raw = await _get_setting(db_path, _pending_key(conversation_id))
    if not raw and conversation_id == "default":
        raw = await _get_setting(db_path, "schedule_pending_mutation")
    if not raw:
        return []
    try:
        parsed = json.loads(raw)
    except json.JSONDecodeError:
        return []
    if isinstance(parsed, dict):       # back-compat with the old single form
        return [parsed]
    return parsed if isinstance(parsed, list) else []


async def clear_pending_mutations(db_path: str, conversation_id: str = "default") -> None:
    await _set_setting(db_path, _pending_key(conversation_id), None)
    if conversation_id == "default":
        await _set_setting(db_path, "schedule_pending_mutation", None)


async def execute_pending_mutations(chaoxing_svc, db_path: str, conversation_id: str = "default") -> dict:
    """Run ALL queued pending mutations. Used by the confirm BUTTON (no text
    gate) and by the typed-confirmation path. Returns {ok, result}."""
    items = await get_pending_mutations(db_path, conversation_id)
    if not items:
        return {"ok": False, "result": "没有待确认的操作。"}

    from .agent_service import ToolCall

    texts: list[str] = []
    ok_any = False
    for it in items:
        tc = ToolCall(id="confirmed_pending", name=it.get("tool", ""),
                      arguments=it.get("arguments") or {})
        try:
            # user_message="确认执行" satisfies is_confirmation_text so the tool's
            # own _require_confirmation gate passes and it actually runs.
            result = await _execute_schedule_tool(
                tc, chaoxing_svc, db_path, "确认执行", None,
                conversation_id=conversation_id,
            )
        except Exception as e:
            texts.append(f"执行「{tc.name}」失败：{e}")
            continue
        if result.startswith("错误:") or result.startswith("需要用户确认"):
            texts.append(result)
        else:
            ok_any = True
            await _audit_schedule_tool(db_path, conversation_id, tc.name, tc.arguments, result)
            texts.append(_confirmed_result_text(tc.name, result))

    await clear_pending_mutations(db_path, conversation_id)
    return {"ok": ok_any, "result": "\n".join(texts) or "已完成。"}


async def execute_confirmed_pending_mutation(user_message: str, chaoxing_svc, db_path: str, conversation_id: str = "default") -> dict | None:
    """Typed-confirmation path (user types "确认"). Button path uses
    execute_pending_mutations directly via the /confirm endpoint."""
    if not is_confirmation_text(user_message):
        return None
    if not await get_pending_mutations(db_path, conversation_id):
        return None
    res = await execute_pending_mutations(chaoxing_svc, db_path, conversation_id)
    return {"text": res["result"], "result": res["result"]}


async def _audit_schedule_tool(db_path: str, conversation_id: str, tool_name: str, arguments: dict, result: str) -> None:
    import uuid

    async with aiosqlite.connect(db_path) as db:
        await db.execute(
            """INSERT INTO agent_audit_log
               (id, conversation_id, tool_name, sql_or_op, result_summary, created_at)
               VALUES (?,?,?,?,?,?)""",
            (
                f"audit_{uuid.uuid4().hex[:12]}",
                conversation_id or "default",
                tool_name,
                json.dumps(arguments or {}, ensure_ascii=False)[:2000],
                str(result or "")[:500],
                datetime.now(timezone.utc).isoformat(),
            ),
        )
        await db.commit()


async def _kb_search(db_path: str, query: str, limit: int) -> str:
    like = f"%{query}%"
    async with aiosqlite.connect(db_path) as db:
        db.row_factory = aiosqlite.Row
        try:
            rows = await (await db.execute(
                """SELECT f.doc_id, f.doc_type, snippet(kb_fts, 2, '[', ']', '...', 8) AS snippet
                   FROM kb_fts f
                   WHERE kb_fts MATCH ?
                   LIMIT ?""",
                (_fts_query_for_sql(query), limit),
            )).fetchall()
        except Exception:
            rows = []
        entities = await (await db.execute(
            """SELECT id, etype, name, notes, attrs
               FROM entities
               WHERE status='active' AND (name LIKE ? OR aliases LIKE ? OR notes LIKE ?)
               ORDER BY updated_at DESC LIMIT ?""",
            (like, like, like, limit),
        )).fetchall()
        facts = await (await db.execute(
            """SELECT id, entity_id, text, source, confidence
               FROM facts
               WHERE archived_at IS NULL AND text LIKE ?
               ORDER BY updated_at DESC LIMIT ?""",
            (like, limit),
        )).fetchall()
        items = await (await db.execute(
            """SELECT id, title, summary, action_hint, importance, kind, expires_at
               FROM chaoxing_memory_entries
               WHERE archived_at IS NULL
                 AND COALESCE(status, 'active')='active'
                 AND (title LIKE ? OR summary LIKE ? OR action_hint LIKE ?)
               ORDER BY updated_at DESC LIMIT ?""",
            (like, like, like, limit),
        )).fetchall()
    return json.dumps({
        "fts": [dict(r) for r in rows],
        "entities": [dict(r) for r in entities],
        "facts": [dict(r) for r in facts],
        "items": [dict(r) for r in items],
    }, ensure_ascii=False, indent=2)


async def _db_query(db_path: str, sql: str, limit: int) -> str:
    limited_sql = sql.rstrip().rstrip(";")
    if re.match(r"^\s*select\b", limited_sql, re.I) and not re.search(r"\blimit\b", limited_sql, re.I):
        limited_sql = f"{limited_sql} LIMIT {limit}"
    async with aiosqlite.connect(db_path) as db:
        db.row_factory = aiosqlite.Row
        rows = await (await db.execute(limited_sql)).fetchmany(limit)
    return json.dumps([dict(r) for r in rows], ensure_ascii=False, indent=2)


def _validate_read_sql(sql: str) -> tuple[bool, str]:
    clean = sql.strip()
    if not clean:
        return False, "SQL 为空"
    if _has_multiple_statements(clean):
        return False, "只允许单条 SQL"
    if not re.match(r"^(select|pragma)\b", clean, re.I):
        return False, "只允许 SELECT/PRAGMA"
    if re.search(r"\b(insert|update|delete|drop|alter|attach|detach|replace|create|vacuum)\b", clean, re.I):
        return False, "只读查询不能包含写操作"
    return True, ""


def _validate_write_sql(sql: str) -> tuple[bool, str]:
    clean = sql.strip()
    if not clean:
        return False, "SQL 为空"
    if _has_multiple_statements(clean):
        return False, "只允许单条 SQL"
    if not re.match(r"^(insert|update|delete)\b", clean, re.I):
        return False, "只允许 INSERT/UPDATE/DELETE"
    if re.search(r"\b(drop|alter|attach|detach|create|vacuum|pragma|reindex)\b", clean, re.I):
        return False, "不允许结构变更或附加数据库"
    allowed = (
        "server_reminders", "server_events", "server_courses",
        "scheduled_notifications", "chaoxing_memory_entries",
        "entities", "facts", "settings", "user_memory",
    )
    if not any(re.search(rf"\b{re.escape(table)}\b", clean, re.I) for table in allowed):
        return False, "写操作只能作用于允许的业务表"
    return True, ""


def _has_multiple_statements(sql: str) -> bool:
    stripped = sql.strip()
    if ";" not in stripped:
        return False
    return stripped.rstrip(";").count(";") > 0


def _fts_query_for_sql(text: str) -> str:
    words = []
    for token in (text or "").replace('"', " ").split():
        token = token.strip("，。！？、,.!?;:()[]{}<>")
        if len(token) >= 2:
            words.append(token[:20])
    return " OR ".join(words[:8]) or text


async def detect_and_store_pending_mutation(user_message: str, db_path: str) -> str | None:
    if is_confirmation_text(user_message):
        return None

    event_mutation = _parse_create_calendar_event(user_message)
    if event_mutation:
        await _store_pending_mutation(db_path, "create_calendar_event", event_mutation)
        return (
            f"即将创建日历事件：{event_mutation['title']}，"
            f"时间 {event_mutation['startDate']} - {event_mutation['endDate']}"
            f"{'，地点 ' + event_mutation['location'] if event_mutation.get('location') else ''}。确认执行吗？"
        )

    reminder_mutation = _parse_create_reminder(user_message)
    if reminder_mutation:
        await _store_pending_mutation(db_path, "create_reminder", reminder_mutation)
        return (
            f"即将创建提醒事项：{reminder_mutation['title']}"
            f"{'，截止 ' + reminder_mutation['dueDate'] if reminder_mutation.get('dueDate') else ''}。确认执行吗？"
        )

    item_id = _extract_uuid(user_message)
    if not item_id:
        return None

    if any(word in user_message for word in ("完成", "标记完成", "已完成", "做完")):
        await _store_pending_mutation(db_path, "complete_reminder", {"id": item_id})
        return f"即将把 ID {item_id} 这条提醒标记为已完成。确认执行吗？"

    if any(word in user_message for word in ("删除", "删掉", "移除")):
        if "事件" in user_message or "日历" in user_message:
            tool_name = "delete_calendar_event"
            label = "日历事件"
        else:
            tool_name = "delete_reminder"
            label = "提醒事项"
        await _store_pending_mutation(db_path, tool_name, {"id": item_id})
        return f"即将删除 ID {item_id} 这条{label}。确认执行吗？"

    return None


def _extract_uuid(text: str) -> str | None:
    match = re.search(
        r"[0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{12}",
        text,
    )
    return match.group(0) if match else None


def _parse_create_calendar_event(text: str) -> dict | None:
    if "创建" not in text or not any(word in text for word in ("日历", "事件", "会议", "安排")):
        return None

    title = _extract_title(text, ("日历事件", "事件", "会议"))
    if not title:
        return None

    date = _relative_date(text)
    times = _extract_time_range(text)
    if not date or not times:
        return None

    start_time, end_time = times
    location = _extract_location(text)
    return {
        "title": title,
        "startDate": f"{date}T{start_time}:00+08:00",
        "endDate": f"{date}T{end_time}:00+08:00",
        "location": location,
        "calendarName": "Web 日程",
    }


def _parse_create_reminder(text: str) -> dict | None:
    # Require an explicit creation intent — a bare mention of "提醒"/"提醒事项"
    # (e.g. complaints or questions like "我没看到你放在提醒事项里啊") must NOT
    # be treated as a request to create a reminder.
    create_phrases = (
        "创建提醒", "新建提醒", "添加提醒", "加提醒", "加个提醒", "加一条提醒",
        "记个提醒", "记一条提醒", "记一下提醒", "设提醒", "设个提醒", "设置提醒",
        "提醒我",
    )
    if not any(phrase in text for phrase in create_phrases):
        return None

    # Questions / negations are not creation requests.
    if any(neg in text for neg in ("没看到", "没有", "为什么", "怎么", "是不是", "没放")):
        return None
    if text.rstrip().endswith(("吗", "吗？", "吗?", "？", "?")):
        return None

    title = _extract_title(text, ("提醒我", "提醒事项", "提醒"))
    if not title:
        return None

    date = _relative_date(text)
    time_value = _extract_single_time(text)
    due_date = f"{date}T{time_value}:00+08:00" if date and time_value else None
    data = {"title": title}
    if due_date:
        data["dueDate"] = due_date
    return data


def _extract_title(text: str, labels: tuple[str, ...]) -> str | None:
    if "：" in text:
        tail = text.split("：", 1)[1]
    elif ":" in text:
        tail = text.split(":", 1)[1]
    else:
        tail = text
        for label in labels:
            tail = tail.replace(label, "")
        tail = tail.replace("创建", "")

    title = re.split(r"，|,|。|；|;", tail, maxsplit=1)[0].strip()
    title = re.sub(r"^(一个|一条|新的)?(日历事件|事件|会议|提醒事项|提醒)", "", title).strip()
    return title or None


def _relative_date(text: str) -> str | None:
    now = datetime.now(zoneinfo.ZoneInfo("Asia/Shanghai"))
    if "明天" in text:
        return (now + timedelta(days=1)).date().isoformat()
    if "后天" in text:
        return (now + timedelta(days=2)).date().isoformat()
    if "今天" in text or "今晚" in text:
        return now.date().isoformat()
    match = re.search(r"(20\d{2})[-/年](\d{1,2})[-/月](\d{1,2})", text)
    if match:
        y, m, d = match.groups()
        return f"{int(y):04d}-{int(m):02d}-{int(d):02d}"
    return None


def _extract_time_range(text: str) -> tuple[str, str] | None:
    match = re.search(r"(\d{1,2}:\d{2})\s*(?:到|-|~|至)\s*(\d{1,2}:\d{2})", text)
    if not match:
        return None
    return _normalize_time(match.group(1)), _normalize_time(match.group(2))


def _extract_single_time(text: str) -> str | None:
    match = re.search(r"(\d{1,2}:\d{2})", text)
    return _normalize_time(match.group(1)) if match else None


def _normalize_time(value: str) -> str:
    hour, minute = value.split(":", 1)
    return f"{int(hour):02d}:{int(minute):02d}"


def _extract_location(text: str) -> str | None:
    match = re.search(r"地点\s*[:：]?\s*([^，,。；;]+)", text)
    return match.group(1).strip() if match else None


def _confirmed_result_text(tool_name: str, result: str) -> str:
    action = {
        "create_reminder": "已创建提醒事项。",
        "update_reminder": "已更新提醒事项。",
        "complete_reminder": "已完成提醒事项。",
        "delete_reminder": "已删除提醒事项。",
        "create_watch": "已创建关注项。",
        "delete_watch": "已删除关注项。",
        "create_calendar_event": "已创建日历事件。",
        "update_calendar_event": "已更新日历事件。",
        "delete_calendar_event": "已删除日历事件。",
        "import_timetable": "已导入课程表。",
        "db_execute": "已执行数据库修正。",
    }.get(tool_name, "已执行操作。")
    return f"{action}\n{result}"


def _days_arg(arguments: dict) -> int:
    try:
        return max(1, min(int(arguments.get("days") or 14), 120))
    except (TypeError, ValueError):
        return 14


def _filter_items(items: list[dict], query: str | None) -> list[dict]:
    needle = (query or "").strip().lower()
    if not needle:
        return items
    keys = ("title", "location", "notes", "calendarName")
    return [
        item for item in items
        if any(needle in str(item.get(key) or "").lower() for key in keys)
    ]


def _default_end_date(start_date: str) -> str:
    try:
        start = datetime.fromisoformat(start_date.replace("Z", "+00:00"))
        return (start + timedelta(hours=1)).isoformat()
    except ValueError:
        return start_date


def _memory_item_active(item: dict, now: datetime) -> bool:
    expires_at = item.get("expires_at")
    if not expires_at:
        return True
    try:
        expires = datetime.fromisoformat(str(expires_at).replace("Z", "+00:00"))
    except ValueError:
        return True
    if expires.tzinfo is None:
        expires = expires.replace(tzinfo=timezone.utc)
    return expires >= now.astimezone(timezone.utc)


async def _get_schedule_context(chaoxing_svc, db_path: str) -> str:
    now = datetime.now(zoneinfo.ZoneInfo("Asia/Shanghai"))
    parts = [f"当前时间: {now.strftime('%Y-%m-%d %H:%M')} ({now.strftime('%A')})"]

    from .schedule_store import list_courses, list_events, list_reminders
    reminders = await list_reminders(db_path)
    events = await list_events(db_path, days=14)
    courses = await list_courses(db_path, days=14)

    if reminders:
        parts.append("\n## 服务器提醒事项:")
        for r in reminders[:12]:
            due = r.get("dueDate") or "无截止"
            parts.append(f"- {r.get('title')} | 清单: {r.get('listName')} | 截止: {due} | ID: {r.get('id')}")

    if events:
        parts.append("\n## 服务器日程:")
        for e in events[:12]:
            parts.append(f"- {e.get('title')} | {e.get('startDate')} - {e.get('endDate')} | {e.get('location') or ''}")

    if courses:
        parts.append("\n## 本地课程表:")
        for c in courses[:12]:
            parts.append(f"- {c.get('title')} | {c.get('startDate')} - {c.get('endDate')} | {c.get('location') or ''}")

    # Get assignments
    assignments = await chaoxing_svc.fetch_all_pending_assignments()
    if assignments:
        parts.append("\n## 待完成作业:")
        for a in assignments[:10]:
            parts.append(f"- {a.get('title', '未知')} | 课程: {a.get('courseName', '?')} | 截止: {a.get('dueDate', '?')}")

    # Get memory entries
    async with aiosqlite.connect(db_path) as db:
        rows = await (await db.execute("""
            SELECT title, summary, importance, action_hint, expires_at
            FROM chaoxing_memory_entries
            WHERE archived_at IS NULL AND importance IN ('high', 'medium')
            ORDER BY CASE importance WHEN 'high' THEN 1 ELSE 2 END, sent_at DESC
            LIMIT 10
        """)).fetchall()

    if rows:
        parts.append("\n## 重要消息记忆:")
        for r in rows:
            item = {"title": r[0], "summary": r[1], "action_hint": r[3], "expires_at": r[4]}
            if _memory_item_active(item, datetime.now(timezone.utc)):
                parts.append(f"- [{r[2]}] {r[0]}: {r[1]}")
                if r[3]:
                    parts.append(f"  行动: {r[3]}")

    return "\n".join(parts) if parts else "暂无日程信息。"


async def _get_chaoxing_memory(db_path: str, importance_filter: str) -> str:
    import aiosqlite

    conditions = ["archived_at IS NULL"]
    if importance_filter == "high":
        conditions.append("importance='high'")
    elif importance_filter == "medium":
        conditions.append("importance='medium'")
    elif importance_filter == "high_and_medium":
        conditions.append("importance IN ('high', 'medium')")

    where = " AND ".join(conditions)

    async with aiosqlite.connect(db_path) as db:
        rows = await (await db.execute(f"""
            SELECT id, title, summary, importance, action_hint, sent_at, expires_at
            FROM chaoxing_memory_entries
            WHERE {where}
            ORDER BY CASE importance WHEN 'high' THEN 1 WHEN 'medium' THEN 2 ELSE 3 END,
                     sent_at DESC
            LIMIT 20
        """)).fetchall()

    if not rows:
        return "记忆库为空。"

    now = datetime.now(timezone.utc)
    parts = []
    for r in rows:
        item = {"title": r[1], "summary": r[2], "action_hint": r[4], "expires_at": r[6]}
        if not _memory_item_active(item, now):
            continue
        parts.append(f"[{r[3]}] id={r[0]} {r[1]}: {r[2]}")
        if r[4]:
            parts.append(f"  行动: {r[4]}")

    return "\n".join(parts) if parts else "没有符合条件的记忆条目。"


async def _get_assignments(chaoxing_svc) -> str:
    assignments = await chaoxing_svc.fetch_all_pending_assignments()
    if not assignments:
        return "暂无待完成作业。"

    parts = []
    for a in assignments:
        parts.append(f"- {a.get('title', '未知')} | 课程: {a.get('courseName', '?')} | 截止: {a.get('dueDate', '?')}")
    return "\n".join(parts)


# Build structured schedule payload for frontend rendering
def build_schedule_payload(schedule_data: dict) -> dict:
    """Build a structured schedule payload for the frontend to render as rich cards."""
    return {
        "type": "schedule_payload",
        "courses": schedule_data.get("courses", []),
        "chaoxing_assignments": schedule_data.get("assignments", []),
        "chaoxing_messages": schedule_data.get("messages", []),
        "reminders": [],
        "actions": schedule_data.get("actions", []),
    }
