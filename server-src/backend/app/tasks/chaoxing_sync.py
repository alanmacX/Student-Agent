"""
Adaptive Chaoxing sync probe.
"""
from __future__ import annotations


import logging
from apscheduler.triggers.date import DateTrigger
from datetime import datetime, timezone, timedelta
from app.chaoxing.memory_provider import run_chaoxing_memory_sync
from app.config import settings

logger = logging.getLogger("chaoxing")


async def run_chaoxing_probe_adaptive(app_state, scheduler):
    if not app_state.chaoxing_svc.is_logged_in:
        next_interval = 300.0
    else:
        # Fetch assignments once — reused by adaptive_sync_pass, memory_sync, and memory_agent
        assignments = []
        try:
            assignments = await app_state.chaoxing_svc.fetch_all_pending_assignments()
        except Exception as e:
            logger.warning(f"Could not fetch assignments: {e}")

        next_interval = await app_state.chaoxing_svc.adaptive_sync_pass(
            app_state.settings.database_path, assignments=assignments
        )
        # compute_sync_interval already owns the full cadence decision and self-caps
        # at 900s; only enforce a hard safety ceiling so a bad signal can't stall sync.
        # (The old chaoxing_sync_interval=300 cap defeated the night back-off.)
        next_interval = min(next_interval, 900.0)

        now = datetime.now(timezone.utc)
        db_path = app_state.settings.database_path

        # Did any conversation change this tick? adaptive_sync_pass set this.
        # Default 1 (run) if unknown so we never silently stall on first tick.
        messages_changed = getattr(app_state.chaoxing_svc, "_last_sync_changed", 1)

        # ── Step 1: Sync assignments + reminders into unified memory (no LLM) ─
        # Always runs (cheap, no LLM) so memory stays consistent with live data.
        memory_changed = False
        try:
            from app.services.memory_sync import sync_to_memory
            from app.services.schedule_store import list_reminders

            try:
                await _cache_chaoxing_data(app_state.chaoxing_svc, db_path, assignments, now)
            except Exception as e:
                logger.warning(f"Could not cache chaoxing data: {e}")

            reminders = []
            try:
                reminders = await list_reminders(db_path)
            except Exception as e:
                logger.warning(f"Could not fetch reminders for memory sync: {e}")

            sync_result = await sync_to_memory(assignments, reminders, db_path, now)
            memory_changed = (sync_result["upserted"] + sync_result["archived"]) > 0
            logger.debug(
                f"Memory sync: {sync_result['upserted']} upserted, "
                f"{sync_result['archived']} archived, {sync_result['linked']} linked"
            )
        except Exception as e:
            logger.error(f"Memory sync failed: {e}", exc_info=True)

        # Resolve provider once for the LLM steps below.
        provider = api_key = model = None
        try:
            from app.services.provider_registry import resolve_provider
            provider, api_key = await resolve_provider(
                app_state.settings.standby_agent_provider or "openai"
            )
            model = app_state.settings.standby_agent_model or "gpt-4o-mini"
        except Exception as e:
            logger.error(f"Provider resolve failed in probe: {e}")

        # ── Step 2: LLM extraction — GATED: only when a conversation changed ──
        # On idle/night ticks (no message change) this whole block is skipped,
        # saving a redundant fetch+filter+LLM pass. Assignment changes are handled
        # by Step 1 (no LLM) and the separate deadline_check job, so skipping is safe.
        new_entry_ids = []
        if messages_changed and provider and api_key:
            try:
                result = await run_chaoxing_memory_sync(
                    app_state.chaoxing_svc, db_path,
                    provider, model, api_key,
                    assignments=assignments, now=now,
                )
                logger.debug(
                    f"Chaoxing memory: {result.get('candidate_count', 0)} candidates, "
                    f"{result.get('processed_count', 0)} processed"
                )
                new_entry_ids = result.get("new_entry_ids") or []
            except Exception as e:
                logger.error(f"Memory agent (LLM) failed in probe: {e}")
        elif not messages_changed:
            logger.debug("Skip LLM extraction: no changed conversations this tick")

    run_at = datetime.now(timezone.utc) + timedelta(seconds=next_interval)
    scheduler.add_job(
        run_chaoxing_probe_adaptive,
        DateTrigger(run_date=run_at),
        args=[app_state, scheduler],
        id="chaoxing_probe",
        misfire_grace_time=60,
        replace_existing=True,
    )


async def _cache_chaoxing_data(chaoxing_svc, db_path: str, assignments: list, now: datetime) -> None:
    """Upsert assignments and courses into local cache tables for sidebar reads."""
    import aiosqlite

    now_iso = now.isoformat()

    async with aiosqlite.connect(db_path) as db:
        # Cache assignments
        if assignments:
            await db.execute("DELETE FROM chaoxing_assignments")
            await db.executemany(
                """INSERT OR REPLACE INTO chaoxing_assignments
                   (id, course_id, course_name, title, description, due_date, status, synced_at)
                   VALUES (?,?,?,?,?,?,?,?)""",
                [
                    (
                        a.get("id", ""),
                        a.get("courseId", a.get("course_id", "")),
                        a.get("courseName", a.get("course_name", "")),
                        a.get("title", ""),
                        a.get("description", ""),
                        a.get("dueDate", a.get("due_date")),
                        a.get("status", "未交"),
                        now_iso,
                    )
                    for a in assignments
                ],
            )

        # Cache courses
        try:
            courses = await chaoxing_svc.fetch_courses()
            if courses:
                await db.execute("DELETE FROM chaoxing_courses")
                await db.executemany(
                    """INSERT OR REPLACE INTO chaoxing_courses
                       (id, class_id, cpi, name, teacher, image, synced_at)
                       VALUES (?,?,?,?,?,?,?)""",
                    [
                        (c["id"], c["classId"], c.get("cpi", ""), c["name"],
                         c.get("teacher", ""), c.get("image", ""), now_iso)
                        for c in courses
                    ],
                )
        except Exception as e:
            logger.warning(f"Could not fetch/cache courses: {e}")

        await db.commit()
