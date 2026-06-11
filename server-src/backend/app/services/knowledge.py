"""Knowledge-base helpers for entities, facts, and compact FTS indexing."""
from __future__ import annotations

import json
import re
import uuid
from datetime import datetime, timezone
from typing import Any

import aiosqlite


def utc_now_iso() -> str:
    return datetime.now(timezone.utc).isoformat()


def new_id(prefix: str) -> str:
    return f"{prefix}_{uuid.uuid4().hex[:8]}"


def ngrams_for_index(text: str) -> str:
    chunks = re.findall(r"[\u4e00-\u9fff]{2,}", text or "")
    grams: list[str] = []
    for chunk in chunks:
        grams.extend(chunk[i:i + 2] for i in range(len(chunk) - 1))
    return " ".join(dict.fromkeys(grams))


def fts_content(*parts: Any) -> str:
    base = " ".join(str(p or "").strip() for p in parts if str(p or "").strip())
    grams = ngrams_for_index(base)
    return f"{base} {grams}".strip()


async def replace_fts_doc(db: aiosqlite.Connection, doc_id: str, doc_type: str, content: str) -> None:
    try:
        await db.execute("DELETE FROM kb_fts WHERE doc_id=? AND doc_type=?", (doc_id, doc_type))
        if content.strip():
            await db.execute(
                "INSERT INTO kb_fts (doc_id, doc_type, content) VALUES (?,?,?)",
                (doc_id, doc_type, fts_content(content)),
            )
    except Exception:
        # FTS5 may be unavailable in unusual SQLite builds; the core data path
        # must keep working and context lookup will fall back to LIKE scans.
        pass


async def sync_item_fts(db: aiosqlite.Connection, item_id: str) -> None:
    db.row_factory = aiosqlite.Row
    row = await (await db.execute(
        """SELECT id, title, summary, action_hint, reason, kind, category,
                  archived_at, status
           FROM chaoxing_memory_entries WHERE id=?""",
        (item_id,),
    )).fetchone()
    if not row:
        await replace_fts_doc(db, item_id, "item", "")
        return
    if row["archived_at"] or (row["status"] or "active") != "active":
        await replace_fts_doc(db, item_id, "item", "")
        return
    await replace_fts_doc(
        db,
        item_id,
        "item",
        f"{row['title']} {row['summary']} {row['action_hint']} {row['reason']} {row['kind']} {row['category']}",
    )


async def sync_entity_fts(db: aiosqlite.Connection, entity_id: str) -> None:
    db.row_factory = aiosqlite.Row
    row = await (await db.execute(
        "SELECT id, etype, name, aliases, attrs, notes, status FROM entities WHERE id=?",
        (entity_id,),
    )).fetchone()
    if not row or row["status"] != "active":
        await replace_fts_doc(db, entity_id, "entity", "")
        return
    await replace_fts_doc(
        db,
        entity_id,
        "entity",
        f"{row['etype']} {row['name']} {row['aliases']} {row['attrs']} {row['notes']}",
    )


async def sync_fact_fts(db: aiosqlite.Connection, fact_id: str) -> None:
    db.row_factory = aiosqlite.Row
    row = await (await db.execute(
        "SELECT id, text, source, archived_at FROM facts WHERE id=?",
        (fact_id,),
    )).fetchone()
    if not row or row["archived_at"]:
        await replace_fts_doc(db, fact_id, "fact", "")
        return
    await replace_fts_doc(db, fact_id, "fact", f"{row['text']} {row['source']}")


async def find_entity_by_name(
    db: aiosqlite.Connection,
    name: str,
    *,
    etype: str | None = None,
) -> aiosqlite.Row | None:
    db.row_factory = aiosqlite.Row
    target = (name or "").strip()
    if not target:
        return None
    params: list[Any] = [target]
    clause = "status='active' AND name=?"
    if etype:
        clause += " AND etype=?"
        params.append(etype)
    row = await (await db.execute(
        f"SELECT * FROM entities WHERE {clause} LIMIT 1",
        params,
    )).fetchone()
    if row:
        return row

    rows = await (await db.execute(
        "SELECT * FROM entities WHERE status='active' " + ("AND etype=? " if etype else "") + "LIMIT 200",
        ([etype] if etype else []),
    )).fetchall()
    for row in rows:
        aliases = _loads_list(row["aliases"])
        if target in aliases:
            return row
    return None


async def upsert_entity(
    db: aiosqlite.Connection,
    *,
    etype: str,
    name: str,
    aliases: list[str] | None = None,
    attrs: dict[str, Any] | None = None,
    notes: str = "",
    status: str = "active",
    now: str | None = None,
) -> str:
    now = now or utc_now_iso()
    existing = await find_entity_by_name(db, name, etype=etype)
    if existing:
        eid = existing["id"]
        old_aliases = _loads_list(existing["aliases"])
        merged_aliases = list(dict.fromkeys(old_aliases + [a for a in (aliases or []) if a]))
        old_attrs = _loads_dict(existing["attrs"])
        merged_attrs = {**old_attrs, **(attrs or {})}
        await db.execute(
            """UPDATE entities
               SET aliases=?, attrs=?, notes=COALESCE(NULLIF(?, ''), notes),
                   status=?, updated_at=?
               WHERE id=?""",
            (
                json.dumps(merged_aliases, ensure_ascii=False),
                json.dumps(merged_attrs, ensure_ascii=False),
                notes[:500],
                status,
                now,
                eid,
            ),
        )
    else:
        eid = new_id("ent")
        await db.execute(
            """INSERT INTO entities
               (id, etype, name, aliases, attrs, notes, status, created_at, updated_at)
               VALUES (?,?,?,?,?,?,?,?,?)""",
            (
                eid,
                etype,
                name.strip(),
                json.dumps(aliases or [], ensure_ascii=False),
                json.dumps(attrs or {}, ensure_ascii=False),
                notes[:500],
                status,
                now,
                now,
            ),
        )
    await sync_entity_fts(db, eid)
    return eid


async def create_fact(
    db: aiosqlite.Connection,
    *,
    text: str,
    entity_id: str | None = None,
    source: str = "distilled",
    confidence: float = 0.8,
    now: str | None = None,
) -> str:
    now = now or utc_now_iso()
    fid = new_id("fact")
    await db.execute(
        """INSERT INTO facts
           (id, entity_id, text, source, confidence, created_at, updated_at)
           VALUES (?,?,?,?,?,?,?)""",
        (fid, entity_id, text.strip(), source, confidence, now, now),
    )
    await sync_fact_fts(db, fid)
    return fid


async def backfill_kb_fts(db: aiosqlite.Connection) -> None:
    try:
        exists = await (await db.execute(
            "SELECT 1 FROM sqlite_master WHERE type='table' AND name='kb_fts'"
        )).fetchone()
    except Exception:
        return
    if not exists:
        return

    db.row_factory = aiosqlite.Row
    items = await (await db.execute(
        """SELECT id FROM chaoxing_memory_entries
           WHERE archived_at IS NULL AND COALESCE(status, 'active')='active'
           LIMIT 1000"""
    )).fetchall()
    for row in items:
        await sync_item_fts(db, row["id"])

    entities = await (await db.execute("SELECT id FROM entities WHERE status='active' LIMIT 500")).fetchall()
    for row in entities:
        await sync_entity_fts(db, row["id"])

    facts = await (await db.execute("SELECT id FROM facts WHERE archived_at IS NULL LIMIT 500")).fetchall()
    for row in facts:
        await sync_fact_fts(db, row["id"])


async def migrate_legacy_knowledge(db: aiosqlite.Connection) -> dict[str, int]:
    """Bridge legacy memory rows into the phase-2 knowledge model.

    This is intentionally conservative and idempotent: it creates only entities
    we can infer from existing structured/local data, links legacy items to
    those entities, and rebuilds FTS docs. It never deletes business rows.
    """
    now = utc_now_iso()
    db.row_factory = aiosqlite.Row
    counts = {
        "entities_upserted": 0,
        "facts_copied": 0,
        "items_linked": 0,
        "raw_refs_filled": 0,
        "fts_synced": 0,
    }

    # Structured course sources are trustworthy entity seeds.
    course_sources: dict[str, dict[str, Any]] = {}

    rows = await (await db.execute(
        """SELECT title, location, notes, MIN(start_at) AS first_start
           FROM server_courses
           WHERE title IS NOT NULL AND title != ''
           GROUP BY title
           LIMIT 500"""
    )).fetchall()
    for row in rows:
        attrs = _clean_attrs({
            "location": row["location"],
            "notes": row["notes"],
            "weekday": _weekday_from_iso(row["first_start"]),
        })
        course_sources.setdefault(row["title"], {}).update(attrs)

    try:
        rows = await (await db.execute(
            """SELECT name, teacher FROM chaoxing_courses
               WHERE name IS NOT NULL AND name != ''
               LIMIT 500"""
        )).fetchall()
        for row in rows:
            attrs = _clean_attrs({"teacher": row["teacher"]})
            course_sources.setdefault(row["name"], {}).update(attrs)
    except Exception:
        pass

    try:
        rows = await (await db.execute(
            """SELECT DISTINCT course_name FROM chaoxing_assignments
               WHERE course_name IS NOT NULL AND course_name != ''
               LIMIT 500"""
        )).fetchall()
        for row in rows:
            course_sources.setdefault(row["course_name"], {})
    except Exception:
        pass

    # Load memory rows for status/raw_ref backfill and entity linking below.
    # NOTE: we deliberately do NOT seed course entities from memory candidate
    # names — that injected junk like '2024级' or '数据库原理及应用期末考试'
    # (an exam, not a course) and resurrected stale courses on every startup.
    # Course entities come only from the authoritative course tables above.
    memory_rows = await (await db.execute(
        """SELECT id, title, kind, category, conversation_name,
                  conversation_names_json, entity_id, source_message_id,
                  source_ids_json, raw_ref, archived_at, status
           FROM chaoxing_memory_entries
           LIMIT 1500"""
    )).fetchall()

    course_name_to_id: dict[str, str] = {}
    for name, attrs in course_sources.items():
        clean = (name or "").strip()
        if not clean:
            continue
        eid = await upsert_entity(db, etype="course", name=clean, attrs=attrs, now=now)
        course_name_to_id[clean] = eid
        counts["entities_upserted"] += 1

    self_id = await upsert_entity(db, etype="self", name="我", aliases=["用户", "自己"], now=now)
    counts["entities_upserted"] += 1

    user_rows = await (await db.execute(
        "SELECT key, value, source, created_at, updated_at FROM user_memory LIMIT 1000"
    )).fetchall()
    for row in user_rows:
        text = f"{row['key']}: {row['value']}"
        exists = await (await db.execute(
            "SELECT 1 FROM facts WHERE text=? AND source=? LIMIT 1",
            (text, row["source"] or "user_told"),
        )).fetchone()
        if exists:
            continue
        await create_fact(
            db,
            entity_id=self_id,
            text=text,
            source=row["source"] or "user_told",
            confidence=0.9,
            now=row["updated_at"] or row["created_at"] or now,
        )
        counts["facts_copied"] += 1

    for row in memory_rows:
        updates: list[str] = []
        params: list[Any] = []
        if row["archived_at"] and (row["status"] or "active") == "active":
            updates.append("status='expired'")
        elif not row["status"]:
            updates.append("status='active'")

        raw_ref = row["raw_ref"] or row["source_message_id"] or _first_json_value(row["source_ids_json"])
        if raw_ref and not row["raw_ref"]:
            updates.append("raw_ref=?")
            params.append(raw_ref)
            counts["raw_refs_filled"] += 1

        if not row["entity_id"]:
            entity_id = _match_entity_for_memory(row, course_name_to_id)
            if entity_id:
                updates.append("entity_id=?")
                params.append(entity_id)
                counts["items_linked"] += 1

        if updates:
            updates.append("updated_at=COALESCE(updated_at, ?)")
            params.extend([now, row["id"]])
            await db.execute(
                f"UPDATE chaoxing_memory_entries SET {', '.join(updates)} WHERE id=?",
                params,
            )

    await backfill_kb_fts(db)
    try:
        row = await (await db.execute("SELECT COUNT(*) FROM kb_fts")).fetchone()
        counts["fts_synced"] = int(row[0] or 0)
    except Exception:
        pass
    await db.execute(
        "INSERT OR REPLACE INTO settings (key, value) VALUES (?, ?)",
        ("legacy_kb_backfill_last", json.dumps({"at": now, **counts}, ensure_ascii=False)),
    )
    return counts


def _candidate_course_names(row: aiosqlite.Row) -> list[str]:
    names: list[str] = []
    if row["conversation_name"]:
        names.append(row["conversation_name"])
    names.extend(_loads_list(row["conversation_names_json"]))
    if row["kind"] == "course" and row["title"]:
        names.append(row["title"])
    return [
        n.strip()
        for n in dict.fromkeys(names)
        if n and n.strip() and len(n.strip()) <= 80
    ]


def _match_entity_for_memory(row: aiosqlite.Row, course_name_to_id: dict[str, str]) -> str | None:
    for name in _candidate_course_names(row):
        if name in course_name_to_id:
            return course_name_to_id[name]
    title = row["title"] or ""
    for name, eid in course_name_to_id.items():
        if name and (name in title or title in name):
            return eid
    return None


def _first_json_value(raw: str | None) -> str | None:
    values = _loads_list(raw)
    return values[0] if values else None


def _clean_attrs(attrs: dict[str, Any]) -> dict[str, Any]:
    return {k: v for k, v in attrs.items() if v not in (None, "", [])}


def _weekday_from_iso(value: str | None) -> int | None:
    if not value:
        return None
    try:
        dt = datetime.fromisoformat(value.replace("Z", "+00:00"))
    except Exception:
        return None
    return dt.isoweekday()


def _loads_list(raw: str | None) -> list[str]:
    try:
        data = json.loads(raw or "[]")
    except Exception:
        return []
    return [str(v) for v in data if str(v or "").strip()] if isinstance(data, list) else []


def _loads_dict(raw: str | None) -> dict[str, Any]:
    try:
        data = json.loads(raw or "{}")
    except Exception:
        return {}
    return data if isinstance(data, dict) else {}
