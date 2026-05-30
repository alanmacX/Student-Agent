from fastapi import APIRouter
from app.database import db_conn
from app.models import SettingsUpdate
import json

router = APIRouter(prefix="/api/settings", tags=["settings"])

DEFAULT_NOTIFICATION_RULE_PROMPT = """你是推送通知调度器。读到新的重要消息或事件后，判断是否值得推送给用户，以及最佳推送时机。

规则：
- 考试/期末/期中变动 → 立即调度一条推送（scheduled_at = now + 5分钟）
- 作业截止在 48 小时内 → 调度在截止前 2 小时推送（若已有 deadline_check 覆盖则跳过）
- 调课/停课/换教室 → 立即调度
- 普通通知/闲聊/已知信息 → 不调度
- 同一事件只调度一次（检查 source_id 是否已存在 scheduled_notifications）
- 夜间（23:00-7:00）不调度，推迟到次日 7:30"""


@router.get("")
async def get_settings():
    async with db_conn() as db:
        rows = await (await db.execute("SELECT key, value FROM settings")).fetchall()
        return {r["key"]: _try_parse_json(r["value"]) for r in rows}


@router.put("")
async def update_settings(body: SettingsUpdate):
    async with db_conn() as db:
        for key, value in body.settings.items():
            if isinstance(value, (dict, list)):
                value = json.dumps(value)
            await db.execute(
                "INSERT OR REPLACE INTO settings (key, value) VALUES (?,?)",
                (key, str(value)),
            )
        await db.commit()
        return {"ok": True}


@router.get("/notification-rules")
async def get_notification_rules():
    async with db_conn() as db:
        row = await (await db.execute(
            "SELECT value FROM settings WHERE key='notification_rule_prompt'"
        )).fetchone()
        return {"value": row["value"] if row else DEFAULT_NOTIFICATION_RULE_PROMPT}


@router.put("/notification-rules")
async def update_notification_rules(body: dict):
    value = body.get("value") or DEFAULT_NOTIFICATION_RULE_PROMPT
    async with db_conn() as db:
        await db.execute(
            "INSERT OR REPLACE INTO settings (key, value) VALUES ('notification_rule_prompt', ?)",
            (str(value),),
        )
        await db.commit()
        return {"ok": True}


@router.get("/{key}")
async def get_setting(key: str):
    async with db_conn() as db:
        row = await (await db.execute("SELECT value FROM settings WHERE key=?", (key,))).fetchone()
        if not row:
            return {"value": None}
        return {"value": _try_parse_json(row["value"])}


@router.put("/{key}")
async def update_setting(key: str, body: dict):
    async with db_conn() as db:
        value = body.get("value")
        if isinstance(value, (dict, list)):
            value = json.dumps(value)
        await db.execute(
            "INSERT OR REPLACE INTO settings (key, value) VALUES (?,?)",
            (key, str(value)),
        )
        await db.commit()
        return {"ok": True}


def _try_parse_json(value: str):
    try:
        return json.loads(value)
    except (json.JSONDecodeError, TypeError):
        return value
