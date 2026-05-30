"""
Unified Memory Sync
===================
Writes all non-LLM data sources into chaoxing_memory_entries:
  - kind='assignment'  — pending Chaoxing assignments (non-expired)
  - kind='course'      — upcoming local course events from server_courses
  - kind='reminder'    — server reminders from server_reminders

After writing, resolves cross-references between message-derived entries
and their related assignment / course entries (related_ids_json, both sides).

Called from chaoxing_sync.py on every probe pass, before the LLM extraction.
"""
from __future__ import annotations

import json
import uuid
from datetime import datetime, timedelta, timezone

import aiosqlite

from .memory_models import key_text, make_assignment_key, parse_iso

PENDING_STATUSES = {"未交", "未提交"}
CST = timezone(timedelta(hours=8))


# ── helpers ───────────────────────────────────────────────────────────────────

def _now_iso(now: datetime) -> str:
    return now.isoformat()


def _assignment_dk(assignment: dict) -> str:
    k = make_assignment_key(
        assignment.get("courseName") or assignment.get("course_name"),
        assignment.get("title"),
    )
    return f"assignment::{key_text(k)}"


def _reminder_dk(reminder: dict) -> str:
    k = key_text(reminder.get("title") or str(reminder.get("id", "")))
    return f"reminder::{k}"


def _course_dk(title: str, start_at: str) -> str:
    return f"course::{key_text(title)}::{key_text(start_at)}"


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
    Sync assignments, reminders, and course events into unified memory.
    Returns counters: {upserted, archived, linked}.
    """
    if now.tzinfo is None:
        now = now.replace(tzinfo=timezone.utc)

    upserted = archived = linked = 0

    async with aiosqlite.connect(db_path) as db:
        db.row_factory = aiosqlite.Row

        # ── 1. Assignments ────────────────────────────────────────────────────
        # Only assignments with a future dueDate — matches macOS visibleChaoxingAssignmentItems logic
        active_pending = [
            a for a in assignments
            if a.get("status") in PENDING_STATUSES
            and a.get("dueDate")          # must have a deadline
            and not _is_expired(a, now)   # must not be past deadline
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
            action_hint = f"在学习通提交《{title}》"

            existing = await (await db.execute(
                "SELECT id FROM chaoxing_memory_entries WHERE dedupe_key=?", (dk,)
            )).fetchone()

            ni = _now_iso(now)
            if existing:
                await db.execute(
                    """UPDATE chaoxing_memory_entries
                       SET title=?, summary=?, importance=?, expires_at=?,
                           action_hint=?, updated_at=?, archived_at=NULL, kind='assignment'
                       WHERE id=?""",
                    (title, summary, imp, expires_at.isoformat(), action_hint, ni, existing["id"]),
                )
            else:
                eid = str(uuid.uuid4())
                await db.execute(
                    """INSERT INTO chaoxing_memory_entries
                       (id, title, summary, reason, action_hint, importance,
                        sent_at, extracted_at, expires_at, dedupe_key, category,
                        kind, confidence, source_ids_json, source_fingerprints_json,
                        conversation_ids_json, conversation_names_json, sender_names_json,
                        related_ids_json, created_at, updated_at)
                       VALUES (?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?)""",
                    (eid, title, summary, "pending assignment from Chaoxing",
                     action_hint, imp, ni, ni, expires_at.isoformat(),
                     dk, "assignment", "assignment", 1.0,
                     "[]", "[]", "[]",
                     json.dumps([course] if course else [], ensure_ascii=False),
                     "[]", "[]", ni, ni),
                )
            upserted += 1

        # Archive assignments that are no longer active-pending
        # Only archive if we actually fetched assignments — an empty fetch could mean
        # a network failure, and archiving everything would be catastrophic.
        if active_pending:
            stale = await (await db.execute(
                "SELECT id, dedupe_key FROM chaoxing_memory_entries WHERE kind='assignment' AND archived_at IS NULL"
            )).fetchall()
            for row in stale:
                if row["dedupe_key"] not in active_assignment_dks:
                    await db.execute(
                        "UPDATE chaoxing_memory_entries SET archived_at=? WHERE id=?",
                        (now.isoformat(), row["id"]),
                    )
                    archived += 1

        # ── 2. Local course schedule (server_courses) ─────────────────────────
        horizon = (now + timedelta(days=14)).isoformat()
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

            existing = await (await db.execute(
                "SELECT id, action_hint FROM chaoxing_memory_entries WHERE dedupe_key=?", (dk,)
            )).fetchone()
            ni = _now_iso(now)
            if existing:
                # Don't overwrite action_hint — it may have been set by a course_change message
                await db.execute(
                    """UPDATE chaoxing_memory_entries
                       SET title=?, summary=?, expires_at=?, updated_at=?, archived_at=NULL
                       WHERE id=? AND (action_hint IS NULL OR action_hint='')""",
                    (title, summary, expires_at.isoformat(), ni, existing["id"]),
                )
            else:
                eid = str(uuid.uuid4())
                await db.execute(
                    """INSERT INTO chaoxing_memory_entries
                       (id, title, summary, reason, importance, sent_at, extracted_at,
                        expires_at, dedupe_key, category, kind, confidence,
                        source_ids_json, source_fingerprints_json, conversation_ids_json,
                        conversation_names_json, sender_names_json, related_ids_json,
                        created_at, updated_at)
                       VALUES (?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?)""",
                    (eid, title, summary, "local course schedule",
                     "medium", ni, ni, expires_at.isoformat(),
                     dk, "course", "course", 1.0,
                     "[]", "[]", "[]", "[]", "[]", "[]", ni, ni),
                )
            upserted += 1

        # ── 3. Server reminders ───────────────────────────────────────────────
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

            existing = await (await db.execute(
                "SELECT id FROM chaoxing_memory_entries WHERE dedupe_key=?", (dk,)
            )).fetchone()
            ni = _now_iso(now)
            if existing:
                await db.execute(
                    """UPDATE chaoxing_memory_entries
                       SET title=?, importance=?, expires_at=?, updated_at=?, archived_at=NULL, kind='reminder'
                       WHERE id=?""",
                    (title, imp, expires_at.isoformat(), ni, existing["id"]),
                )
            else:
                eid = str(uuid.uuid4())
                await db.execute(
                    """INSERT INTO chaoxing_memory_entries
                       (id, title, summary, reason, importance, sent_at, extracted_at,
                        expires_at, dedupe_key, category, kind, confidence,
                        source_ids_json, source_fingerprints_json, conversation_ids_json,
                        conversation_names_json, sender_names_json, related_ids_json,
                        created_at, updated_at)
                       VALUES (?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?)""",
                    (eid, title, r.get("listName") or "", "server reminder",
                     imp, ni, ni, expires_at.isoformat(),
                     dk, "reminder", "reminder", 1.0,
                     "[]", "[]", "[]", "[]", "[]", "[]", ni, ni),
                )
            upserted += 1

        # ── 4. Cross-reference: message ↔ assignment / course ────────────────
        # Fetch active assignment entries indexed by course name key
        asgn_rows = await (await db.execute(
            """SELECT id, dedupe_key, conversation_names_json
               FROM chaoxing_memory_entries WHERE kind='assignment' AND archived_at IS NULL"""
        )).fetchall()
        course_name_to_asgn: dict[str, str] = {}
        for row in asgn_rows:
            for name in json.loads(row["conversation_names_json"] or "[]"):
                course_name_to_asgn[key_text(name)] = row["id"]
        asgn_dk_to_id = {row["dedupe_key"]: row["id"] for row in asgn_rows}

        # Fetch active course entries
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

            # Back-reference both sides
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
