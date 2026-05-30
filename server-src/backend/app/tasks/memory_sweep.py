"""
Memory sweep task — runs hourly via APScheduler.
Uses MemoryRepository.sweep() to delete expired entries and cap active count.
"""
import logging
from datetime import datetime, timezone

logger = logging.getLogger("memory_sweep")


async def run_memory_sweep(app_state):
    db_path = app_state.settings.database_path
    try:
        from app.memory.base import MemoryRepository
        repo = MemoryRepository(db_path)
        result = await repo.sweep(datetime.now(timezone.utc))
        logger.debug(
            "Memory sweep: deleted_expired=%d trimmed=%d",
            result["deleted_expired"], result["trimmed"],
        )
    except Exception as e:
        logger.error(f"Memory sweep failed: {e}")
