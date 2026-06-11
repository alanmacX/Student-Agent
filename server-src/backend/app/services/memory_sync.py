"""
Unified Memory Sync
===================
Writes all non-LLM data sources into chaoxing_memory_entries via MemoryRepository:
  - kind='assignment'  — pending Chaoxing assignments (non-expired)
  - kind='course'      — upcoming local course events from server_courses
  - kind='reminder'    — server reminders from server_reminders

After writing, resolves cross-references between message-derived entries
and their related assignment / course entries (related_ids_json, both sides).

Called from chaoxing_sync.py on every probe pass, before the LLM extraction.
"""
from __future__ import annotations

import json
from datetime import datetime, timedelta, timezone

import aiosqlite

from .memory_models import key_text, parse_iso
from app.memory.base import MemoryEntry, MemoryRepository, Tier
from app.memory.keys import canonical_dedupe_key

PENDING_STATUSES = {"未交", "未提交"}
CST = timezone(timedelta(hours=8))


# ── helpers ───────────────────────────────────────────────────────────────────
# Dedup keys go through the canonical registry (app.memory.keys) so the
# structured sync and the LLM engine agree on one key per entity. The registry
# builders reproduce these exact formats, so existing rows keep matching.

def _assignment_dk(assignment: dict) -> str:
    return canonical_dedupe_key(
        "assignment",
        course=assignment.get("courseName") or assignment.get("course_name") or "",
        title=assignment.get("title") or "",
    )


def _reminder_dk(reminder: dict) -> str:
    return canonical_dedupe_key(
        "reminder",
        title=reminder.get("title") or str(reminder.get("id", "")),
    )


def _course_dk(title: str, start_at: str) -> str:
    return canonical_dedupe_key("course", title=title or "", start=start_at or "")


def _is_expired(assignment: dict, now: datetime) -> bool:
    due = parse_iso(assignment.get("dueDate"))
    return due is not None and due < now


def _importance_by_deadline(due: datetime | None, now: datetime) -> str:
    if due is None:
        return "medium"
    return "high" if (due - now).total_seconds() < 72 * 3600 else "medium"


def _fmt_dt(dt: datetime | None) -> str:
    if dt is None:
        return "待定"
    return dt.astimezone(CST).strftime("%m月%d日 %H:%M")


# ── public entry point ────────────────────────────────────────────────────────

async def sync_to_memory(
    assignments: list[dict],
    reminders: list[dict],
    db_path: str,
    now: datetime,
) -> dict:
    """
    Sync assignments, reminders, and course events into unified memory
    via MemoryRepository (replaces direct SQL writes).
    Returns counters: {upserted, archived, linked}.
    """
    if now.tzinfo is None:
        now = now.replace(tzinfo=timezone.utc)

    repo = MemoryRepository(db_path)
    upserted = archived = linked = 0

    # ── 1. Assignments ────────────────────────────────────────────────────────
    active_pending = [
        a for a in assignments
        if a.get("status") in PENDING_STATUSES
        and a.get("dueDate")
        and not _is_expired(a, now)
    ]
    active_assignment_dks = {_assignment_dk(a) for a in active_pending}

    for a in active_pending:
        dk = _assignment_dk(a)
        due = parse_iso(a.get("dueDate"))
        expires_at = due or (now + timedelta(days=60))
        imp = _importance_by_deadline(due, now)
        title = a.get("title") or "作业"
        course = a.get("courseName") or a.get("course_name") or ""
        due_str = _fmt_dt(due) if due else "无截止日期"
        summary = f"{course} · 截止 {due_str}" if course else f"截止 {due_str}"

        entry = MemoryEntry(
            title=title,
            summary=summary,
            reason="pending assignment from Chaoxing",
            importance=imp,
            action_hint=f"在学习通提交《{title}》",
            category="assignment",
            kind="assignment",
            source_type="chaoxing",
            expires_at=expires_at,
            hierarchy_tier=Tier.ACTIONABLE if imp == "high" else Tier.CONTEXT,
            for_automation=True,
            dedupe_key=dk,
            conversation_names=[course] if course else [],
            confidence=1.0,
        )
        await repo.upsert_entry(entry, now)
        upserted += 1

    # Archive assignments no longer active-pending
    if active_pending:
        async with aiosqlite.connect(db_path) as db:
            stale = await (await db.execute(
                "SELECT id, dedupe_key FROM chaoxing_memory_entries WHERE kind='assignment' AND archived_at IS NULL"
            )).fetchall()
            to_archive = [r[0] for r in stale if r[1] not in active_assignment_dks]
            if to_archive:
                ni = now.isoformat()
                await db.executemany(
                    "UPDATE chaoxing_memory_entries SET archived_at=?, status='expired', updated_at=? WHERE id=?",
                    [(ni, ni, mid) for mid in to_archive],
                )
                from app.services.knowledge import sync_item_fts

                for mid in to_archive:
                    await sync_item_fts(db, mid)
                archived += len(to_archive)
            await db.commit()
        if to_archive:
            from app.services.ladder import cancel_ladder_for_item

            for mid in to_archive:
                await cancel_ladder_for_item(db_path, mid)

    # ── 2. Local course schedule (server_courses) ─────────────────────────────
    horizon = (now + timedelta(days=14)).isoformat()
    async with aiosqlite.connect(db_path) as db:
        db.row_factory = aiosqlite.Row
        course_rows = await (await db.execute(
            """SELECT id, title, start_at, end_at, location
               FROM server_courses
               WHERE end_at >= ? AND start_at <= ?
               ORDER BY start_at ASC LIMIT 80""",
            (now.isoformat(), horizon),
        )).fetchall()

    for c in course_rows:
        title = c["title"] or "课程"
        start = parse_iso(c["start_at"])
        end = parse_iso(c["end_at"])
        expires_at = end or (start + timedelta(hours=2) if start else now + timedelta(hours=2))
        if expires_at < now:
            continue
        dk = _course_dk(title, c["start_at"])
        location = c["location"] or ""
        summary = _fmt_dt(start) + (f" · {location}" if location else "")

        entry = MemoryEntry(
            title=title,
            summary=summary,
            reason="local course schedule",
            importance="medium",
            category="course",
            kind="course",
            source_type="chaoxing",
            expires_at=expires_at,
            hierarchy_tier=Tier.CONTEXT,
            for_automation=False,
            dedupe_key=dk,
            confidence=1.0,
        )
        await repo.upsert_entry(entry, now)
        upserted += 1

    # ── 3. Server reminders ───────────────────────────────────────────────────
    for r in reminders:
        if r.get("is_completed"):
            continue
        due = parse_iso(r.get("dueDate"))
        if due and due < now:
            continue
        dk = _reminder_dk(r)
        expires_at = due or (now + timedelta(days=7))
        title = r.get("title") or "提醒"
        imp = "high" if r.get("isImportant") else "medium"

        entry = MemoryEntry(
            title=title,
            summary=r.get("listName") or "",
            reason="server reminder",
            importance=imp,
            category="reminder",
            kind="reminder",
            source_type="user",
            expires_at=expires_at,
            hierarchy_tier=Tier.ACTIONABLE if imp == "high" else Tier.CONTEXT,
            for_automation=True,
            dedupe_key=dk,
            confidence=1.0,
        )
        await repo.upsert_entry(entry, now)
        upserted += 1

    # ── 4. Cross-reference: message ↔ assignment / course ─────────────────────
    async with aiosqlite.connect(db_path) as db:
        db.row_factory = aiosqlite.Row

        asgn_rows = await (await db.execute(
            "SELECT id, dedupe_key, conversation_names_json FROM chaoxing_memory_entries WHERE kind='assignment' AND archived_at IS NULL"
        )).fetchall()
        course_name_to_asgn: dict[str, str] = {}
        for row in asgn_rows:
            for name in json.loads(row["conversation_names_json"] or "[]"):
                course_name_to_asgn[key_text(name)] = row["id"]
        asgn_dk_to_id = {row["dedupe_key"]: row["id"] for row in asgn_rows}

        course_rows2 = await (await db.execute(
            "SELECT id, title FROM chaoxing_memory_entries WHERE kind='course' AND archived_at IS NULL"
        )).fetchall()
        course_title_to_id: dict[str, str] = {key_text(row["title"]): row["id"] for row in course_rows2}

        msg_rows = await (await db.execute(
            """SELECT id, conversation_names_json, linked_assignment_key,
                      linked_course_key, related_ids_json
               FROM chaoxing_memory_entries WHERE kind='message' AND archived_at IS NULL"""
        )).fetchall()

        for row in msg_rows:
            existing_rel = set(json.loads(row["related_ids_json"] or "[]"))
            new_rel: set[str] = set()

            for name in json.loads(row["conversation_names_json"] or "[]"):
                aid = course_name_to_asgn.get(key_text(name))
                if aid:
                    new_rel.add(aid)
                cid2 = course_title_to_id.get(key_text(name))
                if cid2:
                    new_rel.add(cid2)

            lak = row["linked_assignment_key"]
            if lak:
                aid = asgn_dk_to_id.get(f"assignment::{key_text(lak)}")
                if aid:
                    new_rel.add(aid)

            lck = row["linked_course_key"]
            if lck:
                cid2 = course_title_to_id.get(key_text(lck))
                if cid2:
                    new_rel.add(cid2)

            merged = existing_rel | new_rel
            if merged != existing_rel:
                await db.execute(
                    "UPDATE chaoxing_memory_entries SET related_ids_json=? WHERE id=?",
                    (json.dumps(list(merged), ensure_ascii=False), row["id"]),
                )
                linked += 1

            for target_id in new_rel:
                t = await (await db.execute(
                    "SELECT related_ids_json FROM chaoxing_memory_entries WHERE id=?", (target_id,)
                )).fetchone()
                if t:
                    t_rel = set(json.loads(t["related_ids_json"] or "[]"))
                    if row["id"] not in t_rel:
                        t_rel.add(row["id"])
                        await db.execute(
                            "UPDATE chaoxing_memory_entries SET related_ids_json=? WHERE id=?",
                            (json.dumps(list(t_rel), ensure_ascii=False), target_id),
                        )

        await db.commit()

    return {"upserted": upserted, "archived": archived, "linked": linked}
