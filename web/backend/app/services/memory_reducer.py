from __future__ import annotations
import json
import uuid
from datetime import datetime, timedelta, timezone

import aiosqlite

from .memory_models import display_text, key_text, normalize_importance, parse_iso, sha256_hex


def canonical_dedupe_key(item: dict, title: str, summary: str, messages: list[dict]) -> str:
    if item.get("dedupe_key"):
        return f"llm::{key_text(item['dedupe_key'])}"
    if item.get("linked_course_key"):
        return f"course::{key_text(item['linked_course_key'])}::{key_text(title)}"
    base = "|".join([
        item.get("category") or "notice",
        messages[0].get("conversation_name", "") if messages else "",
        title,
        summary,
    ])
    return f"event::{sha256_hex(key_text(base))}"


def default_expiry(item: dict, messages: list[dict], now: datetime) -> datetime:
    content_time = parse_iso(item.get("content_time"))
    if content_time and content_time > now:
        return content_time + timedelta(hours=12)
    sent_ats = [parse_iso(m.get("sent_at")) for m in messages if m.get("sent_at")]
    sent_ats = [dt for dt in sent_ats if dt]
    sent_at = max(sent_ats) if sent_ats else now
    return sent_at + timedelta(days=14)


async def reduce_memory(
    extracted: list[dict],
    candidate_messages: list[dict],
    assignment_keys: set[str],
    now: datetime,
    db_path: str,
) -> list[str]:
    if now.tzinfo is None:
        now = now.replace(tzinfo=timezone.utc)
    message_by_id = {m["source_id"]: m for m in candidate_messages}
    changed_ids: list[str] = []

    async with aiosqlite.connect(db_path) as db:
        db.row_factory = aiosqlite.Row
        for item in extracted:
            if (item.get("decision") or "").lower() != "keep":
                continue
            confidence = float(item.get("confidence") or 0.75)
            if confidence < 0.55:
                continue
            source_messages = [
                message_by_id[sid]
                for sid in (item.get("source_ids") or [])
                if sid in message_by_id
            ]
            if not source_messages:
                continue

            # Drop messages that purely duplicate a tracked assignment
            linked_assignment_key = item.get("linked_assignment_key")
            normalized_assignment_keys = {key_text(k) for k in assignment_keys}
            if linked_assignment_key and (
                linked_assignment_key in assignment_keys
                or key_text(linked_assignment_key) in normalized_assignment_keys
            ):
                continue

            importance = normalize_importance(item.get("importance"))
            if importance not in ("high", "medium"):
                continue
            summary = display_text(item.get("summary") or "")
            if not summary:
                continue
            title = display_text(
                item.get("title") or source_messages[0].get("conversation_name") or "学习通通知"
            )
            dedupe_key = canonical_dedupe_key(item, title, summary, source_messages)
            expires_at = parse_iso(item.get("expires_at")) or default_expiry(item, source_messages, now)
            if expires_at <= now:
                continue
            content_time = parse_iso(item.get("content_time"))

            existing = await (await db.execute(
                "SELECT * FROM chaoxing_memory_entries WHERE dedupe_key=?",
                (dedupe_key,),
            )).fetchone()
            if existing:
                entry_id = existing["id"]
                await _update_memory_entry(db, existing, item, source_messages, now, expires_at, confidence, title, summary, importance, content_time)
            else:
                entry_id = str(uuid.uuid4())
                await _insert_memory_entry(db, entry_id, dedupe_key, item, source_messages, now, expires_at, confidence, title, summary, importance, content_time)
            changed_ids.append(entry_id)

            # ── Interaction: propagate changes to linked entries ──────────────
            category = (item.get("category") or "").lower()
            action_hint = item.get("action_hint") or summary

            if category == "course_change":
                linked_course_key = item.get("linked_course_key") or ""
                await _propagate_course_change(db, entry_id, linked_course_key, title, action_hint, now)

            if linked_assignment_key and importance == "high":
                await _annotate_assignment_entry(db, entry_id, linked_assignment_key, action_hint, now)

        await _sweep_memory_conn(db, now)
        await db.commit()
    return changed_ids


async def _propagate_course_change(
    db, message_entry_id: str, linked_course_key: str, change_title: str, action_hint: str, now: datetime
) -> None:
    """
    When a course_change message is saved, find or create the affected course
    memory entry and mark it as changed. Cross-links both entries.
    """
    if not linked_course_key:
        return

    ck = key_text(linked_course_key)
    # Look for a course entry whose dedupe_key contains this key or whose title matches
    row = await (await db.execute(
        """SELECT id, related_ids_json FROM chaoxing_memory_entries
           WHERE kind='course' AND archived_at IS NULL
             AND (dedupe_key LIKE ? OR title LIKE ?)
           ORDER BY expires_at ASC LIMIT 1""",
        (f"course::{ck}%", f"%{linked_course_key}%"),
    )).fetchone()

    ni = now.isoformat()
    if row:
        course_id = row["id"]
        # Update the course entry: mark it changed, elevate importance
        await db.execute(
            """UPDATE chaoxing_memory_entries
               SET action_hint=?, importance='high', updated_at=?
               WHERE id=?""",
            (f"⚠️ {action_hint}", ni, course_id),
        )
    else:
        # Dynamically create a course entry from the change message
        course_id = str(uuid.uuid4())
        dk = f"course::{ck}"
        expires_at = now + timedelta(days=7)
        await db.execute(
            """INSERT OR IGNORE INTO chaoxing_memory_entries
               (id, title, summary, reason, action_hint, importance,
                sent_at, extracted_at, expires_at, dedupe_key, category,
                kind, confidence, source_ids_json, source_fingerprints_json,
                conversation_ids_json, conversation_names_json, sender_names_json,
                related_ids_json, created_at, updated_at)
               VALUES (?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?)""",
            (course_id, linked_course_key, change_title,
             "created from course_change message",
             f"⚠️ {action_hint}", "high", ni, ni,
             expires_at.isoformat(), dk, "course", "course", 0.9,
             "[]", "[]", "[]", "[]", "[]",
             json.dumps([message_entry_id], ensure_ascii=False), ni, ni),
        )

    # Cross-link: message → course
    if row:
        c_related = set(json.loads(row["related_ids_json"] or "[]"))
        c_related.add(message_entry_id)
        await db.execute(
            "UPDATE chaoxing_memory_entries SET related_ids_json=? WHERE id=?",
            (json.dumps(list(c_related), ensure_ascii=False), course_id),
        )

    m_row = await (await db.execute(
        "SELECT related_ids_json FROM chaoxing_memory_entries WHERE id=?", (message_entry_id,)
    )).fetchone()
    if m_row:
        m_related = set(json.loads(m_row["related_ids_json"] or "[]"))
        m_related.add(course_id)
        await db.execute(
            "UPDATE chaoxing_memory_entries SET related_ids_json=? WHERE id=?",
            (json.dumps(list(m_related), ensure_ascii=False), message_entry_id),
        )


async def _annotate_assignment_entry(
    db, message_entry_id: str, linked_assignment_key: str, hint: str, now: datetime
) -> None:
    """
    When a high-importance message references an assignment, update that
    assignment entry's action_hint with extra context and cross-link.
    """
    dk = f"assignment::{key_text(linked_assignment_key)}"
    row = await (await db.execute(
        "SELECT id, related_ids_json FROM chaoxing_memory_entries WHERE dedupe_key=? AND archived_at IS NULL",
        (dk,),
    )).fetchone()
    if not row:
        return

    ni = now.isoformat()
    await db.execute(
        "UPDATE chaoxing_memory_entries SET action_hint=?, importance='high', updated_at=? WHERE id=?",
        (hint, ni, row["id"]),
    )

    a_related = set(json.loads(row["related_ids_json"] or "[]"))
    a_related.add(message_entry_id)
    await db.execute(
        "UPDATE chaoxing_memory_entries SET related_ids_json=? WHERE id=?",
        (json.dumps(list(a_related), ensure_ascii=False), row["id"]),
    )

    m_row = await (await db.execute(
        "SELECT related_ids_json FROM chaoxing_memory_entries WHERE id=?", (message_entry_id,)
    )).fetchone()
    if m_row:
        m_related = set(json.loads(m_row["related_ids_json"] or "[]"))
        m_related.add(row["id"])
        await db.execute(
            "UPDATE chaoxing_memory_entries SET related_ids_json=? WHERE id=?",
            (json.dumps(list(m_related), ensure_ascii=False), message_entry_id),
        )


async def _insert_memory_entry(db, entry_id, dedupe_key, item, messages, now, expires_at, confidence, title, summary, importance, content_time):
    source_ids = [m["source_id"] for m in messages]
    fingerprints = [m["fingerprint"] for m in messages]
    conversation_ids = _ordered_unique([m.get("conversation_id") for m in messages])
    conversation_names = _ordered_unique([m.get("conversation_name") for m in messages])
    sender_names = _ordered_unique([m.get("sender_name") for m in messages if m.get("sender_name")])
    first = messages[0]
    now_iso = now.isoformat()
    await db.execute("""
        INSERT INTO chaoxing_memory_entries
        (id, source_message_id, conversation_id, conversation_name, sender_id, sender_name,
         title, summary, reason, action_hint, importance, sent_at, extracted_at, expires_at,
         source_text_preview, dedupe_key, category, confidence, content_time, created_at, updated_at,
         source_ids_json, source_fingerprints_json, conversation_ids_json, conversation_names_json,
         sender_names_json, linked_assignment_key, linked_course_key)
        VALUES (?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?)
    """, (
        entry_id, first.get("source_id"), first.get("conversation_id"), first.get("conversation_name"),
        first.get("sender_id"), first.get("sender_name"), title, summary, item.get("reason") or "",
        item.get("action_hint"), importance, first.get("sent_at") or now_iso, now_iso, expires_at.isoformat(),
        display_text(first.get("text") or "")[:200], dedupe_key, item.get("category") or "notice",
        confidence, content_time.isoformat() if content_time else None, now_iso, now_iso,
        json.dumps(source_ids, ensure_ascii=False), json.dumps(fingerprints, ensure_ascii=False),
        json.dumps(conversation_ids, ensure_ascii=False), json.dumps(conversation_names, ensure_ascii=False),
        json.dumps(sender_names, ensure_ascii=False), item.get("linked_assignment_key"), item.get("linked_course_key"),
    ))


async def _update_memory_entry(db, existing, item, messages, now, expires_at, confidence, title, summary, importance, content_time):
    source_ids = _merge_json_array(existing["source_ids_json"], [m["source_id"] for m in messages])
    fingerprints = _merge_json_array(existing["source_fingerprints_json"], [m["fingerprint"] for m in messages])
    conversation_ids = _merge_json_array(existing["conversation_ids_json"], [m.get("conversation_id") for m in messages])
    conversation_names = _merge_json_array(existing["conversation_names_json"], [m.get("conversation_name") for m in messages])
    sender_names = _merge_json_array(existing["sender_names_json"], [m.get("sender_name") for m in messages if m.get("sender_name")])
    existing_expires = parse_iso(existing["expires_at"])
    merged_expires = max(existing_expires or expires_at, expires_at)
    merged_confidence = max(float(existing["confidence"] or 0), confidence)
    await db.execute("""
        UPDATE chaoxing_memory_entries
        SET title=?, summary=?, reason=?, action_hint=?, importance=?, expires_at=?,
            category=?, confidence=?, content_time=COALESCE(?, content_time),
            source_ids_json=?, source_fingerprints_json=?, conversation_ids_json=?,
            conversation_names_json=?, sender_names_json=?, linked_assignment_key=COALESCE(?, linked_assignment_key),
            linked_course_key=COALESCE(?, linked_course_key), updated_at=?
        WHERE id=?
    """, (
        title, summary, item.get("reason") or "", item.get("action_hint"), importance,
        merged_expires.isoformat(), item.get("category") or existing["category"],
        merged_confidence, content_time.isoformat() if content_time else None,
        json.dumps(source_ids, ensure_ascii=False), json.dumps(fingerprints, ensure_ascii=False),
        json.dumps(conversation_ids, ensure_ascii=False), json.dumps(conversation_names, ensure_ascii=False),
        json.dumps(sender_names, ensure_ascii=False), item.get("linked_assignment_key"),
        item.get("linked_course_key"), now.isoformat(), existing["id"],
    ))


async def sweep_memory(db_path: str, now: datetime) -> None:
    async with aiosqlite.connect(db_path) as db:
        await _sweep_memory_conn(db, now)
        await db.commit()


async def _sweep_memory_conn(db, now: datetime) -> None:
    await db.execute("DELETE FROM chaoxing_memory_entries WHERE expires_at IS NOT NULL AND expires_at <= ?", (now.isoformat(),))
    row = await (await db.execute("SELECT COUNT(*) FROM chaoxing_memory_entries WHERE archived_at IS NULL")).fetchone()
    count = row[0] if row else 0
    if count > 100:
        await db.execute("""
            DELETE FROM chaoxing_memory_entries
            WHERE id IN (
                SELECT id FROM chaoxing_memory_entries
                WHERE archived_at IS NULL
                ORDER BY CASE importance WHEN 'high' THEN 3 WHEN 'medium' THEN 2 ELSE 1 END ASC,
                         COALESCE(updated_at, extracted_at, sent_at) ASC
                LIMIT ?
            )
        """, (count - 100,))


async def get_insights(db_path: str, now: datetime, limit: int = 40) -> list[dict]:
    async with aiosqlite.connect(db_path) as db:
        db.row_factory = aiosqlite.Row
        rows = await (await db.execute("""
            SELECT id, dedupe_key, title, summary, action_hint, importance,
                   COALESCE(content_time, updated_at, sent_at) AS sent_at, expires_at
            FROM chaoxing_memory_entries
            WHERE (expires_at IS NULL OR expires_at > ?) AND archived_at IS NULL
            ORDER BY CASE importance WHEN 'high' THEN 1 WHEN 'medium' THEN 2 ELSE 3 END,
                     COALESCE(content_time, updated_at, sent_at) ASC
            LIMIT ?
        """, (now.isoformat(), limit))).fetchall()
    return [dict(row) for row in rows]


def _ordered_unique(values) -> list:
    result = []
    seen = set()
    for value in values:
        if value is None or value in seen:
            continue
        seen.add(value)
        result.append(value)
    return result


def _merge_json_array(raw: str | None, additions: list) -> list:
    try:
        base = json.loads(raw or "[]")
    except Exception:
        base = []
    return _ordered_unique(list(base) + [v for v in additions if v is not None])
