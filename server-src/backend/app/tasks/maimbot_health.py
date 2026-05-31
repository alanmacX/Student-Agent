"""MaiMBot health check task — runs every 5 minutes. Uses Docker socket API."""
from __future__ import annotations

import logging

import httpx
from app.database import db_conn

log = logging.getLogger("maimbot_health")

CORE_CONTAINER = "maim-bot-core"
NAPCAT_CONTAINER = "maim-bot-napcat"
DOCKER_SOCKET = "/var/run/docker.sock"
NAPCAT_URL = "http://maim-bot-napcat:3000"
MAX_LOG_ROWS = 100


def _transport():
    return httpx.AsyncHTTPTransport(uds=DOCKER_SOCKET)


async def _is_running(container: str) -> bool:
    try:
        async with httpx.AsyncClient(transport=_transport(), timeout=5.0) as client:
            r = await client.get(f"http://localhost/containers/{container}/json")
            if r.status_code == 200:
                return r.json().get("State", {}).get("Running", False)
    except Exception:
        pass
    return False


async def _cpu_mem(container: str) -> tuple[float, float]:
    """Return (cpu_percent, mem_mb)."""
    try:
        async with httpx.AsyncClient(transport=_transport(), timeout=10.0) as client:
            r = await client.get(f"http://localhost/containers/{container}/stats?stream=false")
            if r.status_code != 200:
                return 0, 0
            stats = r.json()

        # CPU
        cpu = stats.get("cpu_stats", {})
        precpu = stats.get("precpu_stats", {})
        cpu_delta = cpu["cpu_usage"]["total_usage"] - precpu["cpu_usage"]["total_usage"]
        sys_delta = cpu["system_cpu_usage"] - precpu["system_cpu_usage"]
        n_cpus = cpu.get("online_cpus", 1)
        cpu_pct = round((cpu_delta / sys_delta) * n_cpus * 100, 1) if sys_delta > 0 else 0

        # Memory
        mem = stats.get("memory_stats", {})
        usage = mem.get("usage", 0) - mem.get("stats", {}).get("cache", 0)
        mem_mb = round(usage / (1024 * 1024), 1)

        return cpu_pct, mem_mb
    except Exception:
        return 0, 0


async def _check_napcat() -> bool:
    try:
        async with httpx.AsyncClient(timeout=5.0) as client:
            r = await client.get(f"{NAPCAT_URL}/get_group_list")
            return r.status_code == 200
    except Exception:
        return False


async def run_maimbot_health_check(app_state):
    """Scheduled every 5 minutes. Checks MaiMBot container health."""
    db_path = app_state.settings.database_path

    async with db_conn() as db:
        row = await (await db.execute(
            "SELECT value FROM settings WHERE key='maimbot_enabled'"
        )).fetchone()
    enabled = row and row["value"] not in ("0", "false", "no", "")
    if not enabled:
        return

    core_running = await _is_running(CORE_CONTAINER)
    napcat_running = await _is_running(NAPCAT_CONTAINER)
    napcat_alive = await _check_napcat() if napcat_running else False

    core_cpu, core_ram = await _cpu_mem(CORE_CONTAINER) if core_running else (0, 0)
    napcat_cpu, napcat_ram = await _cpu_mem(NAPCAT_CONTAINER) if napcat_running else (0, 0)

    errors = []
    if not core_running:
        errors.append("core not running")
    if not napcat_running:
        errors.append("napcat not running")
    if napcat_running and not napcat_alive:
        errors.append("napcat API unreachable")
    error_str = "; ".join(errors)

    async with db_conn() as db:
        await db.execute(
            """INSERT INTO maimbot_health_log
               (core_running, napcat_running, napcat_alive,
                core_cpu, core_ram_mb, napcat_cpu, napcat_ram_mb, error)
               VALUES (?, ?, ?, ?, ?, ?, ?, ?)""",
            (int(core_running), int(napcat_running), int(napcat_alive),
             core_cpu, core_ram, napcat_cpu, napcat_ram, error_str),
        )
        await db.execute(
            "DELETE FROM maimbot_health_log WHERE id NOT IN "
            "(SELECT id FROM maimbot_health_log ORDER BY checked_at DESC LIMIT ?)",
            (MAX_LOG_ROWS,),
        )
        await db.commit()

    if errors:
        log.warning("MaiMBot health: %s", error_str)
    else:
        log.debug("MaiMBot health: OK (core=%.0fMB, napcat=%.0fMB)", core_ram, napcat_ram)
