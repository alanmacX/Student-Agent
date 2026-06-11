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
        row = await (await db.execute("SELECT COUNT(*) FROM kb_fts LIMIT 1")).fetchone()
        if row and row[0] > 0:
            return
    except Exception:
        return

    db.row_factory = aiosqlite.Row
    items = await (await db.execute(
        """SELECT id FROM chaoxing_memory_entries
           WHERE archived_at IS NULL AND COALESCE(status, 'active')='active'
           LIMIT 500"""
    )).fetchall()
    for row in items:
        await sync_item_fts(db, row["id"])

    entities = await (await db.execute("SELECT id FROM entities WHERE status='active' LIMIT 500")).fetchall()
    for row in entities:
        await sync_entity_fts(db, row["id"])

    facts = await (await db.execute("SELECT id FROM facts WHERE archived_at IS NULL LIMIT 500")).fetchall()
    for row in facts:
        await sync_fact_fts(db, row["id"])


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
