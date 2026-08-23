from __future__ import annotations
import asyncio
import json
from dataclasses import dataclass, field
from typing import Any, Optional, AsyncGenerator
import httpx


@dataclass
class AgentMsg:
    role: str  # "system" | "user" | "assistant" | "tool"
    content: str | None = None
    reasoning_content: str | None = None
    tool_calls: list["ToolCall"] | None = None
    tool_call_id: str | None = None
    tool_name: str | None = None


@dataclass
class ToolDefinition:
    name: str
    description: str
    input_schema: dict


@dataclass
class ToolCall:
    id: str
    name: str
    arguments: dict


@dataclass
class AgentResponse:
    text: Optional[str]
    reasoning_content: Optional[str]
    tool_calls: list[ToolCall]
    usage: Optional[Any]
    stop_reason: str  # "end_turn" | "tool_use" | "max_tokens"


_RETRYABLE_STATUS = {429, 500, 502, 503, 504}
_MAX_ATTEMPTS = 3
_RETRY_BASE_DELAY = 1.5  # seconds; exponential: 1.5, 3


async def agent_complete(
    messages: list[AgentMsg],
    tools: list[ToolDefinition],
    provider: dict,
    model: str,
    api_key: str,
    thinking_budget: int = 0,
    response_format: dict[str, Any] | None = None,
    max_tokens: int | None = None,
    thinking_enabled: bool | None = None,
    reasoning_effort: str = "high",
) -> AgentResponse:
    """Single LLM call with bounded retry on transient provider errors.

    Retries 429/5xx and network-level failures with exponential backoff.
    Honors Retry-After on 429 when present. Non-retryable 4xx (401/400/…)
    raise immediately.

    NOTE: the OpenAI path already retries internally for DeepSeek
    (post_json_with_retries); this outer loop covers every other provider
    without stacking (DeepSeek inner attempts=3, outer sees the raised error
    only after the inner loop is exhausted — acceptable worst case for a
    single-user app).
    """
    import asyncio as _asyncio

    api_type = provider.get("api_type", "openAI")
    base_url = provider.get("base_url", "https://api.openai.com")

    last_exc: Exception | None = None
    for attempt in range(_MAX_ATTEMPTS):
        try:
            if api_type == "anthropic":
                return await _anthropic_agent_complete(
                    messages, tools, model, api_key, base_url,
                    thinking_budget,
                )
            return await _openai_agent_complete(
                messages,
                tools,
                model,
                api_key,
                base_url,
                thinking_budget=thinking_budget,
                response_format=response_format,
                max_tokens=max_tokens,
                thinking_enabled=thinking_enabled,
                reasoning_effort=reasoning_effort,
            )
        except httpx.HTTPStatusError as e:
            status = e.response.status_code
            if status not in _RETRYABLE_STATUS or attempt == _MAX_ATTEMPTS - 1:
                raise
            delay = _RETRY_BASE_DELAY * (2 ** attempt)
            retry_after = e.response.headers.get("retry-after")
            if retry_after:
                try:
                    delay = max(delay, float(retry_after))
                except ValueError:
                    pass
            print(f"[AGENT] retryable {status} from provider, attempt {attempt + 1}/{_MAX_ATTEMPTS}, sleeping {delay:.1f}s", flush=True)
            last_exc = e
            await _asyncio.sleep(delay)
        except (httpx.TimeoutException, httpx.TransportError) as e:
            if attempt == _MAX_ATTEMPTS - 1:
                raise
            delay = _RETRY_BASE_DELAY * (2 ** attempt)
            print(f"[AGENT] network error ({type(e).__name__}), attempt {attempt + 1}/{_MAX_ATTEMPTS}, sleeping {delay:.1f}s", flush=True)
            last_exc = e
            await _asyncio.sleep(delay)

    raise last_exc  # unreachable; satisfies type checkers


async def _anthropic_agent_complete(messages, tools, model, api_key, base_url, thinking_budget) -> AgentResponse:
    from .api_service import get_http_client, UsageStats

    client = get_http_client()
    system_msg = next((m.content for m in messages if m.role == "system"), None)
    non_sys = [_anthropic_message(m) for m in messages if m.role != "system"]

    body: dict[str, Any] = {
        "model": model,
        "max_tokens": 8096,
        "messages": non_sys,
        "tools": [
            {"name": t.name, "description": t.description, "input_schema": t.input_schema}
            for t in tools
        ],
    }
    if system_msg:
        body["system"] = system_msg
    if thinking_budget > 0:
        body["thinking"] = {"type": "enabled", "budget_tokens": thinking_budget}

    headers = {"x-api-key": api_key, "anthropic-version": "2023-06-01", "Content-Type": "application/json"}
    resp = await client.post(f"{base_url}/v1/messages", headers=headers, json=body)
    resp.raise_for_status()
    data = resp.json()

    text = None
    tool_calls = []
    for block in data.get("content", []):
        if block.get("type") == "text":
            text = block["text"]
        elif block.get("type") == "tool_use":
            tool_calls.append(ToolCall(
                id=block["id"],
                name=block["name"],
                arguments=block.get("input", {}),
            ))

    u = data.get("usage", {})
    usage = UsageStats(input_tokens=u.get("input_tokens", 0), output_tokens=u.get("output_tokens", 0))

    return AgentResponse(
        text=text,
        reasoning_content=None,
        tool_calls=tool_calls,
        usage=usage,
        stop_reason=data.get("stop_reason", "end_turn"),
    )


def _anthropic_message(message: AgentMsg) -> dict[str, Any]:
    if message.role == "assistant" and message.tool_calls:
        content = []
        if message.content:
            content.append({"type": "text", "text": message.content})
        content.extend(
            {
                "type": "tool_use",
                "id": tc.id,
                "name": tc.name,
                "input": tc.arguments,
            }
            for tc in message.tool_calls
        )
        return {"role": "assistant", "content": content}

    if message.role == "tool":
        return {
            "role": "user",
            "content": [
                {
                    "type": "tool_result",
                    "tool_use_id": message.tool_call_id or "",
                    "content": message.content or "",
                }
            ],
        }

    return {"role": message.role, "content": message.content or ""}


async def _openai_agent_complete(
    messages,
    tools,
    model,
    api_key,
    base_url,
    thinking_budget: int = 0,
    response_format: dict[str, Any] | None = None,
    max_tokens: int | None = None,
    thinking_enabled: bool | None = None,
    reasoning_effort: str = "high",
) -> AgentResponse:
    from .api_service import (
        get_http_client,
        _chat_completion_url,
        _openai_auth_headers,
        _openai_bearer_auth_headers,
        _apply_deepseek_options,
        _is_deepseek_base,
        _parse_openai_usage,
        post_json_with_retries,
        resolve_deepseek_runtime_options,
    )

    client = get_http_client()
    is_mimo = "xiaomimimo.com" in base_url.lower()
    is_deepseek = _is_deepseek_base(base_url)
    print(f"[AGENT] _openai_agent_complete model={model} base_url={base_url} is_mimo={is_mimo} is_deepseek={is_deepseek} msgs={len(messages)} tools={len(tools)} key={'SET' if api_key else 'EMPTY'}", flush=True)

    oai_tools = [
        {
            "type": "function",
            "function": {
                "name": t.name,
                "description": t.description,
                "parameters": t.input_schema,
            }
        }
        for t in tools
    ]
    body = {
        "model": model,
        "messages": [_openai_message(m) for m in messages],
    }
    if response_format and not is_mimo:
        body["response_format"] = response_format
    if is_mimo:
        body["stream"] = False
        # 2048 is enough for tool calls + agent responses; 8192 was bloating latency
        body["max_completion_tokens"] = max_tokens or 2048
        body["chat_template_kwargs"] = {"enable_thinking": False}
    elif is_deepseek:
        body["stream"] = False
        body["max_tokens"] = max_tokens or 2048
        deepseek_options = await resolve_deepseek_runtime_options()
        configured_mode = deepseek_options["thinking"]
        deepseek_thinking = (
            thinking_enabled
            if thinking_enabled is not None
            else (thinking_budget > 0 or configured_mode in {"high", "max"})
        )
        effort = "max" if reasoning_effort == "max" or thinking_budget >= 8192 or configured_mode == "max" else "high"
        _apply_deepseek_options(
            body,
            model,
            base_url,
            thinking_enabled=bool(deepseek_thinking),
            reasoning_effort=effort,
            user_id=deepseek_options["user_id"],
        )
    elif max_tokens:
        body["max_tokens"] = max_tokens
    if oai_tools:
        body["tools"] = oai_tools
        body["tool_choice"] = "auto"
    headers = _openai_auth_headers(api_key, base_url)
    headers["Content-Type"] = "application/json"

    resp = await post_json_with_retries(
        client,
        _chat_completion_url(base_url),
        headers,
        body,
        # DeepSeek keeps its fast inner retry; every other provider relies on
        # the outer agent_complete loop (avoids 3x3=9 stacked attempts).
        retry_deepseek=is_deepseek,
        attempts=1 if not is_deepseek else 3,
    )
    print(f"[AGENT] LLM response status={resp.status_code}", flush=True)
    if resp.status_code == 401 and is_mimo and api_key:
        print(f"[AGENT] 401 mimo retry with bearer auth", flush=True)
        headers = _openai_bearer_auth_headers(api_key)
        headers["Content-Type"] = "application/json"
        resp = await client.post(_chat_completion_url(base_url), headers=headers, json=body)
        print(f"[AGENT] retry status={resp.status_code}", flush=True)
    if resp.status_code >= 400:
        print(f"[AGENT_ERROR] LLM {resp.status_code} from {base_url} body={resp.text[:800]}", flush=True)
    resp.raise_for_status()
    data = resp.json()

    choice = data["choices"][0]
    msg = choice["message"]
    text = msg.get("content")
    reasoning_content = msg.get("reasoning_content")
    tool_calls = []
    for tc in msg.get("tool_calls") or []:
        raw_args = tc["function"].get("arguments", {})
        if isinstance(raw_args, str):
            try:
                args = json.loads(raw_args) if raw_args.strip() else {}
            except json.JSONDecodeError:
                args = {}
        else:
            args = raw_args or {}
        tool_calls.append(ToolCall(id=tc["id"], name=tc["function"]["name"], arguments=args))

    usage = _parse_openai_usage(data.get("usage", {}))

    stop_reason = "tool_use" if tool_calls else "end_turn"
    return AgentResponse(
        text=text,
        reasoning_content=reasoning_content,
        tool_calls=tool_calls,
        usage=usage,
        stop_reason=stop_reason,
    )


def _openai_message(message: AgentMsg) -> dict[str, Any]:
    if message.role == "assistant":
        data: dict[str, Any] = {"role": "assistant", "content": message.content or ""}
        if message.reasoning_content:
            data["reasoning_content"] = message.reasoning_content
        if message.tool_calls:
            data["tool_calls"] = [
                {
                    "id": tc.id,
                    "type": "function",
                    "function": {
                        "name": tc.name,
                        "arguments": json.dumps(tc.arguments, ensure_ascii=False),
                    },
                }
                for tc in message.tool_calls
            ]
        return data

    if message.role == "tool":
        return {
            "role": "tool",
            "tool_call_id": message.tool_call_id or "",
            "content": message.content or "",
        }

    return {"role": message.role, "content": message.content or ""}


def merge_system_messages(messages: list[AgentMsg]) -> list[AgentMsg]:
    """FIX FOR BUG 1: Merge all system messages into one before any API call."""
    system_parts = [m.content for m in messages if m.role == "system" and m.content]
    non_system = [m for m in messages if m.role != "system"]
    if not system_parts:
        return non_system
    return [AgentMsg(role="system", content="\n\n".join(system_parts))] + non_system


def _trim_intra_turn_pairs(pairs: list[AgentMsg], max_pairs: int = 6) -> list[AgentMsg]:
    """FIX FOR BUG 2: Trim only intra-turn tool pairs, never conversation history."""
    max_msgs = max_pairs * 2
    return pairs[-max_msgs:] if len(pairs) > max_msgs else pairs


async def run_agentic_loop(
    initial_messages: list[AgentMsg],
    tools: list[ToolDefinition],
    tool_executor,
    provider: dict,
    model: str,
    api_key: str,
    max_iterations: int = 8,
    thinking_budget: int = 0,
    require_tool_call: bool = False,
    tool_retry_message: str | None = None,
) -> AsyncGenerator[dict, None]:
    """Full agentic loop with parallel tool execution."""
    history = merge_system_messages(initial_messages)
    intra_turn: list[AgentMsg] = []
    failure_summaries = []
    reached_final = False
    tool_used = False
    missing_tool_retry_done = False

    for _ in range(max_iterations):
        trimmed_intra = _trim_intra_turn_pairs(intra_turn)
        current_messages = history + trimmed_intra

        response = await agent_complete(current_messages, tools, provider, model, api_key, thinking_budget)

        if response.usage:
            provider_id = provider.get("id", "")
            usage_dict = _usage_to_dict(response.usage, model=model, provider=provider_id)
            try:
                from app.config import settings
                from app.services.budget import log_usage_later

                log_usage_later(settings.database_path, "agent_loop", provider_id, model, response.usage)
            except Exception:
                pass
            yield {"type": "usage", "usage": usage_dict}

        if not response.tool_calls:
            final_text = (response.text or "").strip()
            if require_tool_call and tools and not tool_used and not missing_tool_retry_done:
                missing_tool_retry_done = True
                intra_turn.append(AgentMsg(
                    role="user",
                    content=tool_retry_message or "你刚才没有调用工具。本轮必须先调用至少一个工具获取证据，再回答用户。",
                ))
                continue
            reached_final = True
            if failure_summaries and is_bare_completion(final_text):
                yield {"type": "text", "content": _partial_failure_summary(failure_summaries)}
                break
            if final_text:
                yield {"type": "text", "content": final_text}
            break

        tool_used = True
        yield {"type": "tool_start", "tools": [{"name": tc.name, "id": tc.id} for tc in response.tool_calls]}
        raw_results = await asyncio.gather(
            *[tool_executor(tc) for tc in response.tool_calls],
            return_exceptions=True,
        )
        results = [
            f"错误: {type(result).__name__}: {result}" if isinstance(result, Exception) else result
            for result in raw_results
        ]

        for tc, result in zip(response.tool_calls, results):
            yield {"type": "tool_result", "tool_name": tc.name, "result_preview": result[:200]}
            if result.startswith("错误:"):
                failure_summaries.append(f"{tc.name}: {result[:120]}")

        intra_turn.append(AgentMsg(
            role="assistant",
            content=response.text,
            reasoning_content=response.reasoning_content,
            tool_calls=response.tool_calls,
        ))
        for tc, result in zip(response.tool_calls, results):
            intra_turn.append(AgentMsg(
                role="tool",
                content=_truncate_tool_result(result),
                tool_call_id=tc.id,
                tool_name=tc.name,
            ))

    if not reached_final:
        if failure_summaries:
            yield {"type": "text", "content": _partial_failure_summary(failure_summaries)}
        else:
            yield {"type": "text", "content": "任务未完成：Agent 达到工具调用轮次上限，但没有生成最终回答。"}


def _truncate_tool_result(result: str, max_chars: int = 3000) -> str:
    if len(result) <= max_chars:
        return result
    return result[:max_chars] + f"\n…（内容已截断，共 {len(result)} 字符，仅传递前 {max_chars} 字符）"


def _partial_failure_summary(failures: list[str]) -> str:
    unique = list(dict.fromkeys(failures))[:4]
    lines = "\n".join(f"- {f}" for f in unique)
    return f"任务没有完全完成：有 {len(failures)} 个工具失败。\n{lines}"


def is_bare_completion(text: str) -> bool:
    normalized = text.strip().rstrip("。.!！ ").lower()
    return normalized in {"完成", "done", "ok", "好的", "已完成"}


def _usage_to_dict(u, model: str = "", provider: str = "") -> dict:
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


def filter_relevant_tools(tools: list[ToolDefinition], user_message: str, always_include: set[str] = frozenset()) -> list[ToolDefinition]:
    msg_lower = user_message.lower()
    relevant = [
        t for t in tools
        if t.name in always_include
        or any(kw in msg_lower for kw in _tool_keywords(t.name))
    ]
    return relevant if len(relevant) >= 2 else tools


def _tool_keywords(tool_name: str) -> list[str]:
    return {
        "fetch_url":               ["http", "url", "网页", "链接", "网站"],
        "search_web":              ["搜索", "查找", "找", "search"],
        "read_pdf":                ["pdf", "文件", "文档"],
        "get_current_time":        ["今天", "明天", "后天", "本周", "下周", "时间", "日期"],
        "get_data_schema":         ["schema", "表结构", "字段", "有哪些表", "数据库结构"],
        "search_records":          ["课", "作业", "日程", "提醒", "通知", "ddl", "deadline",
                                    "课程", "考试", "安排", "学习通", "钉钉"],
        "search_database":         ["数据库", "sql", "表", "记录", "查询", "统计"],
        "get_record_detail":       ["详情", "原文", "完整", "展开"],
        "send_push_notification":  ["提醒", "通知", "推送", "notify", "remind",
                                    "截止", "deadline", "别忘了", "记得"],
    }.get(tool_name, [tool_name])
