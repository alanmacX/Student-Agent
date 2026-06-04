from __future__ import annotations
import json
from datetime import datetime, timedelta, timezone

import aiosqlite

from .chaoxing_message_filter import load_sync_state, run as filter_messages, save_sync_state
from .memory_models import display_text, key_text, make_assignment_key, parse_iso, preview
from .memory_reducer import get_insights, reduce_memory, sweep_memory


async def _fetch_for_scope(chaoxing_svc, db_path, scope, conversation_ids):
    """Narrow the message fetch by scope. Returns list of message dicts."""
    if scope == "conversation" and conversation_ids:
        return await chaoxing_svc.fetch_recent_messages(
            changed_conversation_ids=conversation_ids, per_conversation=20
        )
    if scope == "changed":
        probes = await chaoxing_svc.fetch_conversation_probes()
        changed = await chaoxing_svc._filter_changed_probes(probes, db_path)
        if not changed:
            return []
        msgs = await chaoxing_svc.fetch_recent_messages(
            changed_conversation_ids=changed, per_conversation=20
        )
        # Persist signatures so the next "changed" pass doesn't re-pull the same.
        await chaoxing_svc._save_probe_signatures(probes, db_path)
        return msgs
    # default "all"
    return await chaoxing_svc.fetch_recent_messages(max_conversations=12, per_conversation=20)


async def run_memory_agent(
    chaoxing_svc,
    db_path: str,
    provider: dict,
    model: str,
    api_key: str,
    muted_names: set[str] = None,
    assignments: list[dict] | None = None,
    scope: str = "all",
    conversation_ids: list[str] | None = None,
) -> dict:
    """scope:
    - "all"          : fetch up to 12 conversations × 20 msgs (full pass).
    - "changed"      : probe first, fetch only conversations whose signature changed.
    - "conversation" : fetch only the given conversation_ids.
    The LLM extraction is unchanged; scope only narrows the *fetch* to cut cost.
    """
    now = datetime.now(timezone.utc)
    sync_state = await load_sync_state(db_path)
    messages = await _fetch_for_scope(chaoxing_svc, db_path, scope, conversation_ids)
    if not messages:
        await _touch_chaoxing_session(db_path, now)
        return {"candidate_count": 0, "kept_count": 0, "processed_ids": [], "new_entry_ids": []}

    if assignments is None:
        try:
            assignments = await chaoxing_svc.fetch_all_pending_assignments()
        except Exception:
            assignments = []

    filter_result = filter_messages(
        messages,
        sync_state,
        assignments,
        muted_names=muted_names,
        now=now,
    )
    candidates = filter_result["candidates"]
    if not candidates:
        await save_sync_state(db_path, filter_result, [], now)
        await _touch_chaoxing_session(db_path, now)
        return {
            "candidate_count": 0,
            "kept_count": 0,
            "processed_ids": [],
            "new_entry_ids": [],
            "dropped_reasons": filter_result.get("dropped_reasons", {}),
        }

    active_memory = await get_insights(db_path, now, limit=30)
    courses = await _load_course_snapshot(db_path, now)
    raw_text, extracted, parse_ok = await _extract_with_llm(
        candidates, assignments, courses, active_memory, provider, model, api_key, now
    )

    # If LLM returned content but JSON parsing failed, do NOT mark messages as processed.
    # This allows the next probe to retry extraction.
    # Note: parse_ok=False means JSON was invalid. parse_ok=True with empty extracted means
    # LLM correctly decided there's nothing worth extracting — that's normal.
    if not parse_ok:
        import logging
        logging.getLogger("memory_agent").error(
            f"LLM returned non-empty response but JSON parsing failed. "
            f"NOT marking {len(candidates)} messages as processed. "
            f"Raw snippet: {raw_text[:200]}"
        )
        await _touch_chaoxing_session(db_path, now)
        return {
            "candidate_count": len(candidates),
            "kept_count": 0,
            "processed_ids": [],
            "new_entry_ids": [],
            "dropped_reasons": filter_result.get("dropped_reasons", {}),
        }

    assignment_keys = {
        make_assignment_key(a.get("courseName") or a.get("course_name"), a.get("title"))
        for a in assignments
    }
    new_entry_ids = await reduce_memory(extracted, candidates, assignment_keys, now, db_path)
    await save_sync_state(db_path, filter_result, candidates, now)
    await _touch_chaoxing_session(db_path, now)

    return {
        "candidate_count": len(candidates),
        "kept_count": len(new_entry_ids),
        "processed_ids": [m["source_id"] for m in candidates],
        "processed_fingerprints": [m["fingerprint"] for m in candidates],
        "new_entry_ids": new_entry_ids,
        "dropped_reasons": filter_result.get("dropped_reasons", {}),
    }


def _system_prompt(now: datetime) -> str:
    from .time_context import now_stamp as _now_stamp
    return f"""{_now_stamp(now)}
You are the Chaoxing Memory Agent for a unified schedule/todo app.
The app already has a unified memory store containing entries of kinds:
  assignment — pending assignments (auto-synced, do not duplicate)
  course     — upcoming class sessions (auto-synced from calendar)
  reminder   — reminders (auto-synced)
  message    — extracted from Chaoxing messages (YOUR output)

Your job: extract ONLY kind=message entries from candidate Chaoxing messages.
Do NOT emit entries for assignments or reminders that are already tracked.

Return strict JSON only, no markdown fences.

Schema:
{{
  "insights": [
    {{
      "decision": "keep" | "drop",
      "source_ids": ["message id", ...],
      "category": "course_change" | "exam" | "meeting" | "notice" | "other",
      "importance": "high" | "medium" | "low",
      "title": "≤20 chars",
      "summary": "what happened, with concrete dates/times",
      "reason": "why keep or drop",
      "action_hint": "one concrete next action for the user",
      "content_time": "ISO-8601 datetime of the event itself, if known",
      "expires_at": "ISO-8601 datetime — set to exact event time for time-bound items; sent_at+14d otherwise",
      "dedupe_key": "stable semantic key, e.g. 'course_change::web前端::2026-06-03'",
      "linked_assignment_key": "if message references a tracked assignment, its key (course_name::title)",
      "linked_course_key": "if message changes a course (reschedule/cancel/room), the COURSE NAME only",
      "confidence": 0.85
    }}
  ]
}}

INTERACTION RULES (critical):
1. course_change category + linked_course_key:
   Set this when teacher announces cancellation, reschedule, makeup, room change.
   The system will AUTOMATICALLY update the linked course entry's status.
   Example: "下周二停课" → category=course_change, linked_course_key="Web前端开发"
2. linked_assignment_key for high-importance messages:
   If a message adds urgency to a tracked assignment (e.g., "明天最后截止"),
   set linked_assignment_key. The system will elevate that assignment's priority.
3. Merge repeated notices: use the same dedupe_key to avoid duplicate entries.
4. Drop: pure chat, ACKs, vague noise, homework announcements already in assignment snapshot."""


def _user_payload(candidates, assignments, courses, active_memory_entries, now) -> str:
    candidate_payload = [
        {
            "source_id": m["source_id"],
            "fingerprint": m["fingerprint"],
            "conversation_id": m["conversation_id"],
            "conversation_name": m["conversation_name"],
            "is_group": m["is_group"],
            "sender_id": m["sender_id"],
            "sender_name": m.get("sender_name"),
            "sent_at": m["sent_at"],
            "type": m["type"],
            "text": preview(m.get("text") or "", 900),
            "image_urls": m.get("image_urls") or [],
        }
        for m in candidates
    ]

    # All pending assignments — already tracked in memory as kind='assignment'
    # LLM should use their keys for linked_assignment_key references
    assignment_snapshot = [
        {
            "key": make_assignment_key(a.get("courseName") or a.get("course_name"), a.get("title")),
            "course": a.get("courseName") or a.get("course_name"),
            "title": a.get("title"),
            "due": a.get("dueDate"),
            "status": a.get("status"),
        }
        for a in assignments
        if a.get("status") in ("未交", "未提交")
    ]

    # Active memory — split by kind so LLM sees what already exists
    asgn_mem = [m for m in active_memory_entries if m.get("kind") == "assignment"]
    course_mem = [m for m in active_memory_entries if m.get("kind") == "course"]
    other_mem = [m for m in active_memory_entries if m.get("kind") not in ("assignment", "course")]

    # Local course schedule for display context
    course_schedule = "\n".join(
        f"- {c.get('title')} {c.get('start_at') or c.get('startDate')}-{c.get('end_at') or c.get('endDate')} {c.get('location') or ''}".strip()
        for c in courses[:40]
    )

    def mem_compact(items):
        return [{"k": m.get("dedupe_key"), "t": m.get("title"), "x": m.get("expires_at")} for m in items[:15]]

    return f"""=== Candidate Chaoxing messages to extract ===
{json.dumps(candidate_payload, ensure_ascii=False, indent=2)}

=== Pending assignments already in memory (kind=assignment) ===
Use these keys for linked_assignment_key. Do NOT emit entries for these — they're tracked.
{json.dumps(assignment_snapshot, ensure_ascii=False, indent=2)}

=== Course entries in memory (kind=course) ===
Use title as linked_course_key when a message changes one of these courses.
{json.dumps(mem_compact(course_mem), ensure_ascii=False, indent=2)}

=== Local course schedule (calendar) ===
{course_schedule or "No local course data."}

=== Other active memory entries (kind=message/reminder) ===
Merge/update these instead of creating duplicates.
{json.dumps(mem_compact(other_mem + asgn_mem), ensure_ascii=False, indent=2)}"""


async def _extract_with_llm(candidates, assignments, courses, active_memory, provider, model, api_key, now) -> tuple[str, list[dict], bool]:
    """Returns (raw_text, parsed_insights, parse_success).

    parse_success=True  → JSON was valid (insights may be empty — LLM decided nothing to extract)
    parse_success=False → JSON parsing failed (should NOT mark messages as processed)
    """
    from .agent_service import AgentMsg, agent_complete

    response = await agent_complete(
        [
            AgentMsg(role="system", content=_system_prompt(now)),
            AgentMsg(role="user", content=_user_payload(candidates, assignments, courses, active_memory, now)),
        ],
        [],
        provider,
        model,
        api_key,
    )
    raw = response.text or ""
    parsed, success = _parse_envelope(raw)
    return raw, parsed, success


def _parse_envelope(text: str) -> tuple[list[dict], bool]:
    """Parse LLM response into insight list.

    Returns (insights, success):
      success=True  → JSON was valid (insights may be empty — that's normal)
      success=False → JSON parsing failed entirely (should NOT mark processed)
    """
    body = text.strip()
    if body.startswith("```"):
        body = body.split("\n", 1)[1] if "\n" in body else body
        body = body.rsplit("```", 1)[0].strip()
        if body.startswith("json"):
            body = body[4:].strip()
    start = body.find("{")
    end = body.rfind("}")
    if start >= 0 and end > start:
        body = body[start:end + 1]
    try:
        data = json.loads(body)
    except json.JSONDecodeError:
        return [], False
    insights = data.get("insights") if isinstance(data, dict) else None
    return (insights if isinstance(insights, list) else []), True


async def _load_course_snapshot(db_path: str, now: datetime) -> list[dict]:
    async with aiosqlite.connect(db_path) as db:
        db.row_factory = aiosqlite.Row
        rows = await (await db.execute("""
            SELECT title, start_at, end_at, location
            FROM server_courses
            WHERE end_at >= ?
            ORDER BY start_at ASC
            LIMIT 40
        """, (now.isoformat(),))).fetchall()
    return [dict(row) for row in rows]


async def _touch_chaoxing_session(db_path: str, now: datetime) -> None:
    async with aiosqlite.connect(db_path) as db:
        await db.execute(
            "UPDATE chaoxing_session SET last_active_at=?, updated_at=? WHERE id=1",
            (now.isoformat(), now.isoformat()),
        )
        await db.commit()


async def run_memory_maintenance(db_path: str):
    await sweep_memory(db_path, datetime.now(timezone.utc))


def is_semantically_expired(item: dict, now: datetime) -> bool:
    if now.tzinfo is None:
        now = now.replace(tzinfo=timezone.utc)
    expires = parse_iso(item.get("expires_at"))
    if expires:
        return now > expires

    text = f"{item.get('title', '')} {item.get('summary', '')} {item.get('action_hint', '')}"
    if any(marker in text for marker in ["明天", "后天", "下周", "下个", "明日"]):
        return False
    import re
    match = re.search(r"(\d{1,2}):(\d{2})", text)
    if match:
        hour, minute = int(match.group(1)), int(match.group(2))
        target = now.replace(hour=hour, minute=minute, second=0, microsecond=0)
        return target < now - timedelta(minutes=45)
    return False


def format_current_time(now: datetime) -> str:
    return now.astimezone(timezone.utc).isoformat()
