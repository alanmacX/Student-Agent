"""app/memory/engine.py — Universal Automation Engine

Architecture
────────────
Message (any source)
  → Context Builder     : compressed schedule + memory snapshot (SQL, 0 LLM)
  → User Context Loader : free-form user constraints from settings
  → IntentExtractor     : 1 cheap LLM call → IntentGraph (intents + effects)
  → Parallel Sub-Agents : asyncio.gather, each validates + enriches 1 intent
  → Effect Merger       : dedup, batch push, resolve conflicts
  → Effect Executor     : generic SQL transaction
  → Side-effects        : topic_index update, scheduled_notifications writes

Adding a new source module
──────────────────────────
1.  Normalise your raw data into the standard `Message` dict (see `NormalisedMessage`)
2.  Call `process_message(msg, db_path, provider, model, api_key)`
3.  That's it.  No scenario-specific code needed.
"""
from __future__ import annotations

import asyncio
import json
import logging
import uuid
from dataclasses import dataclass, field
from datetime import datetime, timedelta, timezone
from enum import Enum
from typing import Any

import aiosqlite

logger = logging.getLogger("memory.engine")

# ── Standard message shape (source-agnostic) ──────────────────────────────────
NormalisedMessage = dict  # keys: mid, text, sender_name, conversation_title,
                           #        is_group, source_type, created_at (ms), category

# ── Effect types ──────────────────────────────────────────────────────────────
class EffectType(str, Enum):
    UPSERT_MEMORY   = "upsert_memory"    # create or update a memory entry
    ARCHIVE_MEMORY  = "archive_memory"   # soft-delete matching memory entries
    PUSH_NOW        = "push_now"         # immediate push notification
    SCHEDULE_PUSH   = "schedule_push"    # time-deferred push → scheduled_notifications
    LINK_ENTRIES    = "link_entries"     # cross-ref two memory entries


@dataclass
class Effect:
    type: EffectType
    params: dict[str, Any]
    intent_id: str = ""
    priority: int = 0   # higher = applied first within same transaction


@dataclass
class IntentGraph:
    intents: list[dict[str, Any]] = field(default_factory=list)
    # Each intent:
    # { id, type, entity_type, entity_name, confidence, effects: [Effect], raw_params }


@dataclass
class ExecutionResult:
    ok: bool
    effects_applied: int = 0
    memory_upserted: list[str] = field(default_factory=list)
    memory_archived: list[str] = field(default_factory=list)
    push_scheduled: int = 0
    errors: list[str] = field(default_factory=list)


# ── Context builder ───────────────────────────────────────────────────────────

async def _build_context(msg: NormalisedMessage, db_path: str, now: datetime) -> str:
    """Compressed context fed to the LLM. SQL only, ~200 tokens."""
    lines: list[str] = []
    now_str = now.astimezone(timezone(timedelta(hours=8))).strftime("%Y-%m-%d %H:%M %a")
    lines.append(f"当前时间: {now_str}")

    async with aiosqlite.connect(db_path) as db:
        db.row_factory = aiosqlite.Row

        # Upcoming 14-day courses (compact)
        horizon = (now + timedelta(days=14)).isoformat()
        courses = await (await db.execute(
            """SELECT title, start_at, end_at, location, notes
               FROM server_courses
               WHERE end_at >= ? AND start_at <= ?
               ORDER BY start_at ASC LIMIT 20""",
            (now.isoformat(), horizon),
        )).fetchall()
        if courses:
            from zoneinfo import ZoneInfo
            tz8 = ZoneInfo("Asia/Shanghai")
            def fmt(s):
                try:
                    from datetime import datetime as dt
                    return dt.fromisoformat(s.replace("Z", "+00:00")).astimezone(tz8).strftime("%m-%d %H:%M")
                except Exception:
                    return s or "?"
            lines.append("近期课程: " + " | ".join(
                f"{r['title']}({fmt(r['start_at'])}{' '+r['location'] if r['location'] else ''}"
                f"{' [已调整]' if r['notes'] and 'cancel' in (r['notes'] or '').lower() else ''})"
                for r in courses
            ))

        # Active tier-0/1 memory entries (most urgent)
        urgent = await (await db.execute(
            """SELECT title, action_hint, source_type, hierarchy_tier, expires_at
               FROM chaoxing_memory_entries
               WHERE hierarchy_tier <= 1 AND archived_at IS NULL
                 AND (expires_at IS NULL OR expires_at > ?)
               ORDER BY hierarchy_tier ASC, expires_at ASC LIMIT 6""",
            (now.isoformat(),),
        )).fetchall()
        if urgent:
            lines.append("紧急记忆: " + " | ".join(
                f"[{r['source_type']}]{r['title']}"
                f"{': '+r['action_hint'] if r['action_hint'] else ''}"
                for r in urgent
            ))

        # Entity name if there's a topic_index hit for message text
        text_sample = (msg.get("text") or "")[:100]
        if text_sample:
            topic_hits = await (await db.execute(
                """SELECT DISTINCT m.title, m.kind, m.source_type
                   FROM memory_topic_index t
                   JOIN chaoxing_memory_entries m ON m.id = t.memory_id
                   WHERE m.archived_at IS NULL
                     AND length(t.entity_key) >= 4
                     AND ? LIKE '%'||t.entity_key||'%'
                   LIMIT 5""",
                (text_sample,),
            )).fetchall()
            if topic_hits:
                lines.append("相关条目: " + " | ".join(
                    f"{r['title']}({r['kind']}/{r['source_type']})" for r in topic_hits
                ))

    return "\n".join(lines)


# ── User context loader ───────────────────────────────────────────────────────

async def _load_user_context(db_path: str) -> str:
    async with aiosqlite.connect(db_path) as db:
        row = await (await db.execute(
            "SELECT value FROM settings WHERE key='user_automation_context'"
        )).fetchone()
    return str(row[0]) if row else ""


# ── Intent extractor ──────────────────────────────────────────────────────────

_INTENT_SYSTEM = """你是一个自动化引擎的意图提取器。分析消息，结合当前系统状态，输出结构化 IntentGraph。

你的职责：
1. 识别消息中的所有意图（一条消息可以有多个）
2. 解析时间引用（"明天"→具体日期、"下周三"→日期、"第3-4节"→具体时间段）
3. 检测冲突（新意图与已有课程/提醒是否冲突）
4. 为每个意图生成精确的 Effect 列表

Effect 类型说明：
- upsert_memory: 新建或更新记忆条目
  params: {title, summary, action_hint, importance(high/medium/low),
           entity_key(索引键), expires_iso, for_automation(bool), category}
  ⚠️ expires_iso 规则（务必遵守）：
    · 有明确截止/考试/上课时间的事项 → expires_iso 必须**等于那个真实时间**，
      不要往后留缓冲、不要凑整到周末或月底。截止过了条目就该自然失效。
    · 没有明确时间的一般通知/背景信息 → expires_iso 留空或给一个**近期**
      （最多 3 天）的值，不要给两周后这种远期，否则会被反复当作待办推送。
    · 已经过去的事（截止时间早于当前时间）→ 不要 for_automation，expires_iso
      就设成那个已过去的时间（让它立即失效），不要续命。
- archive_memory: 软删除匹配的记忆条目
  params: {entity_key, reason}
- push_now: 立即推送
  params: {title, body}
- schedule_push: 定时推送
  params: {title, body, trigger_iso}
- link_entries: 关联两条记忆
  params: {entity_key_a, entity_key_b, relation}

置信度低于 0.7 的意图不要输出。
对于纯聊天/表情/无实质内容，输出 {"intents":[]}。

输出纯 JSON，不要 markdown 代码块：
{
  "intents": [
    {
      "id": "intent_0",
      "type": "course_change|deadline_change|new_notice|cancellation|general_info",
      "entity_type": "course|assignment|reminder|general",
      "entity_name": "规范化实体名",
      "confidence": 0.95,
      "conflict_detected": false,
      "conflict_note": "",
      "effects": [
        {"type": "effect类型", "params": {...}, "priority": 10}
      ]
    }
  ]
}"""


async def _extract_intents(
    msg: NormalisedMessage,
    context: str,
    user_ctx: str,
    provider: dict,
    model: str,
    api_key: str,
    now: datetime,
) -> IntentGraph:
    from app.services.agent_service import AgentMsg, agent_complete

    user_section = f"\n用户背景约束:\n{user_ctx}" if user_ctx.strip() else ""
    user_msg = f"""系统状态:
{context}{user_section}

待分析消息:
来源: {msg.get('source_type','?')}
发送人: {msg.get('sender_name','?')}
会话: {msg.get('conversation_title','私聊')}
内容: {(msg.get('text') or '')[:500]}"""

    try:
        resp = await agent_complete(
            [AgentMsg(role="system", content=_INTENT_SYSTEM),
             AgentMsg(role="user", content=user_msg)],
            [], provider, model, api_key,
        )
        raw = (resp.text or "").strip()
        s, e = raw.find("{"), raw.rfind("}")
        if s == -1:
            return IntentGraph()
        data = json.loads(raw[s:e+1])
        intents_raw = data.get("intents") or []
        graph = IntentGraph()
        for it in intents_raw:
            if not isinstance(it, dict):
                continue
            conf = float(it.get("confidence") or 0)
            if conf < 0.7:
                continue
            # Parse effects into Effect objects
            effects = []
            for ef in (it.get("effects") or []):
                try:
                    effects.append(Effect(
                        type=EffectType(ef["type"]),
                        params=ef.get("params") or {},
                        intent_id=it.get("id", ""),
                        priority=int(ef.get("priority") or 0),
                    ))
                except (KeyError, ValueError):
                    pass
            graph.intents.append({**it, "effects": effects})
        return graph
    except Exception as e:
        logger.warning("Intent extraction failed: %s", e)
        return IntentGraph()


# ── Sub-agent: validate + enrich one intent ────────────────────────────────────

async def _plan_intent(intent: dict, db_path: str, now: datetime) -> list[Effect]:
    """
    Lightweight sub-agent (pure SQL, no LLM).
    Validates entity existence, checks time conflicts, enriches effect params.
    Returns the (possibly modified) effect list for this intent.
    """
    entity_name = intent.get("entity_name") or ""
    entity_type = intent.get("entity_type") or ""
    effects: list[Effect] = list(intent.get("effects") or [])

    # Carry the intent's identity onto each effect so the executor can build a
    # canonical, cross-source dedupe key (see _execute_effects).
    for ef in effects:
        if entity_type:
            ef.params.setdefault("entity_type", entity_type)
        if entity_name:
            ef.params.setdefault("entity_name", entity_name)

    if not entity_name:
        return effects

    async with aiosqlite.connect(db_path) as db:
        db.row_factory = aiosqlite.Row

        # Resolve actual memory_id for archive effects
        if entity_name:
            hits = await (await db.execute(
                """SELECT DISTINCT t.memory_id, m.title
                   FROM memory_topic_index t
                   JOIN chaoxing_memory_entries m ON m.id = t.memory_id
                   WHERE t.entity_key = ? AND m.archived_at IS NULL""",
                (_normalise_key(entity_name),),
            )).fetchall()
            matched_ids = [r["memory_id"] for r in hits]
        else:
            matched_ids = []

        # Enrich archive_memory effects with resolved IDs
        for ef in effects:
            if ef.type == EffectType.ARCHIVE_MEMORY and matched_ids:
                ef.params.setdefault("resolved_ids", matched_ids)

        # Detect schedule conflicts for course-related intents
        if entity_type == "course":
            for ef in effects:
                if ef.type == EffectType.UPSERT_MEMORY:
                    trigger = ef.params.get("expires_iso") or ef.params.get("trigger_iso")
                    if trigger:
                        conflict = await (await db.execute(
                            """SELECT title FROM server_courses
                               WHERE start_at <= ? AND end_at >= ?
                               LIMIT 1""",
                            (trigger, trigger),
                        )).fetchone()
                        if conflict and conflict["title"] != entity_name:
                            ef.params["conflict_warning"] = f"时间冲突: {conflict['title']}"

    return effects


# ── Effect merger ─────────────────────────────────────────────────────────────

def _merge_effects(plans: list[list[Effect]]) -> list[Effect]:
    """Flatten, deduplicate by (type, entity_key), batch push notifications."""
    flat: list[Effect] = []
    for plan in plans:
        flat.extend(plan)

    # Sort by priority descending
    flat.sort(key=lambda e: -e.priority)

    # Deduplicate: same type + same entity_key → keep higher priority
    seen: dict[tuple, Effect] = {}
    for ef in flat:
        key = (ef.type, ef.params.get("entity_key", ""), ef.params.get("trigger_iso", ""))
        if key not in seen:
            seen[key] = ef

    # Batch same-time push_now into single notification
    push_nows = [e for e in seen.values() if e.type == EffectType.PUSH_NOW]
    others = [e for e in seen.values() if e.type != EffectType.PUSH_NOW]

    if len(push_nows) > 1:
        # Merge into single notification
        titles = [e.params.get("title", "") for e in push_nows]
        bodies = [e.params.get("body", "") for e in push_nows]
        # Preserve a stable identity: combine the source entity_keys so the
        # merged push gets a deterministic item_id (dedup survives reprocessing)
        # instead of falling back to a content hash that changes if wording does.
        keys = [e.params.get("entity_key") or e.params.get("dedupe_key") for e in push_nows]
        merged_key = "+".join(sorted(k for k in keys if k)) or None
        merged_push = Effect(
            type=EffectType.PUSH_NOW,
            params={
                "title": titles[0],
                "body": " | ".join(b for b in bodies if b),
                **({"entity_key": merged_key} if merged_key else {}),
            },
            priority=max(e.priority for e in push_nows),
        )
        return others + [merged_push]
    return others + push_nows


# ── Generic effect executor ───────────────────────────────────────────────────

async def _execute_effects(
    effects: list[Effect],
    db_path: str,
    now: datetime,
    msg: NormalisedMessage | None = None,
) -> ExecutionResult:
    result = ExecutionResult(ok=True)
    from app.memory.base import MemoryRepository, MemoryEntry, compute_tier, Tier
    from app.memory.keys import canonical_dedupe_key, kind_from_entity_type

    repo = MemoryRepository(db_path)
    msg = msg or {}
    msg_source = msg.get("source_type") or "automation"
    msg_conversation = msg.get("conversation_title") or ""

    for ef in effects:
        try:
            if ef.type == EffectType.UPSERT_MEMORY:
                p = ef.params
                importance = p.get("importance") or "medium"
                for_auto = bool(p.get("for_automation"))
                expires_at = _parse_iso_or_none(p.get("expires_iso"))
                tier = compute_tier(importance, expires_at, for_auto, now)

                # Resolve the entity kind from the intent so known kinds
                # (assignment/course/reminder) get a *canonical* dedupe key that
                # matches the structured sync — instead of a free-form LLM key
                # that would create a cross-source duplicate.
                kind = kind_from_entity_type(p.get("entity_type"))
                entity_name = p.get("entity_name") or p.get("title") or "消息"
                if kind != "message":
                    dedupe_key = canonical_dedupe_key(
                        kind, course=msg_conversation, title=entity_name,
                        start=p.get("expires_iso") or "",
                    )
                else:
                    dedupe_key = p.get("dedupe_key") or p.get("entity_key") or ""

                entry = MemoryEntry(
                    title=p.get("title") or entity_name,
                    summary=p.get("summary") or p.get("title") or "",
                    reason=p.get("reason") or "automation engine",
                    importance=importance,
                    action_hint=p.get("action_hint") or "",
                    category=p.get("category") or "notice",
                    kind=kind,
                    source_type=p.get("source_type") or msg_source,
                    expires_at=expires_at,
                    hierarchy_tier=tier,
                    for_automation=for_auto,
                    dedupe_key=dedupe_key,
                    conversation_names=[msg_conversation] if msg_conversation else [],
                    confidence=float(p.get("confidence") or 0.8),
                )
                eid = await repo.upsert_entry(entry, now)
                result.memory_upserted.append(eid)

                # Maintain topic_index
                if p.get("entity_key"):
                    await _update_topic_index(db_path, eid, p["entity_key"],
                                               p.get("entity_type") or "general",
                                               p.get("source_type") or "automation",
                                               expires_at)

            elif ef.type == EffectType.ARCHIVE_MEMORY:
                ids = ef.params.get("resolved_ids") or []
                async with aiosqlite.connect(db_path) as db:
                    for mid in ids:
                        await db.execute(
                            "UPDATE chaoxing_memory_entries SET archived_at=? WHERE id=?",
                            (now.isoformat(), mid),
                        )
                    await db.commit()
                result.memory_archived.extend(ids)

            elif ef.type == EffectType.PUSH_NOW:
                # Route through the unified dispatcher so it's deduped (won't
                # re-fire on reprocessing) and recorded in notification_log.
                from app.memory.dispatch import notify_now
                p = ef.params
                title = p.get("title") or "通知"
                body = p.get("body") or ""
                await notify_now(
                    db_path, title, body,
                    item_id=p.get("entity_key") or p.get("dedupe_key") or None,
                    notif_type="automation",
                    data={"type": "automation"},
                )
                result.push_scheduled += 1

            elif ef.type == EffectType.SCHEDULE_PUSH:
                # Deterministic id (idempotent) via the dispatcher — the old
                # random-uuid INSERT OR IGNORE never actually deduped.
                from app.memory.dispatch import schedule_push
                p = ef.params
                trigger_iso = p.get("trigger_iso")
                if not trigger_iso:
                    continue
                await schedule_push(
                    db_path,
                    p.get("title") or "提醒",
                    p.get("body") or "",
                    trigger_iso,
                    source_type="automation_engine",
                    source_id=p.get("entity_key") or p.get("dedupe_key") or None,
                    reason=p.get("reason") or "memory automation",
                    now=now,
                )
                result.push_scheduled += 1

            elif ef.type == EffectType.LINK_ENTRIES:
                # Cross-reference two memory entries via related_ids_json
                p = ef.params
                async with aiosqlite.connect(db_path) as db:
                    db.row_factory = aiosqlite.Row
                    for key in (p.get("entity_key_a"), p.get("entity_key_b")):
                        if key:
                            hits = await (await db.execute(
                                """SELECT memory_id FROM memory_topic_index
                                   WHERE entity_key=? LIMIT 1""", (key,),
                            )).fetchall()
                            _ = [r["memory_id"] for r in hits]  # store for future cross-ref
                    await db.commit()

            result.effects_applied += 1

        except Exception as e:
            logger.warning("Effect %s failed: %s", ef.type, e)
            result.errors.append(f"{ef.type}: {e}")

    return result


# ── Topic index management ────────────────────────────────────────────────────

async def _update_topic_index(
    db_path: str,
    memory_id: str,
    entity_name: str,
    entity_type: str,
    source_type: str,
    expires_at: datetime | None,
) -> None:
    """Write all key variants for this entity to topic_index."""
    keys = _expand_entity_keys(entity_name)
    expires_iso = expires_at.isoformat() if expires_at else None
    async with aiosqlite.connect(db_path) as db:
        for key in keys:
            await db.execute(
                """INSERT OR REPLACE INTO memory_topic_index
                   (entity_key, entity_type, memory_id, source_type, expires_at)
                   VALUES (?,?,?,?,?)""",
                (key, entity_type, memory_id, source_type, expires_iso),
            )
        await db.commit()


def _normalise_key(text: str) -> str:
    import re, unicodedata
    t = text.lower().strip()
    t = unicodedata.normalize("NFKC", t)
    t = re.sub(r"[\s\-_·•·]", "", t)
    return t[:40]


def _expand_entity_keys(name: str) -> list[str]:
    """Generate index keys for fuzzy matching.

    Deliberately does NOT emit 2-char bigrams: those matched almost any Chinese
    message in the LIKE-based context lookup and flooded "相关条目" with
    unrelated memories. Keep only high-signal keys — the full normalized name,
    each whole CJK chunk, and ASCII words.
    """
    keys: list[str] = []
    base = _normalise_key(name)
    if base:
        keys.append(base)
    import re
    cjk = re.findall(r'[一-鿿]+', name)
    for chunk in cjk:
        nk = _normalise_key(chunk)
        if len(nk) >= 2:
            keys.append(nk)
    # ASCII words 3+ chars
    ascii_words = re.findall(r'[a-zA-Z]{3,}', name)
    for w in ascii_words:
        keys.append(w.lower())
    return list(dict.fromkeys(k for k in keys if k))


def _parse_iso_or_none(value: str | None) -> datetime | None:
    if not value:
        return None
    try:
        dt = datetime.fromisoformat(value.replace("Z", "+00:00"))
        if dt.tzinfo is None:
            dt = dt.replace(tzinfo=timezone.utc)
        return dt
    except Exception:
        return None


# ── Main entry point ──────────────────────────────────────────────────────────

async def process_message(
    msg: NormalisedMessage,
    db_path: str,
    provider: dict,
    model: str,
    api_key: str,
    now: datetime | None = None,
) -> ExecutionResult:
    """
    Universal entry point.  Call this from any source module (DingTalk,
    Chaoxing, Ideas, etc.) with a normalised message dict.

    The caller does NOT need to know about intents, effects, or handlers.
    """
    if now is None:
        now = datetime.now(timezone.utc)

    text = (msg.get("text") or "").strip()
    if not text or len(text) < 5:
        return ExecutionResult(ok=True)

    # Skip pure noise early
    if _is_obvious_noise(text):
        logger.debug("Skipping obvious noise: %s", text[:40])
        return ExecutionResult(ok=True)

    # 1. Build compressed context
    context = await _build_context(msg, db_path, now)

    # 2. User automation constraints
    user_ctx = await _load_user_context(db_path)

    # 3. Intent extraction (1 LLM call)
    intent_graph = await _extract_intents(
        msg, context, user_ctx, provider, model, api_key, now
    )

    if not intent_graph.intents:
        logger.debug("No actionable intents extracted")
        return ExecutionResult(ok=True)

    logger.info("Extracted %d intents from %s message",
                len(intent_graph.intents), msg.get("source_type"))

    # 4. Parallel sub-agents (pure SQL, no LLM)
    effect_plans = await asyncio.gather(*[
        _plan_intent(intent, db_path, now)
        for intent in intent_graph.intents
    ], return_exceptions=True)

    valid_plans: list[list[Effect]] = []
    for plan in effect_plans:
        if isinstance(plan, Exception):
            logger.warning("Sub-agent failed: %s", plan)
        else:
            valid_plans.append(plan)

    # 5. Merge
    effects = _merge_effects(valid_plans)
    if not effects:
        return ExecutionResult(ok=True)

    # 6. Execute
    result = await _execute_effects(effects, db_path, now, msg)
    logger.info(
        "Automation: applied=%d upserted=%d archived=%d pushes=%d errors=%d",
        result.effects_applied, len(result.memory_upserted),
        len(result.memory_archived), result.push_scheduled, len(result.errors),
    )
    return result


def _is_obvious_noise(text: str) -> bool:
    import re
    # Remove brackets (emoji like [赞]), check length
    clean = re.sub(r'\[.*?\]', '', text).strip()
    if len(clean) < 5:
        return True
    NOISE = {"好的", "谢谢", "收到", "知道了", "ok", "嗯", "嗯嗯", "test",
              "好", "是的", "对", "明白", "晓得", "了解", "稍等", "好滴"}
    c = clean.strip().lower()
    if c in NOISE:
        return True
    # Doubled acknowledgements ("收到收到", "好的好的") are still pure noise.
    if len(c) % 2 == 0 and c[: len(c) // 2] == c[len(c) // 2:] and c[: len(c) // 2] in NOISE:
        return True
    return False
