"""
APScheduler setup. Runs inside the FastAPI process.
"""
from __future__ import annotations


from apscheduler.schedulers.asyncio import AsyncIOScheduler
from apscheduler.triggers.interval import IntervalTrigger
from apscheduler.triggers.cron import CronTrigger
from apscheduler.triggers.date import DateTrigger
from datetime import datetime, timezone, timedelta

scheduler = AsyncIOScheduler(timezone="Asia/Shanghai")


def init_scheduler(app_state):
    from app.tasks.chaoxing_sync import run_chaoxing_probe_adaptive
    from app.tasks.notification_sender import (
        check_and_send_deadline_notifications,
        check_scheduled_notifications,
        send_daily_begin,
        send_daily_summary_evening,
    )
    from app.tasks.memory_sweep import run_memory_sweep
    from app.tasks.ladder_audit import run_ladder_audit
    from app.dingtalk.task import run_dingtalk_sync
    from app.dingtalk.task import run_dingtalk_memory_task
    from app.tasks.health_monitor import run_health_check

    scheduler.add_job(
        run_chaoxing_probe_adaptive,
        DateTrigger(run_date=datetime.now(timezone.utc) + timedelta(seconds=5)),
        args=[app_state, scheduler],
        id="chaoxing_probe",
        misfire_grace_time=60,
        replace_existing=True,
    )
    scheduler.add_job(
        check_and_send_deadline_notifications,
        IntervalTrigger(seconds=300),
        args=[app_state],
        id="deadline_check",
        misfire_grace_time=60,
        replace_existing=True,
    )
    scheduler.add_job(
        send_daily_begin,
        CronTrigger(hour=7, minute=30),
        args=[app_state],
        id="daily_begin",
        misfire_grace_time=300,
        replace_existing=True,
    )
    scheduler.add_job(
        send_daily_summary_evening,
        CronTrigger(hour=22, minute=0),
        args=[app_state],
        id="daily_summary_evening",
        misfire_grace_time=300,
        replace_existing=True,
    )
    scheduler.add_job(
        run_memory_sweep,
        IntervalTrigger(hours=1),
        args=[app_state],
        id="memory_sweep",
        misfire_grace_time=300,
        replace_existing=True,
    )
    scheduler.add_job(
        run_ladder_audit,
        IntervalTrigger(hours=1),
        args=[app_state],
        id="ladder_audit",
        misfire_grace_time=300,
        replace_existing=True,
    )
    scheduler.add_job(
        check_scheduled_notifications,
        IntervalTrigger(minutes=1),
        args=[app_state],
        id="scheduled_notifications",
        misfire_grace_time=60,
        replace_existing=True,
    )
    scheduler.add_job(
        run_dingtalk_sync,
        IntervalTrigger(seconds=60),
        args=[app_state],
        id="dingtalk_sync",
        max_instances=1,
        coalesce=True,
        misfire_grace_time=60,
        replace_existing=True,
    )
    scheduler.add_job(
        run_health_check,
        IntervalTrigger(minutes=10),
        args=[app_state],
        id="health_monitor",
        max_instances=1,
        misfire_grace_time=120,
        replace_existing=True,
    )
    scheduler.add_job(
        run_dingtalk_memory_task,
        IntervalTrigger(seconds=180),
        args=[app_state],
        id="dingtalk_memory",
        max_instances=1,
        coalesce=True,
        misfire_grace_time=120,
        replace_existing=True,
    )
    scheduler.start()
