from __future__ import annotations

import json
import re
from typing import Any

from app.database import db_conn
from app.services.agent_service import AgentMsg, ToolDefinition, agent_complete
from app.services.provider_registry import resolve_provider

CORE_TOOLS = {"get_current_time", "get_data_schema", "search_records", "search_database", "get_record_detail"}
READ_FALLBACK = {
    "list_reminders", "list_calendar_events", "list_courses",
    "read_message_memory", "get_chaoxing_assignments", "kb_search",
}
WRITE_HINT_RE = re.compile(r"(提醒我|创建|新建|添加|删除|删掉|完成|改成|更新|取消|安排|推送|记住|保存|导入)", re.I)


async def resolve_light_agent_provider(default_provider: dict, default_model: str, default_api_key: str):
    async with db_conn() as db:
        row_provider = await (await db.execute(
            "SELECT value FROM settings WHERE key='light_agent_provider_id'"
        )).fetchone()
        row_model = await (await db.execute(
            "SELECT value FROM settings WHERE key='light_agent_model'"
        )).fetchone()
    provider_id = row_provider["value"] if row_provider and row_provider["value"] else ""
    model = row_model["value"] if row_model and row_model["value"] else ""
    if provider_id:
        provider, api_key = await resolve_provider(provider_id)
        chosen_model = model or (provider.get("models") or [default_model])[0]
        return provider, chosen_model, api_key or default_api_key
    return default_provider, model or default_model, default_api_key


async def select_tools_for_query(
    user_message: str,
    history: list[dict],
    tools: list[ToolDefinition],
    provider: dict,
    model: str,
    api_key: str,
) -> tuple[list[str], dict[str, Any] | None]:
    available = [{"name": t.name, "description": _compact(t.description)} for t in tools]
    system = (
        "你是工具路由器，只选择工具，不回答用户问题。"
        "从给定工具列表中选出本轮主 agent 需要的工具名。"
        "优先少选；复杂/跨表/调查类必须包含 search_database。"
        "写操作只有用户明确要求创建、修改、删除、提醒、推送、保存时才选择。"
        "输出严格 JSON：{\"tools\":[...],\"confidence\":0-1,\"reason\":\"简短原因\"}。"
    )
    recent = [
        {"role": m.get("role"), "content": (m.get("content") or "")[-500:]}
        for m in (history or [])[-6:]
    ]
    user = json.dumps({
        "query": user_message,
        "recent_history": recent,
        "available_tools": available,
    }, ensure_ascii=False)
    try:
        light_provider, light_model, light_key = await resolve_light_agent_provider(provider, model, api_key)
        response = await agent_complete(
            [AgentMsg(role="system", content=system), AgentMsg(role="user", content=user)],
            [], light_provider, light_model, light_key,
        )
        parsed = _parse_router_json(response.text or "")
        selected = _sanitize_tool_names(parsed.get("tools") or [], {t.name for t in tools})
        usage = None
        if response.usage:
            try:
                from app.config import settings
                from app.services.budget import log_usage

                await log_usage(settings.database_path, "tool_router", light_provider.get("id", ""), light_model, response.usage)
            except Exception:
                pass
            usage = {
                "input_tokens": response.usage.input_tokens,
                "output_tokens": response.usage.output_tokens,
                "cache_hit_tokens": response.usage.cache_hit_tokens,
                "cache_miss_tokens": response.usage.cache_miss_tokens,
                "reasoning_tokens": response.usage.reasoning_tokens,
                "model": light_model,
                "provider": light_provider.get("id", ""),
                "phase": "tool_router",
            }
        if not selected or float(parsed.get("confidence") or 0) < 0.35:
            selected = _fallback_tool_names(user_message, tools)
        return selected, usage
    except Exception as exc:
        return _fallback_tool_names(user_message, tools), {"phase": "tool_router", "error": str(exc)[:200]}


def _fallback_tool_names(user_message: str, tools: list[ToolDefinition]) -> list[str]:
    names = {t.name for t in tools}
    selected = set(CORE_TOOLS) | (READ_FALLBACK & names)
    if WRITE_HINT_RE.search(user_message or ""):
        selected |= {n for n in names if n.startswith(("create_", "update_", "delete_", "complete_", "schedule_", "cancel_", "save_", "send_", "import_", "set_"))}
    return [t.name for t in tools if t.name in selected]


def _sanitize_tool_names(values: list[Any], available: set[str]) -> list[str]:
    out = []
    for value in values:
        name = str(value).strip()
        if name in available and name not in out:
            out.append(name)
    for core in CORE_TOOLS:
        if core in available and core not in out:
            out.append(core)
    return out


def _parse_router_json(text: str) -> dict[str, Any]:
    start = text.find("{")
    end = text.rfind("}")
    if start >= 0 and end > start:
        return json.loads(text[start:end + 1])
    return json.loads(text)


def _compact(text: str) -> str:
    return re.sub(r"\s+", " ", text or "").strip()[:220]
