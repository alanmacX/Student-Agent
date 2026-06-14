from __future__ import annotations

from fastapi import APIRouter, Request
from fastapi.responses import StreamingResponse
import json
import asyncio
import uuid
import ipaddress
import socket
from datetime import datetime, timezone
from urllib.parse import urljoin, urlparse
from app.database import db_conn
from app.services.api_service import make_service
from app.services.agent_service import AgentMsg, ToolDefinition, run_agentic_loop, filter_relevant_tools
from app.services.provider_registry import resolve_provider
from app.services.time_context import inject_time
from app.config import settings

router = APIRouter(prefix="/api/conversations", tags=["chat"])

# Cap how much conversation history is replayed to the LLM each turn. Sending the
# full transcript grows input tokens (and latency) without bound on long chats;
# the most recent turns carry virtually all the useful context.
MAX_HISTORY_MESSAGES = 24


def _cap_history(rows: list) -> list:
    """Keep only the most recent MAX_HISTORY_MESSAGES messages."""
    if len(rows) <= MAX_HISTORY_MESSAGES:
        return rows
    return rows[-MAX_HISTORY_MESSAGES:]


# Chat tools definition
CHAT_TOOLS = [
    ToolDefinition(
        name="fetch_url",
        description="Fetch and read content from a URL. Returns the text content of the page.",
        input_schema={
            "type": "object",
            "properties": {
                "url": {"type": "string", "description": "The URL to fetch"},
            },
            "required": ["url"],
            "additionalProperties": False,
        },
    ),
    ToolDefinition(
        name="search_web",
        description="Search the web using DuckDuckGo. Returns search result snippets.",
        input_schema={
            "type": "object",
            "properties": {
                "query": {"type": "string", "description": "Search query"},
            },
            "required": ["query"],
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
]


async def _execute_chat_tool(tc, db_path: str) -> str:
    """Execute a chat tool call."""
    from app.services.api_service import get_http_client

    client = get_http_client()

    if tc.name == "fetch_url":
        url = tc.arguments.get("url", "")
        if not url:
            return "错误: 缺少 URL"
        try:
            current_url = url
            for _ in range(5):
                allowed, reason = await _validate_public_http_url(current_url)
                if not allowed:
                    return f"错误: {reason}"
                resp = await client.get(current_url, follow_redirects=False, timeout=15.0)
                if resp.status_code not in (301, 302, 303, 307, 308):
                    break
                location = resp.headers.get("location")
                if not location:
                    break
                current_url = urljoin(current_url, location)
            else:
                return "错误: 重定向次数过多"
            text = resp.text[:8000]  # Match agent pipeline truncation limit
            return text
        except Exception as e:
            return f"错误: {str(e)}"

    elif tc.name == "search_web":
        query = tc.arguments.get("query", "")
        if not query:
            return "错误: 缺少搜索词"
        try:
            resp = await client.get(
                "https://html.duckduckgo.com/html/",
                params={"q": query},
                headers={"User-Agent": "Mozilla/5.0"},
                follow_redirects=True,
                timeout=10.0,
            )
            # Simple HTML parsing for results
            text = resp.text
            results = []
            import re
            for match in re.finditer(r'class="result__snippet"[^>]*>(.*?)</a>', text, re.DOTALL):
                snippet = re.sub(r'<[^>]+>', '', match.group(1)).strip()
                if snippet:
                    results.append(snippet)
            return "\n".join(results[:5]) if results else "没有找到结果"
        except Exception as e:
            return f"错误: {str(e)}"

    elif tc.name == "send_push_notification":
        from app.services.push_service import send_push_to_all_subscribers

        title   = tc.arguments.get("title", "").strip()
        body    = tc.arguments.get("body", "").strip()
        urgency = tc.arguments.get("urgency", "normal")

        if not title or not body:
            return "错误: title 和 body 不能为空"

        result = await send_push_to_all_subscribers(
            settings.database_path,
            title=title,
            body=body,
            tag=f"agent-{uuid.uuid4().hex[:8]}",
            data={"type": "agent_push", "urgency": urgency},
        )
        attempted = result.get("attempted", 0)
        if attempted == 0:
            return "推送未发出：没有已注册的订阅设备（用户未开启推送）"
        return f"推送已发送到 {attempted} 台设备：{title}"

    return f"错误: 未知工具 {tc.name}"


async def _validate_public_http_url(url: str) -> tuple[bool, str]:
    parsed = urlparse(url)
    if parsed.scheme not in {"http", "https"}:
        return False, "只允许 http/https URL"
    if not parsed.hostname:
        return False, "URL 缺少 host"
    port = parsed.port or (443 if parsed.scheme == "https" else 80)
    if port not in (80, 443):
        return False, "只允许访问 80/443 端口"
    try:
        infos = await asyncio.to_thread(socket.getaddrinfo, parsed.hostname, port, type=socket.SOCK_STREAM)
    except socket.gaierror:
        return False, "无法解析 URL host"
    for info in infos:
        ip = ipaddress.ip_address(info[4][0])
        if _is_blocked_ip(ip):
            return False, "不允许访问私有、回环或链路本地地址"
    return True, ""


def _is_blocked_ip(ip: ipaddress._BaseAddress) -> bool:
    return (
        ip.is_private
        or ip.is_loopback
        or ip.is_link_local
        or ip.is_multicast
        or ip.is_reserved
        or ip.is_unspecified
    )


@router.post("/{conv_id}/chat")
async def stream_chat(conv_id: str, request: Request):
    body = await request.json()
    user_message = body.get("message", "").strip()
    if not user_message:
        return {"error": "empty message"}

    async with db_conn() as db:
        # Load conversation
        conv = await (await db.execute(
            "SELECT * FROM conversations WHERE id=?", (conv_id,)
        )).fetchone()
        if not conv:
            return {"error": "conversation not found"}

        # Get message position
        pos_row = await (await db.execute(
            "SELECT MAX(position) FROM messages WHERE conversation_id=?", (conv_id,)
        )).fetchone()
        next_pos = (pos_row[0] or 0) + 1

        # Save user message
        now = datetime.now(timezone.utc).isoformat()
        user_msg_id = str(uuid.uuid4())
        await db.execute(
            "INSERT INTO messages (id, conversation_id, role, content, timestamp, position) VALUES (?,?,?,?,?,?)",
            (user_msg_id, conv_id, "user", user_message, now, next_pos),
        )
        await db.commit()
        next_pos += 1

        provider_id = dict(conv)["provider_id"]
        model = dict(conv)["model"]
        agent_mode = dict(conv)["agent_mode"]
        system_prompt = dict(conv)["system_prompt"] or ""

    provider, api_key = await resolve_provider(provider_id)

    # Build message history
    async with db_conn() as db:
        history_rows = await (await db.execute(
            "SELECT role, content FROM messages WHERE conversation_id=? ORDER BY position",
            (conv_id,),
        )).fetchall()
    history_rows = _cap_history(history_rows)

    # Inject current time into every system prompt regardless of conversation type
    stamped_system = inject_time(system_prompt)

    messages_for_api = []
    messages_for_api.append({"role": "system", "content": stamped_system})
    for r in history_rows:
        messages_for_api.append({"role": dict(r)["role"], "content": dict(r)["content"]})

    api_type = provider.get("api_type", "openAI")
    stream_fn = make_service(api_type)

    async def generate():
        nonlocal next_pos
        full_response = ""
        usage_data = None

        try:
            # Check if we should use agent mode with tools
            if agent_mode in ("subAgent",) and api_key:
                # Use agentic loop with tools
                agent_msgs = [AgentMsg(role="system", content=stamped_system)]
                for r in history_rows:
                    d = dict(r)
                    agent_msgs.append(AgentMsg(role=d["role"], content=d["content"]))

                relevant_tools = filter_relevant_tools(CHAT_TOOLS, user_message)

                async def tool_executor(tc):
                    return await _execute_chat_tool(tc, settings.database_path)

                async for event in run_agentic_loop(
                    agent_msgs, relevant_tools, tool_executor, provider, model, api_key
                ):
                    if event.get("type") == "text":
                        full_response += event["content"]
                    yield f"data: {json.dumps(event)}\n\n"
            else:
                # Direct streaming
                async for event in stream_fn(messages_for_api, model, api_key, provider.get("base_url", "")):
                    if event.type == "text":
                        full_response += event.content
                        yield f"data: {json.dumps({'type': 'text', 'content': event.content})}\n\n"
                    elif event.type == "reasoning":
                        yield f"data: {json.dumps({'type': 'reasoning', 'content': event.content})}\n\n"
                    elif event.type == "usage":
                        usage_data = event.usage
                        yield f"data: {json.dumps({'type': 'usage', 'usage': _usage_to_dict(event.usage, model=model, provider=provider_id)})}\n\n"

            # Save assistant message
            assistant_msg_id = str(uuid.uuid4())
            usage_json = json.dumps(_usage_to_dict(usage_data, model=model, provider=provider_id)) if usage_data else None
            async with db_conn() as db:
                await db.execute(
                    "INSERT INTO messages (id, conversation_id, role, content, usage_json, timestamp, position) VALUES (?,?,?,?,?,?,?)",
                    (assistant_msg_id, conv_id, "assistant", full_response, usage_json, datetime.now(timezone.utc).isoformat(), next_pos),
                )
                await db.execute(
                    "UPDATE conversations SET updated_at=? WHERE id=?",
                    (datetime.now(timezone.utc).isoformat(), conv_id),
                )
                await db.commit()

            yield f"data: {json.dumps({'type': 'done'})}\n\n"

        except asyncio.CancelledError:
            yield f"data: {json.dumps({'type': 'cancelled'})}\n\n"
        except Exception as e:
            yield f"data: {json.dumps({'type': 'error', 'message': str(e)})}\n\n"

    return StreamingResponse(
        generate(),
        media_type="text/event-stream",
        headers={
            "Cache-Control": "no-cache",
            "X-Accel-Buffering": "no",
            "Connection": "keep-alive",
        },
    )


def _usage_to_dict(u, model: str = "", provider: str = "") -> dict:
    if not u:
        return {}
    d = {
        "input_tokens": u.input_tokens,
        "output_tokens": u.output_tokens,
        "cache_hit_tokens": u.cache_hit_tokens,
        "cache_miss_tokens": u.cache_miss_tokens,
        "reasoning_tokens": u.reasoning_tokens,
    }
    if model:
        d["model"] = model
    if provider:
        d["provider"] = provider
    return d
