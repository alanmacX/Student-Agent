import json
import asyncio
import tempfile
import unittest
from datetime import datetime
from types import SimpleNamespace
from zoneinfo import ZoneInfo

import aiosqlite
from fastapi import FastAPI
from fastapi.testclient import TestClient

from app.config import settings
from app.database import run_migrations
from app.routers.schedule import (
    _compact_schedule_payload_context,
    _history_message_with_payload,
    _plan_recent_payload_delete,
    router as schedule_router,
)
from app.services.tool_router import _augment_mutation_resolution_tools


class SchedulePayloadFollowupTests(unittest.TestCase):
    def setUp(self):
        self.payload = {
            "type": "schedule_payload",
            "reminders": [
                {
                    "id": "e0386133-d700-47bf-b414-83bf3fa9134a",
                    "title": "web课设",
                    "dueDate": "2026-06-09T23:59:00+08:00",
                    "isCompleted": False,
                    "listName": "默认",
                },
                {
                    "id": "45edabc8-c036-4665-9a94-2da9e9696af2",
                    "title": "科研方向",
                    "dueDate": "2026-06-09T23:59:00+08:00",
                    "isCompleted": False,
                    "listName": "默认",
                },
                {
                    "id": "17db6eda-ed01-4b33-a176-b8abae6a7bef",
                    "title": "明天下午冲GPT账号",
                    "dueDate": None,
                    "isCompleted": False,
                    "listName": "默认",
                },
            ],
        }

    def test_saved_payload_becomes_compact_history_context(self):
        context = _compact_schedule_payload_context(json.dumps(self.payload, ensure_ascii=False))

        self.assertIn("【上一轮结构化结果】", context)
        self.assertIn("e0386133-d700-47bf-b414-83bf3fa9134a", context)
        self.assertIn("web课设", context)

        row = {
            "role": "assistant",
            "content": "这两个提醒都已经过期。",
            "schedule_payload_json": json.dumps(self.payload, ensure_ascii=False),
        }
        message = _history_message_with_payload(row)
        self.assertEqual(message["role"], "assistant")
        self.assertIn("这两个提醒都已经过期。", message["content"])
        self.assertIn("上一轮结构化结果", message["content"])

    def test_bulk_delete_followup_targets_expired_reminders_only(self):
        row = {
            "role": "assistant",
            "content": "这两个提醒都是 6月9日到期，已经过期4天了。",
            "schedule_payload_json": json.dumps(self.payload, ensure_ascii=False),
        }
        plan = _plan_recent_payload_delete(
            "都删掉吧",
            [row],
            now=datetime(2026, 6, 13, 16, 20, tzinfo=ZoneInfo("Asia/Shanghai")),
        )

        self.assertIsNotNone(plan)
        ids = {m["arguments"]["id"] for m in plan["mutations"]}
        self.assertEqual(ids, {
            "e0386133-d700-47bf-b414-83bf3fa9134a",
            "45edabc8-c036-4665-9a94-2da9e9696af2",
        })
        self.assertIn("已过期提醒", plan["text"])
        self.assertNotIn("17db6eda-ed01-4b33-a176-b8abae6a7bef", ids)

    def test_mutation_router_keeps_read_tool_for_id_resolution(self):
        tools = [
            SimpleNamespace(name="delete_reminder"),
            SimpleNamespace(name="list_reminders"),
            SimpleNamespace(name="list_calendar_events"),
        ]

        selected = _augment_mutation_resolution_tools("都删掉吧", ["delete_reminder"], tools)
        self.assertIn("delete_reminder", selected)
        self.assertIn("list_reminders", selected)

        selected_with_id = _augment_mutation_resolution_tools(
            "删除 e0386133-d700-47bf-b414-83bf3fa9134a",
            ["delete_reminder"],
            tools,
        )
        self.assertEqual(selected_with_id, ["delete_reminder"])


class ScheduleChatRouteFollowupTests(unittest.TestCase):
    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory()
        self.old_db_path = settings.database_path
        self.db_path = f"{self.tmp.name}/chatbot.db"
        settings.database_path = self.db_path
        asyncio.run(run_migrations(self.db_path))

    def tearDown(self):
        settings.database_path = self.old_db_path
        self.tmp.cleanup()

    def test_bulk_delete_followup_queues_then_confirms_exact_targets(self):
        payload = {
            "type": "schedule_payload",
            "reminders": [
                {
                    "id": "e0386133-d700-47bf-b414-83bf3fa9134a",
                    "title": "web课设",
                    "dueDate": "2026-06-09T23:59:00+08:00",
                    "isCompleted": False,
                    "listName": "默认",
                },
                {
                    "id": "45edabc8-c036-4665-9a94-2da9e9696af2",
                    "title": "科研方向",
                    "dueDate": "2026-06-09T23:59:00+08:00",
                    "isCompleted": False,
                    "listName": "默认",
                },
                {
                    "id": "17db6eda-ed01-4b33-a176-b8abae6a7bef",
                    "title": "明天下午冲GPT账号",
                    "dueDate": None,
                    "isCompleted": False,
                    "listName": "默认",
                },
            ],
        }

        async def seed():
            async with aiosqlite.connect(self.db_path) as db:
                await db.execute(
                    "INSERT INTO schedule_sessions (id, title, created_at, updated_at) VALUES (?,?,?,?)",
                    ("s1", "测试", "2026-06-13T08:00:00+00:00", "2026-06-13T08:00:00+00:00"),
                )
                await db.execute(
                    "INSERT INTO schedule_messages (id, session_id, role, content, schedule_payload_json, timestamp, position) VALUES (?,?,?,?,?,?,?)",
                    (
                        "m1",
                        "s1",
                        "assistant",
                        "这两个提醒都是 6月9日到期，已经过期4天了。",
                        json.dumps(payload, ensure_ascii=False),
                        "2026-06-13T08:00:00+00:00",
                        1,
                    ),
                )
                for reminder in payload["reminders"]:
                    await db.execute(
                        """
                        INSERT INTO server_reminders
                            (id, title, list_name, due_at, notes, is_completed, is_important, created_at, updated_at)
                        VALUES (?,?,?,?,?,?,?,?,?)
                        """,
                        (
                            reminder["id"],
                            reminder["title"],
                            "默认",
                            reminder.get("dueDate"),
                            None,
                            0,
                            0,
                            "2026-06-01T00:00:00+00:00",
                            "2026-06-01T00:00:00+00:00",
                        ),
                    )
                await db.commit()

        asyncio.run(seed())

        app = FastAPI()
        app.state.chaoxing_svc = SimpleNamespace(is_logged_in=False)
        app.include_router(schedule_router)
        with TestClient(app) as client:
            response = client.post("/api/schedule/chat", json={"session_id": "s1", "message": "都删掉吧"})
            self.assertEqual(response.status_code, 200)
            self.assertIn("pending_confirmation", response.text)
            self.assertIn("将删除 2 条已过期提醒", response.text)

            confirm = client.post("/api/schedule/confirm", json={"session_id": "s1", "action": "confirm"})
            self.assertEqual(confirm.status_code, 200)
            self.assertTrue(confirm.json()["ok"])

        async def remaining_ids():
            async with aiosqlite.connect(self.db_path) as db:
                rows = await (await db.execute("SELECT id FROM server_reminders ORDER BY id")).fetchall()
                return [row[0] for row in rows]

        self.assertEqual(asyncio.run(remaining_ids()), ["17db6eda-ed01-4b33-a176-b8abae6a7bef"])


if __name__ == "__main__":
    unittest.main()
