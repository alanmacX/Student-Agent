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
        max_interval = app_state.settings.chaoxing_sync_interval
        next_interval = min(next_interval, max_interval)

        now = datetime.now(timezone.utc)

        # ── Step 1: Sync assignments + reminders into unified memory (no LLM) ─
        # This always runs so memory stays consistent with the live data even
        # if the LLM extraction below fails.
        try:
            from app.services.memory_sync import sync_to_memory
            from app.services.schedule_store import list_reminders

            # Cache assignments and courses for sidebar (no live API calls)
            try:
                await _cache_chaoxing_data(
                    app_state.chaoxing_svc, app_state.settings.database_path, assignments, now
                )
            except Exception as e:
                logger.warning(f"Could not cache chaoxing data: {e}")

            reminders = []
            try:
                reminders = await list_reminders(app_state.settings.database_path)
            except Exception as e:
                logger.warning(f"Could not fetch reminders for memory sync: {e}")

            sync_result = await sync_to_memory(
                assignments, reminders, app_state.settings.database_path, now
            )
            logger.debug(
                f"Memory sync: {sync_result['upserted']} upserted, "
                f"{sync_result['archived']} archived, {sync_result['linked']} linked"
            )
        except Exception as e:
            logger.error(f"Memory sync failed: {e}", exc_info=True)

        # ── Step 2: LLM extraction of Chaoxing messages → kind='message' ─────
        try:
            from app.services.provider_registry import resolve_provider
            provider, api_key = await resolve_provider(
                app_state.settings.standby_agent_provider or "openai"
            )
            model = app_state.settings.standby_agent_model or "gpt-4o-mini"
            result = await run_chaoxing_memory_sync(
                app_state.chaoxing_svc,
                app_state.settings.database_path,
                provider, model, api_key,
                assignments=assignments,
                now=now,
            )
            logger.debug(
                f"Chaoxing memory: {result.get('candidate_count', 0)} candidates, "
                f"{result.get('processed_count', 0)} processed"
            )
            new_entry_ids = result.get("new_entry_ids") or []
            if new_entry_ids:
                from app.services.notification_scheduler import (
                    auto_schedule_from_memory,
                    fetch_memory_entries_by_ids,
                )
                entries = await fetch_memory_entries_by_ids(
                    app_state.settings.database_path,
                    new_entry_ids,
                )
                scheduled_count = await auto_schedule_from_memory(
                    entries,
                    app_state.settings.database_path,
                    provider, model, api_key,
                    now,
                )
                if scheduled_count:
                    logger.debug(f"Scheduled {scheduled_count} notifications from memory")

            # ── Step 2.5: regenerate dashboard briefing (data-change gated) ──
            try:
                from app.services.dashboard_briefing import generate_and_store
                await generate_and_store(
                    app_state.settings.database_path,
                    provider, model, api_key, now,
                )
            except Exception as e:
                logger.error(f"Dashboard briefing failed in probe: {e}")
        except Exception as e:
            logger.error(f"Memory agent (LLM) failed in probe: {e}")

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
