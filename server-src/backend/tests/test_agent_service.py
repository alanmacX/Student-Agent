"""Tests for agent_complete outer retry behavior.

The OpenAI path calls post_json_with_retries(client, ...) — we patch that to
raise controlled errors, exercising only the OUTER retry loop in agent_complete.
"""
from __future__ import annotations

import json
from unittest.mock import patch

import httpx
import pytest

from app.services.agent_service import AgentMsg


def _http_err(status: int, headers: dict | None = None) -> httpx.HTTPStatusError:
    resp = httpx.Response(status, headers=headers or {},
                          request=httpx.Request("POST", "https://x/v1/chat/completions"))
    return httpx.HTTPStatusError(f"HTTP {status}", request=resp.request, response=resp)


def _ok_response(text="hi"):
    from app.services.agent_service import AgentResponse
    return AgentResponse(text=text, reasoning_content=None, tool_calls=[],
                         usage=None, stop_reason="end_turn")


@pytest.mark.asyncio
async def test_retry_on_429_then_success(monkeypatch):
    from app.services import agent_service as svc

    calls = {"n": 0}
    sleeps: list[float] = []

    async def fake_openai(*a, **k):
        calls["n"] += 1
        if calls["n"] == 1:
            raise _http_err(429, {"retry-after": "0.01"})
        return _ok_response()

    async def fake_sleep(d):
        sleeps.append(d)

    monkeypatch.setattr(svc, "_openai_agent_complete", fake_openai)
    with patch.object(svc.asyncio, "sleep", fake_sleep):
        resp = await svc.agent_complete([AgentMsg(role="user", content="x")], [],
                                        {"api_type": "openAI", "base_url": "https://x"},
                                        "m", "k")
    assert resp.text == "hi"
    assert calls["n"] == 2 and len(sleeps) == 1


@pytest.mark.asyncio
async def test_no_retry_on_401(monkeypatch):
    from app.services import agent_service as svc

    calls = {"n": 0}

    async def fake_openai(*a, **k):
        calls["n"] += 1
        raise _http_err(401)

    monkeypatch.setattr(svc, "_openai_agent_complete", fake_openai)
    with pytest.raises(httpx.HTTPStatusError):
        await svc.agent_complete([AgentMsg(role="user", content="x")], [],
                                 {"api_type": "openAI", "base_url": "https://x"},
                                 "m", "k")
    assert calls["n"] == 1


@pytest.mark.asyncio
async def test_gives_up_after_max_attempts_on_503(monkeypatch):
    from app.services import agent_service as svc

    calls = {"n": 0}

    async def fake_openai(*a, **k):
        calls["n"] += 1
        raise _http_err(503)

    async def fake_sleep(d):
        pass

    monkeypatch.setattr(svc, "_openai_agent_complete", fake_openai)
    with patch.object(svc.asyncio, "sleep", fake_sleep):
        with pytest.raises(httpx.HTTPStatusError):
            await svc.agent_complete([AgentMsg(role="user", content="x")], [],
                                     {"api_type": "openAI", "base_url": "https://x"},
                                     "m", "k")
    assert calls["n"] == svc._MAX_ATTEMPTS


@pytest.mark.asyncio
async def test_retries_network_timeout(monkeypatch):
    from app.services import agent_service as svc

    calls = {"n": 0}

    async def fake_openai(*a, **k):
        calls["n"] += 1
        if calls["n"] == 1:
            raise httpx.ReadTimeout("timed out")
        return _ok_response("after timeout")

    async def fake_sleep(d):
        pass

    monkeypatch.setattr(svc, "_openai_agent_complete", fake_openai)
    with patch.object(svc.asyncio, "sleep", fake_sleep):
        resp = await svc.agent_complete([AgentMsg(role="user", content="x")], [],
                                        {"api_type": "openAI", "base_url": "https://x"},
                                        "m", "k")
    assert resp.text == "after timeout"
    assert calls["n"] == 2
