from fastapi import APIRouter

from app.config import settings
from app.services.schedule_store import (
    create_reminder,
    delete_reminder,
    list_reminders,
    update_reminder,
)

router = APIRouter(prefix="/api/reminders", tags=["reminders"])


@router.get("")
async def get_reminders(include_completed: bool = False):
    return await list_reminders(settings.database_path, include_completed=include_completed)


@router.post("")
async def post_reminder(body: dict):
    return await create_reminder(
        settings.database_path,
        title=body.get("title", "").strip(),
        due_at=body.get("dueDate"),
        notes=body.get("notes"),
        list_name=body.get("listName") or "默认",
        is_important=body.get("isImportant", False),
    )


@router.put("/{reminder_id}")
async def put_reminder(reminder_id: str, body: dict):
    reminder = await update_reminder(settings.database_path, reminder_id, **body)
    return reminder or {"error": "not found"}


@router.delete("/{reminder_id}")
async def remove_reminder(reminder_id: str):
    return {"ok": await delete_reminder(settings.database_path, reminder_id)}
