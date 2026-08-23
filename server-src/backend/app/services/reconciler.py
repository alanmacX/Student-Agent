"""Context-bounded reconciler for external student messages.

The reconciler replaces the legacy generic automation engine for DingTalk and
Chaoxing text messages. Its guardrail is simple: the model only emits
operations, and destructive/update operations may reference only ids that were
present in this call's context package.
"""
from __future__ import annotations

import json
import logging
from dataclasses import dataclass, field
from datetime import datetime, timedelta, timezone
from typing import Any

import aiosqlite

from app.memory.base import MemoryEntry, MemoryRepository, Tier, compute_tier
from app.memory.keys import canonical_dedupe_key
from app.services.knowledge import (
    create_fact,
    find_entity_by_name,
    sync_entity_fts,
    sync_fact_fts,
    sync_item_fts,
    upsert_entity,
)

logger = logging.getLogger("reconciler")


@dataclass
class ReconcileResult:
    ok: bool = True
    effects_applied: int = 0
    memory_upserted: list[str] = field(default_factory=list)
    memory_archived: list[str] = field(default_factory=list)
    facts_created: list[str] = field(default_factory=list)
    push_scheduled: int = 0
    errors: list[str] = field(default_factory=list)
    warnings: list[str] = field(default_factory=list)


SYSTEM_PROMPT = """你是学生个人助理的消息 Reconciler。你只能把消息转成结构化 ops。

硬规则：
- 只输出 JSON：{"ops":[],"need_more":false}
- update_item/cancel_item 的 id 必须来自上下文里的 item id。
- cancel_course_rows 的 ids 必须来自上下文里的 course row id。
- 不确定就 new_item 或 conflict，不要凭空取消/修改。
- due 必须是 ISO-8601 带时区；没有明确时间用 null。
- push_now 只有在 ref_item 是上下文 item id 时才用。

op schema:
new_item: {"op":"new_item","kind":"assignment|exam|course_change|notice|signup","entity":"ent_x|new:名称","title":"...","due":"ISO|null","importance":2}
update_item: {"op":"update_item","id":"item id","due":"ISO","note":"..."}
cancel_item: {"op":"cancel_item","id":"item id","scope_note":"..."}
cancel_course_rows: {"op":"cancel_course_rows","ids":["course row id"]}
new_fact: {"op":"new_fact","entity":"ent_x","text":"..."}
push_now: {"op":"push_now","title":"≤15字","body":"≤50字","ref_item":"item id|null"}
conflict: {"op":"conflict","a":"...","b":"...","question":"≤40字"}
"""


async def reconcile_message(
    msg: dict,
    db_path: str,
    provider: dict,
    model: str,
    api_key: str,
    now: datetime | None = None,
    sibling_messages: list[dict] | None = None,
) -> ReconcileResult:
    if now is None:
        now = datetime.now(timezone.utc)
    if now.tzinfo is None:
        now = now.replace(tzinfo=timezone.utc)

    text = (msg.get("text") or "").strip()
    if len(text) < 5 and not sibling_messages:
        return ReconcileResult()
    if not provider or not api_key:
        return ReconcileResult(ok=False, errors=["missing_provider_or_api_key"])
    try:
        from app.services.budget import is_budget_exhausted

        if await is_budget_exhausted(db_path) and msg.get("verdict") != "notify":
            return ReconcileResult(ok=True, warnings=["budget_exhausted_skipped_non_notify"])
    except Exception:
        pass

    ctx = await _build_context_package(db_path, msg, now)
    raw = await _call_model(provider, model, api_key, now, ctx["text"], msg, db_path,
                            sibling_messages=sibling_messages)
    parsed = _parse_json(raw)
    if parsed.get("need_more") and parsed.get("lookup_entity"):
        extra = await _lookup_entity_context(db_path, str(parsed.get("lookup_entity")), now)
        raw = await _call_model(provider, model, api_key, now, ctx["text"] + "\n\n补充实体:\n" + extra,
                                msg, db_path, sibling_messages=sibling_messages)
        parsed = _parse_json(raw)

    ops = parsed.get("ops") if isinstance(parsed.get("ops"), list) else []
    valid_ops, warnings = _validate_ops(ops, ctx, now)
    result = await _execute_ops(valid_ops, db_path, msg, now, ctx)
    result.warnings.extend(warnings)
    return result


async def _build_context_package(db_path: str, msg: dict, now: datetime) -> dict:
    text = msg.get("text") or ""
    entity_rows = await _recall_entities(db_path, text)
    item_ids: set[str] = set()
    course_ids: set[str] = set()
    entity_ids = {r["id"] for r in entity_rows}

    lines = [f"当前时间: {now.astimezone(timezone(timedelta(hours=8))).isoformat()}"]
    lines.append(f"来源: {msg.get('source_type','?')} / 会话: {msg.get('conversation_title') or '私聊'}")

    async with aiosqlite.connect(db_path) as db:
        db.row_factory = aiosqlite.Row
        if entity_rows:
            lines.append("命中实体:")
            for ent in entity_rows[:3]:
                lines.append(f"- {ent['id']} {ent['etype']} {ent['name']} attrs={ent['attrs']} notes={(ent['notes'] or '')[:200]}")
                items = await (await db.execute(
                    """SELECT id, title, summary, action_hint, importance, kind, category, expires_at
                       FROM chaoxing_memory_entries
                       WHERE archived_at IS NULL
                         AND COALESCE(status, 'active')='active'
                         AND (entity_id=? OR title LIKE ? OR conversation_names_json LIKE ?)
                       ORDER BY expires_at ASC LIMIT 8""",
                    (ent["id"], f"%{ent['name']}%", f"%{ent['name']}%"),
                )).fetchall()
                for item in items:
                    item_ids.add(item["id"])
                    lines.append(
                        f"  item {item['id']} kind={item['kind']}/{item['category']} due={item['expires_at']} title={item['title']} hint={item['action_hint'] or item['summary']}"
                    )
        else:
            directory = await (await db.execute(
                "SELECT id, etype, name FROM entities WHERE status='active' ORDER BY etype, name LIMIT 80"
            )).fetchall()
            if directory:
                lines.append("实体目录: " + " | ".join(f"{r['id']} {r['etype']} {r['name']}" for r in directory))
            recent_items = await (await db.execute(
                """SELECT id, title, summary, action_hint, importance, kind, category, expires_at
                   FROM chaoxing_memory_entries
                   WHERE archived_at IS NULL
                     AND COALESCE(status, 'active')='active'
                   ORDER BY COALESCE(expires_at, updated_at, extracted_at, sent_at) ASC
                   LIMIT 8"""
            )).fetchall()
            if recent_items:
                lines.append("最近 active items:")
                for item in recent_items:
                    item_ids.add(item["id"])
                    lines.append(
                        f"- item {item['id']} kind={item['kind']}/{item['category']} due={item['expires_at']} title={item['title']} hint={item['action_hint'] or item['summary']}"
                    )

        future = (now + timedelta(days=7)).isoformat()
        courses = await (await db.execute(
            """SELECT id, title, start_at, end_at, location, notes
               FROM server_courses
               WHERE end_at >= ? AND start_at <= ?
               ORDER BY start_at ASC LIMIT 30""",
            (now.isoformat(), future),
        )).fetchall()
        if courses:
            lines.append("未来7天课程行:")
            for row in courses:
                course_ids.add(row["id"])
                lines.append(f"- course_row {row['id']} {row['title']} {row['start_at']}~{row['end_at']} {row['location'] or ''} {row['notes'] or ''}")

        if entity_ids:
            placeholders = ",".join("?" for _ in entity_ids)
            facts = await (await db.execute(
                f"""SELECT entity_id, text FROM facts
                    WHERE archived_at IS NULL AND entity_id IN ({placeholders})
                    ORDER BY updated_at DESC LIMIT 5""",
                list(entity_ids),
            )).fetchall()
        else:
            facts = await (await db.execute(
                """SELECT entity_id, text FROM facts
                   WHERE archived_at IS NULL ORDER BY updated_at DESC LIMIT 5"""
            )).fetchall()
        if facts:
            lines.append("相关 facts:")
            for row in facts:
                lines.append(f"- {row['entity_id'] or ''} {row['text']}")

    return {
        "text": "\n".join(lines)[:3500],
        "entity_ids": entity_ids,
        "item_ids": item_ids,
        "course_ids": course_ids,
    }


async def _recall_entities(db_path: str, text: str) -> list[aiosqlite.Row]:
    async with aiosqlite.connect(db_path) as db:
        db.row_factory = aiosqlite.Row
        rows = await (await db.execute(
            "SELECT * FROM entities WHERE status='active' ORDER BY updated_at DESC LIMIT 200"
        )).fetchall()
        scored: list[tuple[int, aiosqlite.Row]] = []
        for row in rows:
            aliases = _loads_list(row["aliases"])
            score = 0
            if row["name"] and row["name"] in text:
                score += 10
            score += sum(4 for a in aliases if a and a in text)
            if score:
                scored.append((score, row))

        if len(scored) < 3:
            query = _fts_query(text)
            if query:
                try:
                    hits = await (await db.execute(
                        """SELECT e.*
                           FROM kb_fts f JOIN entities e ON e.id=f.doc_id
                           WHERE f.doc_type='entity' AND kb_fts MATCH ?
                             AND e.status='active'
                           LIMIT 5""",
                        (query,),
                    )).fetchall()
                    known = {r["id"] for _, r in scored}
                    scored.extend((3, r) for r in hits if r["id"] not in known)
                except Exception:
                    pass

    scored.sort(key=lambda x: -x[0])
    return [row for _, row in scored[:3]]


async def _lookup_entity_context(db_path: str, name: str, now: datetime) -> str:
    async with aiosqlite.connect(db_path) as db:
        db.row_factory = aiosqlite.Row
        row = await find_entity_by_name(db, name)
        if not row:
            return "未找到实体"
        items = await (await db.execute(
            """SELECT id, title, summary, action_hint, expires_at
               FROM chaoxing_memory_entries
               WHERE entity_id=? AND archived_at IS NULL
                 AND COALESCE(status, 'active')='active'
               ORDER BY expires_at ASC LIMIT 20""",
            (row["id"],),
        )).fetchall()
    parts = [f"{row['id']} {row['etype']} {row['name']} {row['attrs']} {row['notes']}"]
    parts.extend(f"item {i['id']} due={i['expires_at']} {i['title']} {i['action_hint'] or i['summary']}" for i in items)
    return "\n".join(parts)


async def _call_model(provider: dict, model: str, api_key: str, now: datetime, context: str,
                      msg: dict, db_path: str, sibling_messages: list[dict] | None = None) -> str:
    from app.services.agent_service import AgentMsg, agent_complete

    siblings = ""
    if sibling_messages:
        lines = []
        for s in sibling_messages[-6:]:
            lines.append(f"- {s.get('sender_name') or '?'}: {(s.get('text') or '')[:200]}")
        siblings = "\n同会话邻近消息（同一话题，请合并判断，避免重复建条目）:\n" + "\n".join(lines)

    user = f"""上下文包:
{context}
{siblings}

待处理消息:
{(msg.get('text') or '')[:800]}"""
    response = await agent_complete(
        [
            AgentMsg(role="system", content=SYSTEM_PROMPT),
            AgentMsg(role="user", content=user),
        ],
        [],
        provider,
        model,
        api_key,
    )
    if response.usage:
        try:
            from app.services.budget import log_usage

            await log_usage(db_path, "reconciler", provider.get("id", ""), model, response.usage, now)
        except Exception:
            pass
    return response.text or ""


def _validate_ops(ops: list, ctx: dict, now: datetime) -> tuple[list[dict], list[str]]:
    valid: list[dict] = []
    warnings: list[str] = []
    item_ids = set(ctx.get("item_ids") or set())
    course_ids = set(ctx.get("course_ids") or set())
    entity_ids = set(ctx.get("entity_ids") or set())

    for op in ops:
        if not isinstance(op, dict):
            continue
        name = op.get("op")
        if name in {"update_item", "cancel_item"}:
            if op.get("id") not in item_ids:
                warnings.append(f"discarded {name}: id not in context")
                continue
            if name == "update_item":
                due = _parse_dt(op.get("due"))
                if not due or due < now - timedelta(hours=1):
                    warnings.append("discarded update_item: invalid due")
                    continue
        elif name == "cancel_course_rows":
            ids = [i for i in op.get("ids", []) if i in course_ids]
            if not ids:
                warnings.append("discarded cancel_course_rows: no ids in context")
                continue
            op = {**op, "ids": ids}
        elif name == "new_item":
            due_raw = op.get("due")
            if due_raw:
                due = _parse_dt(due_raw)
                if not due or due < now - timedelta(hours=1):
                    warnings.append("discarded new_item: invalid due")
                    continue
            ent = str(op.get("entity") or "")
            if ent.startswith("ent_") and ent not in entity_ids:
                warnings.append("discarded new_item: entity id not in context")
                continue
        elif name == "new_fact":
            ent = op.get("entity")
            if ent and ent not in entity_ids:
                warnings.append("discarded new_fact: entity id not in context")
                continue
        elif name == "push_now":
            ref = op.get("ref_item")
            if not ref or ref not in item_ids:
                warnings.append("discarded push_now: ref_item not in context")
                continue
        elif name != "conflict":
            warnings.append(f"discarded unknown op: {name}")
            continue
        valid.append(op)
    return valid, warnings


async def _execute_ops(ops: list[dict], db_path: str, msg: dict, now: datetime, ctx: dict) -> ReconcileResult:
    result = ReconcileResult()
    repo = MemoryRepository(db_path)
    now_iso = now.isoformat()

    for op in ops:
        try:
            name = op.get("op")
            audit_summary = ""
            if name == "new_item":
                entity_id = await _resolve_entity_for_op(db_path, op, msg, now_iso)
                kind = _normalize_kind(op.get("kind"))
                due = _parse_dt(op.get("due"))
                importance = _importance_text(op.get("importance"))
                title = str(op.get("title") or "消息").strip()[:120]
                body = str(op.get("note") or op.get("summary") or title).strip()
                source_type = msg.get("source_type") or "message"
                conversation = msg.get("conversation_title") or ""
                memory_kind = kind if kind in {"assignment", "exam", "reminder"} else "message"
                dedupe_kind = memory_kind if memory_kind in {"assignment", "exam", "reminder"} else "message"
                dedupe_key = canonical_dedupe_key(
                    dedupe_kind,
                    course=conversation,
                    title=title,
                )
                entry = MemoryEntry(
                    title=title,
                    summary=body,
                    reason="reconciler",
                    importance=importance,
                    action_hint=body,
                    category=kind,
                    kind=memory_kind,
                    source_type=source_type,
                    expires_at=due,
                    hierarchy_tier=compute_tier(importance, due, due is not None, now),
                    for_automation=due is not None or importance == "high",
                    dedupe_key=dedupe_key,
                    source_ids=[str(msg.get("mid") or "")] if msg.get("mid") else [],
                    conversation_names=[conversation] if conversation else [],
                    sender_names=[msg.get("sender_name")] if msg.get("sender_name") else [],
                    confidence=0.85,
                )
                eid = await repo.upsert_entry(entry, now)
                async with aiosqlite.connect(db_path) as db:
                    await db.execute(
                        "UPDATE chaoxing_memory_entries SET entity_id=?, raw_ref=COALESCE(raw_ref, ?) WHERE id=?",
                        (entity_id, msg.get("mid"), eid),
                    )
                    await sync_item_fts(db, eid)
                    await db.commit()
                result.memory_upserted.append(eid)
                result.effects_applied += 1
                audit_summary = f"memory_upserted:{eid}"

            elif name == "update_item":
                due = _parse_dt(op.get("due"))
                if not due:
                    continue
                item_id = op["id"]
                note = str(op.get("note") or "").strip()
                async with aiosqlite.connect(db_path) as db:
                    await db.execute(
                        """UPDATE chaoxing_memory_entries
                           SET expires_at=?, action_hint=COALESCE(NULLIF(?, ''), action_hint),
                               updated_at=?, status='active', archived_at=NULL
                           WHERE id=?""",
                        (due.isoformat(), note, now_iso, item_id),
                    )
                    await sync_item_fts(db, item_id)
                    await db.commit()
                from app.services.ladder import schedule_ladder_for_items

                await schedule_ladder_for_items(db_path, [item_id], now, replace=True)
                from app.memory.dispatch import notify_now

                await notify_now(db_path, "事项已更新", note or "截止时间已更新", item_id=item_id, notif_type="item_update")
                result.effects_applied += 1
                audit_summary = f"item_updated:{item_id}"

            elif name == "cancel_item":
                item_id = op["id"]
                async with aiosqlite.connect(db_path) as db:
                    await db.execute(
                        """UPDATE chaoxing_memory_entries
                           SET status='superseded', archived_at=COALESCE(archived_at, ?), updated_at=?
                           WHERE id=?""",
                        (now_iso, now_iso, item_id),
                    )
                    await sync_item_fts(db, item_id)
                    await db.commit()
                from app.services.ladder import cancel_ladder_for_item
                from app.memory.dispatch import notify_now

                await cancel_ladder_for_item(db_path, item_id)
                await notify_now(db_path, "事项已取消", str(op.get("scope_note") or "已撤销提醒"), item_id=item_id, notif_type="item_cancel")
                result.memory_archived.append(item_id)
                result.effects_applied += 1
                audit_summary = f"item_cancelled:{item_id}"

            elif name == "cancel_course_rows":
                ids = op.get("ids") or []
                async with aiosqlite.connect(db_path) as db:
                    for cid in ids:
                        await db.execute(
                            """UPDATE server_courses
                               SET notes=TRIM(COALESCE(notes, '') || ' cancelled_by_reconciler ' || ?),
                                   updated_at=?
                               WHERE id=?""",
                            (now_iso, now_iso, cid),
                        )
                    await db.commit()
                from app.memory.dispatch import notify_now

                await notify_now(db_path, "课程取消", "相关课程行已标记取消", item_id="course-" + "-".join(ids), notif_type="course_cancel")
                result.effects_applied += len(ids)
                audit_summary = f"course_rows_cancelled:{len(ids)}"

            elif name == "new_fact":
                async with aiosqlite.connect(db_path) as db:
                    fid = await create_fact(
                        db,
                        entity_id=op.get("entity"),
                        text=str(op.get("text") or "")[:200],
                        source="distilled",
                        confidence=0.75,
                        now=now_iso,
                    )
                    await db.commit()
                result.facts_created.append(fid)
                result.effects_applied += 1
                audit_summary = f"fact_created:{fid}"

            elif name == "push_now":
                from app.memory.dispatch import notify_now

                await notify_now(
                    db_path,
                    str(op.get("title") or "提醒")[:18],
                    str(op.get("body") or "")[:80],
                    item_id=op.get("ref_item"),
                    notif_type="reconciler",
                )
                result.push_scheduled += 1
                result.effects_applied += 1
                audit_summary = "push_now"

            elif name == "conflict":
                from app.memory.dispatch import notify_now

                await notify_now(
                    db_path,
                    "需要确认",
                    str(op.get("question") or "有一条消息需要你确认")[:80],
                    notif_type="conflict",
                    data={"type": "conflict", "a": op.get("a"), "b": op.get("b")},
                )
                result.push_scheduled += 1
                result.effects_applied += 1
                audit_summary = "conflict_push"
            if audit_summary:
                await _audit_op(db_path, msg, name or "unknown", op, audit_summary, now_iso)
        except Exception as e:
            logger.warning("Reconciler op failed: %s op=%s", e, op)
            result.errors.append(str(e))

    result.ok = not result.errors
    return result


async def _audit_op(db_path: str, msg: dict, tool_name: str, op: dict, summary: str, now_iso: str) -> None:
    import uuid

    conversation_id = (
        str(msg.get("conversation_id") or msg.get("cid") or msg.get("conversation_title") or msg.get("mid") or "")
    )
    async with aiosqlite.connect(db_path) as db:
        await db.execute(
            """INSERT INTO agent_audit_log
               (id, conversation_id, tool_name, sql_or_op, result_summary, created_at)
               VALUES (?,?,?,?,?,?)""",
            (
                f"audit_{uuid.uuid4().hex[:12]}",
                conversation_id,
                tool_name,
                json.dumps(op, ensure_ascii=False)[:2000],
                summary[:500],
                now_iso,
            ),
        )
        await db.commit()


_ENTITY_NAME_MAX = 60
# Characters that never appear in legitimate course/project names but do show
# up when the model echoes prompt-injection text back as an entity name.
_ENTITY_NAME_SANITIZE_RE = None  # compiled lazily


def _sanitize_entity_name(raw: str) -> str:
    import re

    # Strip SQL-ish punctuation fragments; injection itself is already dead
    # (parameterized queries) — this just keeps the entity directory readable.
    name = re.sub(r"[;'\")\-]{1,2}|/\*|\*/", "", raw)
    name = re.sub(r"\s+", " ", name).strip()
    return name[:_ENTITY_NAME_MAX]


async def _resolve_entity_for_op(db_path: str, op: dict, msg: dict, now_iso: str) -> str | None:
    ent = str(op.get("entity") or "").strip()
    async with aiosqlite.connect(db_path) as db:
        db.row_factory = aiosqlite.Row
        if ent.startswith("ent_"):
            row = await (await db.execute("SELECT id FROM entities WHERE id=? AND status='active'", (ent,))).fetchone()
            return row["id"] if row else None
        if ent.startswith("new:"):
            name = _sanitize_entity_name(ent[4:].strip())
        else:
            name = _sanitize_entity_name(msg.get("conversation_title") or ent or "未分类")
        if not name:
            name = "未分类"
        etype = "course" if (msg.get("conversation_title") or op.get("kind") in {"assignment", "exam", "course_change"}) else "project"
        eid = await upsert_entity(db, etype=etype, name=name, aliases=[], attrs={}, now=now_iso)
        await sync_entity_fts(db, eid)
        await db.commit()
        return eid


def _parse_json(text: str) -> dict:
    body = (text or "").strip()
    if body.startswith("```"):
        body = body.split("\n", 1)[1] if "\n" in body else body
        body = body.rsplit("```", 1)[0].strip()
        if body.startswith("json"):
            body = body[4:].strip()
    s, e = body.find("{"), body.rfind("}")
    if s >= 0 and e > s:
        body = body[s:e + 1]
    try:
        parsed = json.loads(body)
    except Exception:
        return {"ops": [], "need_more": False}
    return parsed if isinstance(parsed, dict) else {"ops": [], "need_more": False}


def _parse_dt(value: str | None) -> datetime | None:
    if not value or value == "null":
        return None
    try:
        dt = datetime.fromisoformat(str(value).replace("Z", "+00:00"))
    except Exception:
        return None
    if dt.tzinfo is None:
        dt = dt.replace(tzinfo=timezone.utc)
    return dt.astimezone(timezone.utc)


def _normalize_kind(value: str | None) -> str:
    raw = (value or "notice").strip().lower()
    return raw if raw in {"assignment", "exam", "course_change", "notice", "signup"} else "notice"


def _importance_text(value: Any) -> str:
    if isinstance(value, (int, float)):
        return "high" if value >= 2 else "medium"
    raw = str(value or "").strip().lower()
    if raw in {"high", "urgent", "2", "3"}:
        return "high"
    if raw in {"low", "0"}:
        return "low"
    return "medium"


def _loads_list(raw: str | None) -> list[str]:
    try:
        data = json.loads(raw or "[]")
    except Exception:
        return []
    return [str(v) for v in data if str(v or "").strip()] if isinstance(data, list) else []


def _fts_query(text: str) -> str:
    words = []
    for token in (text or "").replace('"', " ").split():
        token = token.strip("，。！？、,.!?;:()[]{}<>")
        if len(token) >= 2:
            words.append(token[:20])
    return " OR ".join(words[:8])
