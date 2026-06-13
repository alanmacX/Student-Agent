from __future__ import annotations
from dataclasses import dataclass, field
from typing import AsyncGenerator, Optional
import httpx
import json

@dataclass
class UsageStats:
    input_tokens: int = 0
    output_tokens: int = 0
    cache_hit_tokens: int = 0
    cache_miss_tokens: int = 0
    reasoning_tokens: int = 0
    estimated_cost_usd: Optional[float] = None

@dataclass
class StreamEvent:
    type: str  # "text" | "reasoning" | "usage"
    content: str = ""
    usage: Optional[UsageStats] = None

_http_client: Optional[httpx.AsyncClient] = None


def get_http_client() -> httpx.AsyncClient:
    return _http_client


async def init_http_client():
    global _http_client
    _http_client = httpx.AsyncClient(
        timeout=httpx.Timeout(120.0, connect=30.0),
        limits=httpx.Limits(max_connections=20, max_keepalive_connections=10),
    )


async def close_http_client():
    if _http_client:
        await _http_client.aclose()


KNOWN_PRICING: dict[str, tuple[float, float]] = {
    "gpt-4o-mini": (0.15, 0.60),
    "gpt-4o": (2.50, 10.00),
    "gpt-4.1": (2.00, 8.00),
    "gpt-4.1-mini": (0.40, 1.60),
    "gpt-4.1-nano": (0.10, 0.40),
    "o3-mini": (1.10, 4.40),
    "claude-haiku-3-5": (0.80, 4.00),
    "claude-sonnet-4-6": (3.00, 15.00),
    "claude-opus-4-7": (15.00, 75.00),
    "gemini-2.0-flash": (0.10, 0.40),
    "gemini-2.5-pro": (1.25, 10.00),
    "gemini-2.5-flash": (0.15, 0.60),
    "deepseek-chat": (0.27, 1.10),
    "deepseek-reasoner": (0.55, 2.19),
    "deepseek-v4-flash": (0.14, 0.28),
    "deepseek-v4-pro": (0.435, 0.87),
    "mimo-v2-pro": (0.50, 2.00),
    "mimo-v2.5-pro": (0.50, 2.00),
}


def _match_known_pricing(model: str) -> tuple[float, float] | None:
    pricing = KNOWN_PRICING.get(model)
    if pricing:
        return pricing
    for known, prices in KNOWN_PRICING.items():
        if model.startswith(known) or known.startswith(model):
            return prices
    return None


def _match_openrouter_pricing(model: str, provider: str, or_pricing: dict) -> tuple[float, float] | None:
    """Try to match model against OpenRouter pricing dict."""
    if model in or_pricing:
        return or_pricing[model]
    if provider:
        full = f"{provider}/{model}"
        if full in or_pricing:
            return or_pricing[full]
    # Fuzzy: model name contains or is contained by an OpenRouter key
    for key, prices in or_pricing.items():
        short = key.split("/")[-1] if "/" in key else key
        if model.startswith(short) or short.startswith(model):
            return prices
    return None


async def estimate_cost(model: str, input_tokens: int, output_tokens: int, provider: str = "") -> float | None:
    """Estimate cost in USD. Tries: 1) user override, 2) OpenRouter, 3) KNOWN_PRICING."""
    from .pricing_service import fetch_openrouter_pricing
    from app.database import db_conn

    # 1. User override in DB
    try:
        async with db_conn() as db:
            row = await (await db.execute(
                "SELECT input_rate, output_rate FROM model_pricing WHERE model=?", (model,)
            )).fetchone()
        if row:
            return (input_tokens * row["input_rate"] + output_tokens * row["output_rate"]) / 1_000_000
    except Exception:
        pass

    # 2. OpenRouter pricing (fuzzy match)
    or_pricing = await fetch_openrouter_pricing()
    pricing = _match_openrouter_pricing(model, provider, or_pricing)

    # 3. KNOWN_PRICING fallback
    if not pricing:
        pricing = _match_known_pricing(model)

    if not pricing:
        return None
    input_rate, output_rate = pricing
    return (input_tokens * input_rate + output_tokens * output_rate) / 1_000_000


def economical_model(provider_id: str) -> str:
    prefix = {"openai": "gpt-", "anthropic": "claude-", "gemini": "gemini-", "xiaomimimo": "mimo-", "deepseek": "deepseek-"}.get(
        provider_id, ""
    )
    candidates = {
        mid: inp + out
        for mid, (inp, out) in KNOWN_PRICING.items()
        if mid.startswith(prefix)
    }
    if not candidates:
        defaults = {
            "openai": "gpt-4o-mini",
            "anthropic": "claude-haiku-3-5",
            "gemini": "gemini-2.0-flash",
            "xiaomimimo": "mimo-v2.5-pro",
            "deepseek": "deepseek-v4-flash",
        }
        return defaults.get(provider_id, "gpt-4o-mini")
    return min(candidates, key=candidates.get)


def _endpoint_url(base_url: str, path: str) -> str:
    base = base_url.rstrip("/")
    if base.lower().endswith("/v1") and path.startswith("/v1/"):
        path = path[3:]
    return base + path


def _normalize_api_key(key: str) -> str:
    key = key.strip()
    if "\n" in key:
        key = key.split("\n")[0].strip()
    prefixes = ["authorization:", "api-key:", "bearer "]
    changed = True
    while changed:
        changed = False
        lower = key.lower()
        for prefix in prefixes:
            if lower.startswith(prefix):
                key = key[len(prefix):].strip()
                changed = True
    return key


def _openai_auth_headers(api_key: str, base_url: str) -> dict:
    key = _normalize_api_key(api_key)
    if not key:
        return {}
    if "xiaomimimo.com" in base_url.lower():
        return {"api-key": key}
    return {"Authorization": f"Bearer {key}"}


def _openai_bearer_auth_headers(api_key: str) -> dict:
    key = _normalize_api_key(api_key)
    return {"Authorization": f"Bearer {key}"} if key else {}


def _should_send_deepseek_thinking(model: str, base_url: str) -> bool:
    return _is_deepseek_base(base_url) and model.lower().startswith("deepseek-")


def _is_xiaomi_mimo(base_url: str) -> bool:
    return "xiaomimimo.com" in base_url.lower()


def _is_deepseek_base(base_url: str) -> bool:
    return "api.deepseek.com" in (base_url or "").lower()


def _chat_completion_url(base_url: str) -> str:
    path = "/chat/completions" if _is_deepseek_base(base_url) else "/v1/chat/completions"
    return _endpoint_url(base_url, path)


def _models_url(base_url: str, api_type: str = "") -> str:
    path = "/models" if api_type == "deepseek" or _is_deepseek_base(base_url) else "/v1/models"
    return _endpoint_url(base_url, path)


def _balance_url(base_url: str, api_type: str = "") -> str:
    path = "/user/balance" if api_type == "deepseek" or _is_deepseek_base(base_url) else "/user/balance"
    return _endpoint_url(base_url, path)


def _apply_deepseek_options(body: dict, model: str, base_url: str, thinking_enabled: bool = False) -> None:
    if not _is_deepseek_base(base_url):
        return
    body["thinking"] = {"type": "enabled" if thinking_enabled else "disabled"}
    if thinking_enabled:
        body["reasoning_effort"] = "high"


def _check_http(response: httpx.Response):
    if response.status_code >= 400:
        raise httpx.HTTPStatusError(
            f"HTTP {response.status_code}",
            request=response.request,
            response=response,
        )


async def stream_openai(
    messages: list[dict],
    model: str,
    api_key: str,
    base_url: str = "https://api.openai.com",
    thinking_enabled: bool = False,
) -> AsyncGenerator[StreamEvent, None]:
    client = get_http_client()
    url = _chat_completion_url(base_url)
    headers = _openai_auth_headers(api_key, base_url)
    headers["Content-Type"] = "application/json"
    is_mimo = _is_xiaomi_mimo(base_url)

    body = {
        "model": model,
        "messages": messages,
    }
    if is_mimo:
        body["stream"] = False
        body["max_completion_tokens"] = 8192
        body["chat_template_kwargs"] = {"enable_thinking": bool(thinking_enabled)}
    else:
        body["stream"] = True
        body["stream_options"] = {"include_usage": True}
    if _should_send_deepseek_thinking(model, base_url):
        _apply_deepseek_options(body, model, base_url, thinking_enabled)

    if is_mimo:
        resp = await client.post(url, headers=headers, json=body)
        if resp.status_code == 401 and api_key:
            retry_headers = _openai_bearer_auth_headers(api_key)
            retry_headers["Content-Type"] = "application/json"
            resp = await client.post(url, headers=retry_headers, json=body)
        _check_http(resp)
        data = resp.json()
        choices = data.get("choices", [])
        message = choices[0].get("message", {}) if choices else {}
        if reasoning := message.get("reasoning_content", ""):
            yield StreamEvent(type="reasoning", content=reasoning)
        if text := message.get("content", ""):
            yield StreamEvent(type="text", content=text)
        if usage_raw := data.get("usage"):
            yield StreamEvent(type="usage", usage=_parse_openai_usage(usage_raw))
        return

    async with client.stream("POST", url, headers=headers, json=body) as response:
        _check_http(response)
        async for line in response.aiter_lines():
            if not line.startswith("data: "):
                continue
            payload = line[6:]
            if payload == "[DONE]":
                break
            try:
                data = json.loads(payload)
            except json.JSONDecodeError:
                continue

            choices = data.get("choices", [])
            if choices:
                delta = choices[0].get("delta", {})
                if reasoning := delta.get("reasoning_content", ""):
                    yield StreamEvent(type="reasoning", content=reasoning)
                if text := delta.get("content", ""):
                    yield StreamEvent(type="text", content=text)

            if usage_raw := data.get("usage"):
                yield StreamEvent(type="usage", usage=_parse_openai_usage(usage_raw))


def _parse_openai_usage(u: dict) -> UsageStats:
    stats = UsageStats(
        input_tokens=u.get("prompt_tokens", 0),
        output_tokens=u.get("completion_tokens", 0),
    )
    details = u.get("prompt_tokens_details", {})
    stats.cache_hit_tokens = details.get("cached_tokens", 0)
    stats.cache_hit_tokens = stats.cache_hit_tokens or u.get("prompt_cache_hit_tokens", 0)
    stats.cache_miss_tokens = u.get("prompt_cache_miss_tokens", 0)
    cd = u.get("completion_tokens_details", {})
    stats.reasoning_tokens = cd.get("reasoning_tokens", 0)
    return stats


async def stream_anthropic(
    messages: list[dict],
    model: str,
    api_key: str,
    base_url: str = "https://api.anthropic.com",
    thinking_enabled: bool = False,
) -> AsyncGenerator[StreamEvent, None]:
    client = get_http_client()
    system_msg = next((m["content"] for m in messages if m["role"] == "system"), None)
    non_sys = [m for m in messages if m["role"] != "system"]

    body = {
        "model": model,
        "max_tokens": 8096,
        "stream": True,
        "messages": non_sys,
    }
    if system_msg:
        body["system"] = system_msg

    headers = {
        "x-api-key": api_key,
        "anthropic-version": "2023-06-01",
        "Content-Type": "application/json",
    }

    usage = UsageStats()
    async with client.stream("POST", f"{base_url}/v1/messages", headers=headers, json=body) as resp:
        _check_http(resp)
        async for line in resp.aiter_lines():
            if not line.startswith("data: "):
                continue
            try:
                data = json.loads(line[6:])
            except json.JSONDecodeError:
                continue

            msg_type = data.get("type")
            if msg_type == "message_start":
                u = data.get("message", {}).get("usage", {})
                usage.input_tokens = u.get("input_tokens", 0)
                usage.cache_hit_tokens = u.get("cache_read_input_tokens", 0)
                usage.cache_miss_tokens = usage.input_tokens - usage.cache_hit_tokens
            elif msg_type == "content_block_delta":
                delta = data.get("delta", {})
                text = delta.get("text", "")
                if text:
                    yield StreamEvent(type="text", content=text)
            elif msg_type == "message_delta":
                u = data.get("usage", {})
                usage.output_tokens = u.get("output_tokens", 0)
            elif msg_type == "message_stop":
                yield StreamEvent(type="usage", usage=usage)


async def stream_gemini(
    messages: list[dict],
    model: str,
    api_key: str,
    base_url: str = "https://generativelanguage.googleapis.com",
) -> AsyncGenerator[StreamEvent, None]:
    client = get_http_client()
    url = f"{base_url}/v1beta/models/{model}:streamGenerateContent"
    params = {"key": api_key, "alt": "sse"}

    system_msg = next((m["content"] for m in messages if m["role"] == "system"), None)
    contents = [
        {"role": "user" if m["role"] == "user" else "model", "parts": [{"text": m["content"]}]}
        for m in messages
        if m["role"] != "system"
    ]
    body = {"contents": contents}
    if system_msg:
        body["systemInstruction"] = {"parts": [{"text": system_msg}]}

    last_usage: Optional[UsageStats] = None
    async with client.stream("POST", url, params=params, json=body) as resp:
        _check_http(resp)
        async for line in resp.aiter_lines():
            if not line.startswith("data: "):
                continue
            try:
                data = json.loads(line[6:])
            except json.JSONDecodeError:
                continue
            candidates = data.get("candidates", [])
            if candidates:
                parts = candidates[0].get("content", {}).get("parts", [])
                for part in parts:
                    if text := part.get("text", ""):
                        yield StreamEvent(type="text", content=text)
            if um := data.get("usageMetadata"):
                last_usage = UsageStats(
                    input_tokens=um.get("promptTokenCount", 0),
                    output_tokens=um.get("candidatesTokenCount", 0),
                    cache_hit_tokens=um.get("cachedContentTokenCount", 0),
                )
    if last_usage:
        yield StreamEvent(type="usage", usage=last_usage)


def make_service(api_type: str):
    return {
        "openAI": stream_openai,
        "openAICompatible": stream_openai,
        "deepseek": stream_openai,
        "xiaomiMimo": stream_openai,
        "anthropic": stream_anthropic,
        "gemini": stream_gemini,
    }.get(api_type, stream_openai)


async def fetch_balance(api_key: str, base_url: str, api_type: str) -> dict | None:
    """Fetch provider balance. Returns dict with total/granted/topped_up or None."""
    client = get_http_client()
    try:
        if api_type == "openAI":
            headers = _openai_auth_headers(api_key, base_url)
            url = _endpoint_url(base_url, "/dashboard/billing/credit_grants")
            resp = await client.get(url, headers=headers)
            if resp.status_code == 200:
                data = resp.json()
                return {
                    "total": data.get("total_granted", 0),
                    "used": data.get("total_used", 0),
                    "available": data.get("total_available", 0),
                }
        elif api_type in ("openAICompatible", "deepseek"):
            headers = _openai_bearer_auth_headers(api_key)
            url = _balance_url(base_url, api_type)
            resp = await client.get(url, headers=headers)
            if resp.status_code == 200:
                data = resp.json()
                infos = data.get("balance_infos", [])
                if infos:
                    first = infos[0]
                    return {
                        "total": first.get("total_balance"),
                        "granted": first.get("granted_balance"),
                        "available": first.get("topped_up_balance"),
                        "currency": first.get("currency"),
                    }
    except Exception:
        pass
    return None


async def check_reachability(api_key: str, base_url: str, api_type: str) -> bool:
    """Check if provider endpoint is reachable."""
    client = get_http_client()
    try:
        if api_type in ("openAI", "openAICompatible", "deepseek"):
            url = _models_url(base_url, api_type)
            headers = _openai_auth_headers(api_key, base_url)
            resp = await client.get(url, headers=headers, timeout=httpx.Timeout(30.0, connect=30.0))
            return resp.status_code < 500
        elif api_type == "xiaomiMimo":
            url = _endpoint_url(base_url, "/v1/chat/completions")
            headers = _openai_auth_headers(api_key, base_url)
            headers["Content-Type"] = "application/json"
            body = {
                "model": "mimo-v2.5-pro",
                "messages": [{"role": "user", "content": "ping"}],
                "max_completion_tokens": 1,
                "stream": False,
                "chat_template_kwargs": {"enable_thinking": False},
            }
            _reachability_timeout = httpx.Timeout(30.0, connect=30.0)
            resp = await client.post(url, headers=headers, json=body, timeout=_reachability_timeout)
            if resp.status_code == 401 and api_key:
                retry_headers = _openai_bearer_auth_headers(api_key)
                retry_headers["Content-Type"] = "application/json"
                resp = await client.post(url, headers=retry_headers, json=body, timeout=_reachability_timeout)
            return resp.status_code < 500
        elif api_type == "anthropic":
            resp = await client.get(
                f"{base_url}/v1/messages",
                headers={"x-api-key": api_key, "anthropic-version": "2023-06-01"},
                timeout=httpx.Timeout(30.0, connect=30.0),
            )
            return resp.status_code < 500
        elif api_type == "gemini":
            resp = await client.get(
                f"{base_url}/v1beta/models",
                params={"key": api_key},
                timeout=httpx.Timeout(30.0, connect=30.0),
            )
            return resp.status_code < 500
    except Exception:
        pass
    return False


async def fetch_models(api_key: str, base_url: str, api_type: str) -> list[str]:
    """Fetch available models from provider."""
    client = get_http_client()
    try:
        if api_type == "xiaomiMimo":
            return ["mimo-v2.5-pro"]
        if api_type in ("openAI", "openAICompatible", "deepseek"):
            url = _models_url(base_url, api_type)
            headers = _openai_auth_headers(api_key, base_url)
            resp = await client.get(url, headers=headers, timeout=15.0)
            if resp.status_code == 200:
                data = resp.json()
                return [m["id"] for m in data.get("data", [])]
    except Exception:
        pass
    return []
