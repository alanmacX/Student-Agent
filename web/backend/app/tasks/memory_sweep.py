"""
Memory sweep task — runs hourly via APScheduler.
Calls run_memory_maintenance() to archive stale/expired memory entries
and keep the total count bounded.
"""
import logging

logger = logging.getLogger("memory_agent")


async def run_memory_sweep(app_state):
    db_path = app_state.settings.database_path
    try:
        from app.services.memory_agent import run_memory_maintenance
        await run_memory_maintenance(db_path)
        logger.debug("Memory sweep completed")
    except Exception as e:
        logger.error(f"Memory sweep failed: {e}")
