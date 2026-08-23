"""Shared fixtures: temp DB from real migrations + MockLLM injection.

The MockLLM patches ``app.services.agent_service.agent_complete`` so the whole
pipeline (reconciler, classifier, memory agents, schedule agent) runs offline —
no network, no API key.  Scenarios script per-call responses.
"""
from __future__ import annotations

import asyncio
import json
import os
import sys
from pathlib import Path
from unittest.mock import patch

# Offline push: give push_service a syntactically-valid VAPID key so
# notify_now reaches the "attempted=0 subscribers" path (logged, dedupable)
# instead of bailing on missing config. No network calls happen — there are
# no subscriptions in the test DB.
os.environ.setdefault(
    "VAPID_PRIVATE_KEY",
    (Path(__file__).parent / "vapid_test_key.pem").read_text()
    if (Path(__file__).parent / "vapid_test_key.pem").exists() else "",
)

import aiosqlite
import pytest
import pytest_asyncio

BACKEND_ROOT = Path(__file__).resolve().parents[1]
sys.path.insert(0, str(BACKEND_ROOT))

from app.database import run_migrations  # noqa: E402


# ── Mock LLM ─────────────────────────────────────────────────────────────────

class MockLLM:
    """Scripted agent_complete replacement.

    responses: list of items. Each item is either
      - a str  -> returned as response.text (JSON or plain text)
      - a dict -> {"text": ...} or {"tool_calls": [{"name","arguments","id"}]}
    If calls exceed the script, the last item repeats (or empty text).
    Every call is recorded in ``self.calls`` for assertions.
    """

    def __init__(self, responses=None):
        self.responses = list(responses or [])
        self.calls: list[dict] = []

    def _next(self, idx: int):
        if not self.responses:
            return {"text": ""}
        return self.responses[min(idx, len(self.responses) - 1)]

    async def agent_complete(self, messages, tools, provider, model, api_key, *args, **kwargs):
        idx = len(self.calls)
        self.calls.append({
            "messages": messages,
            "tools": [t.name for t in tools],
            "model": model,
            "system": next((m.content for m in messages if m.role == "system"), ""),
            "user": next((m.content for m in reversed(messages) if m.role == "user"), ""),
        })
        spec = self._next(idx)
        if isinstance(spec, str):
            spec = {"text": spec}
        from app.services.agent_service import AgentResponse, ToolCall
        from app.services.api_service import UsageStats

        tool_calls = [
            ToolCall(id=tc.get("id", f"call_{i}"), name=tc["name"], arguments=tc.get("arguments", {}))
            for i, tc in enumerate(spec.get("tool_calls") or [])
        ]
        return AgentResponse(
            text=spec.get("text"),
            reasoning_content=None,
            tool_calls=tool_calls,
            usage=UsageStats(input_tokens=spec.get("input_tokens", 100),
                             output_tokens=spec.get("output_tokens", 50)),
            stop_reason="tool_use" if tool_calls else "end_turn",
        )


@pytest_asyncio.fixture
async def db_path(tmp_path):
    """Fresh DB built from the real migrations, with one dummy push subscription
    so notify_now takes the attempted>0 path (logged + dedupable) offline.
    The dummy endpoint fails fast and gracefully — no network in tests."""
    from datetime import datetime, timezone

    p = tmp_path / "test_chatbot.db"
    await run_migrations(str(p))
    async with aiosqlite.connect(str(p)) as db:
        await db.execute(
            "INSERT INTO push_subscriptions (endpoint, p256dh, auth, created_at) VALUES (?,?,?,?)",
            ("https://push.invalid/fcm/test-sub", "k", "a",
             datetime.now(timezone.utc).isoformat()),
        )
        await db.commit()
    return str(p)


@pytest_asyncio.fixture
async def db(db_path):
    async with aiosqlite.connect(db_path) as conn:
        conn.row_factory = aiosqlite.Row
        yield conn


@pytest.fixture
def seed_courses(db_path):
    """Insert a small course schedule for 'now' = 2026-09-14 (Mon) week."""
    import uuid
    from datetime import datetime, timedelta, timezone

    async def _seed(rows):
        now = datetime.now(timezone.utc)
        async with aiosqlite.connect(db_path) as db:
            for title, start, end, loc in rows:
                await db.execute(
                    """INSERT INTO server_courses (id, title, start_at, end_at, location, notes, synced_at)
                       VALUES (?,?,?,?,?,?,?)""",
                    (str(uuid.uuid4()), title, start, end, loc, "", now.isoformat()),
                )
            await db.commit()
    return _seed


@pytest.fixture
def mock_llm():
    """Patch agent_complete everywhere it is imported lazily.

    All pipeline modules do ``from app.services.agent_service import agent_complete``
    *inside* their functions, so patching the source attribute works globally.
    """
    mock = MockLLM()
    with patch("app.services.agent_service.agent_complete", new=mock.agent_complete):
        yield mock


def run(coro):
    return asyncio.run(coro)
