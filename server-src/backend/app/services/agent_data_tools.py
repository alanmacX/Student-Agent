from __future__ import annotations

import json
import re
from dataclasses import dataclass
from typing import Any

import aiosqlite

from app.services.time_utils import local_day_window, local_week_window, local_now, to_utc_iso, utc_now


SENSITIVE_RE = re.compile(
    r"(access[_-]?token|refresh[_-]?token|api[_-]?key|cookie|password|password_enc|secret|auth|p256dh|endpoint)",
    re.I,
)

ALLOWED_TABLES: dict[str, str] = {
    "server_reminders": "用户提醒事项，主要时间字段 due_at/created_at/updated_at",
    "server_events": "用户日历事件，主要时间字段 start_at/end_at",
    "server_courses": "本地/教务课程表，主要时间字段 start_at/end_at",
    "chaoxing_assignments": "学习通作业缓存，主要时间字段 due_date/synced_at",
    "chaoxing_courses": "学习通课程缓存",
    "chaoxing_memory_entries": "统一 memory 条目，含 importance/hierarchy_tier/source_type/expires_at",
    "dingtalk_messages": "钉钉消息筛选结果，created_at 为毫秒 epoch",
    "scheduled_notifications": "待发/已发定时通知，主要时间字段 scheduled_at/sent_at/cancelled_at",
    "notification_log": "已发送推送记录，主要时间字段 sent_at/clicked_at/device_received_at",
    "standby_agent_log": "standby agent 决策日志，主要时间字段 ran_at",
    "agent_audit_log": "agent 写操作审计，主要时间字段 created_at",
    "ideas": "用户点子库，主要时间字段 created_at/updated_at/archived_at",
    "user_memory": "用户显式长期记忆，主要时间字段 created_at/updated_at",
    "entities": "知识实体/关注项，主要时间字段 created_at/updated_at",
    "facts": "知识事实，主要时间字段 created_at/updated_at/archived_at",
    "memory_topic_index": "memory topic 索引，主要时间字段 expires_at",
    "llm_budget_log": "LLM token 使用记录，主要时间字段 updated_at",
}

TIME_FIELD_HINTS = {
    "start_at/startDate": "事件/课程开始时间。DB 用 UTC ISO +00:00，API 兼容 camelCase。",
    "end_at/endDate": "事件/课程结束时间。DB 用 UTC ISO +00:00，API 兼容 camelCase。",
    "due_at/dueDate/due_date": "提醒/作业截止时间。无时区输入按 Asia/Shanghai 解析，存储应归一为 UTC。",
    "scheduled_at": "定时推送计划触发时间，UTC ISO。",
    "sent_at": "消息/推送发送时间，UTC ISO。",
    "created_at/updated_at": "记录创建/更新时间，UTC ISO；少量旧数据可能无 offset。",
    "dingtalk_messages.created_at": "钉钉原始时间，毫秒 epoch。",
}

DEFAULT_SCHEMA_TABLES = {
    "server_reminders",
    "server_events",
    "server_courses",
    "chaoxing_assignments",
    "chaoxing_memory_entries",
    "dingtalk_messages",
    "entities",
    "facts",
    "notification_log",
}


@dataclass
class SearchResult:
    ok: bool
    payload: dict[str, Any]

    def to_json(self) -> str:
        return json.dumps(self.payload, ensure_ascii=False, indent=2)


async def schema_payload(db_path: str | None = None, tables: list[str] | None = None) -> dict[str, Any]:
    payload = {
        "ok": True,
        "tables": ALLOWED_TABLES,
        "time_fields": TIME_FIELD_HINTS,
        "importance": {
            "importance": ["high", "medium", "low"],
            "hierarchy_tier": {
                "0": "CRITICAL，今天/紧急/会打扰用户",
                "1": "ACTIONABLE，本周需要行动",
                "2": "CONTEXT，可按 query 检索",
            },
        },
        "query_rules": [
            "search_database 只能 SELECT 或 PRAGMA table_info。",
            "默认 brief，只返回摘要字段；需要完整正文时用 get_record_detail。",
            "所有时间比较建议使用 UTC ISO 参数，例如 2026-06-12T10:30:00+00:00。",
        ],
        "examples": [
            "SELECT id,title,start_at,end_at,location FROM server_courses WHERE start_at >= ? ORDER BY start_at LIMIT 20",
            "SELECT id,title,summary,importance,expires_at FROM chaoxing_memory_entries WHERE archived_at IS NULL AND title LIKE ? LIMIT 20",
        ],
    }
    if db_path:
        requested = {str(t).strip() for t in (tables or []) if str(t).strip()}
        payload["columns"] = await table_columns(db_path, requested or DEFAULT_SCHEMA_TABLES)
    return payload


def current_time_payload() -> dict[str, Any]:
    now_utc = utc_now()
    today_start, today_end = local_day_window(now_utc)
    week_start, week_end = local_week_window(now_utc)
    local = local_now()
    return {
        "ok": True,
        "timezone": "Asia/Shanghai",
        "now_utc": to_utc_iso(now_utc),
        "now_local": local.isoformat(),
        "unix": int(now_utc.timestamp()),
        "today": {
            "local_date": local.date().isoformat(),
            "start_utc": to_utc_iso(today_start),
            "end_utc": to_utc_iso(today_end),
        },
        "this_week": {
            "start_utc": to_utc_iso(week_start),
            "end_utc": to_utc_iso(week_end),
        },
    }


async def search_database(
    db_path: str,
    sql: str,
    params: list[Any] | None = None,
    limit: int = 20,
    detail_level: str = "brief",
) -> SearchResult:
    sql = (sql or "").strip()
    params = params or []
    limit = max(1, min(int(limit or 10), 50))
    detail_level = "detailed" if detail_level == "detailed" else "brief"
    ok, reason = validate_read_sql(sql)
    if not ok:
        return SearchResult(False, {"ok": False, "error": reason})

    limited_sql = _with_limit(sql, limit)
    try:
        async with aiosqlite.connect(db_path) as db:
            db.row_factory = aiosqlite.Row
            rows = await (await db.execute(limited_sql, tuple(params))).fetchmany(limit)
            payload_rows = [_clean_row(dict(row), detail_level=detail_level) for row in rows]
    except aiosqlite.Error as exc:
        tables = sorted(_extract_tables(sql) or _extract_pragma_tables(sql))
        return SearchResult(False, {
            "ok": False,
            "error": f"{type(exc).__name__}: {exc}",
            "provenance": {"tables": tables, "sql": _sql_preview(sql)},
            "columns": await table_columns(db_path, set(tables)) if tables else {},
            "hint": "先用返回的 columns 修正列名；不要猜不存在的字段。",
        })
    return SearchResult(True, {
        "ok": True,
        "mode": detail_level,
        "row_count": len(payload_rows),
        "limit": limit,
        "provenance": {"tables": sorted(_extract_tables(sql)), "sql": _sql_preview(sql)},
        "rows": payload_rows,
    })


async def table_columns(db_path: str, tables: set[str] | None = None) -> dict[str, list[dict[str, Any]]]:
    target_tables = tables or set(ALLOWED_TABLES)
    columns: dict[str, list[dict[str, Any]]] = {}
    async with aiosqlite.connect(db_path) as db:
        db.row_factory = aiosqlite.Row
        for table in sorted(t for t in target_tables if t in ALLOWED_TABLES):
            rows = await (await db.execute(f'PRAGMA table_info("{table}")')).fetchall()
            clean_cols = []
            for row in rows:
                name = row["name"]
                if SENSITIVE_RE.search(name):
                    continue
                clean_cols.append({
                    "name": name,
                    "type": row["type"] or "",
                    "pk": bool(row["pk"]),
                })
            columns[table] = clean_cols
    return columns


async def get_record_detail(db_path: str, source: str, record_id: str) -> dict[str, Any]:
    table = (source or "").strip()
    if table not in ALLOWED_TABLES:
        return {"ok": False, "error": f"不允许读取表 {table}"}
    if SENSITIVE_RE.search(table):
        return {"ok": False, "error": "目标表包含敏感信息"}
    async with aiosqlite.connect(db_path) as db:
        db.row_factory = aiosqlite.Row
        row = await (await db.execute(f'SELECT * FROM "{table}" WHERE id=? LIMIT 1', (record_id,))).fetchone()
    if not row:
        return {"ok": False, "error": "record not found", "source": table, "id": record_id}
    return {
        "ok": True,
        "source": table,
        "id": record_id,
        "record": _clean_row(dict(row), detail_level="detailed"),
    }


def validate_read_sql(sql: str) -> tuple[bool, str]:
    if not sql:
        return False, "SQL 为空"
    if _has_multiple_statements(sql):
        return False, "只允许单条 SQL"
    if re.match(r"^\s*pragma\s+table_info\s*\(", sql, re.I):
        tables = _extract_pragma_tables(sql)
    elif re.match(r"^\s*select\b", sql, re.I):
        if re.search(r"\b(insert|update|delete|drop|alter|attach|detach|replace|create|vacuum|reindex)\b", sql, re.I):
            return False, "只读查询不能包含写操作"
        tables = _extract_tables(sql)
    else:
        return False, "只允许 SELECT 或 PRAGMA table_info"
    if not tables:
        return False, "未识别到允许的业务表"
    forbidden = sorted(t for t in tables if t not in ALLOWED_TABLES)
    if forbidden:
        return False, f"不允许读取表: {', '.join(forbidden)}"
    if SENSITIVE_RE.search(sql):
        return False, "查询包含敏感字段或敏感表名"
    return True, ""


def _extract_tables(sql: str) -> set[str]:
    tables = set()
    for pattern in (r"\bfrom\s+([a-zA-Z_][\w]*)", r"\bjoin\s+([a-zA-Z_][\w]*)"):
        for match in re.finditer(pattern, sql, re.I):
            tables.add(match.group(1))
    return tables


def _extract_pragma_tables(sql: str) -> set[str]:
    match = re.search(r"table_info\s*\(\s*['\"]?([a-zA-Z_][\w]*)['\"]?\s*\)", sql, re.I)
    return {match.group(1)} if match else set()


def _has_multiple_statements(sql: str) -> bool:
    stripped = sql.strip()
    if ";" not in stripped:
        return False
    return stripped.rstrip(";").count(";") > 0


def _with_limit(sql: str, limit: int) -> str:
    stripped = sql.rstrip().rstrip(";")
    if re.match(r"^\s*select\b", stripped, re.I) and not re.search(r"\blimit\b", stripped, re.I):
        return f"{stripped} LIMIT {limit}"
    return stripped


def _clean_row(row: dict[str, Any], detail_level: str) -> dict[str, Any]:
    cleaned: dict[str, Any] = {}
    max_len = 1200 if detail_level == "detailed" else 220
    for key, value in row.items():
        if SENSITIVE_RE.search(key):
            continue
        if isinstance(value, str) and len(value) > max_len:
            value = value[:max_len] + f"...(truncated {len(value)} chars)"
        cleaned[key] = value
    return cleaned


def _sql_preview(sql: str) -> str:
    one_line = re.sub(r"\s+", " ", sql).strip()
    return one_line[:500]
