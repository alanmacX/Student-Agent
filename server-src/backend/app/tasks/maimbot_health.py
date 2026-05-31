"""MaiMBot health check task — runs every 5 minutes."""
from __future__ import annotations

import json
import subprocess
import logging

from app.database import db_conn

log = logging.getLogger("maimbot_health")

CORE_CONTAINER = "maim-bot-core"
NAPCAT_CONTAINER = "maim-bot-napcat"
NAPCAT_URL = "http://host.docker.internal:6099"
MAX_LOG_ROWS = 100


def _docker_running(container: str) -> bool:
    try:
        r = subprocess.run(
            ["docker", "inspect", "--format", "{{.State.Running}}", container],
            capture_output=True, text=True, timeout=5,
        )
        return r.stdout.strip() == "true"
    except Exception:
        return False


def _docker_cpu_mem(container: str) -> tuple[float, float]:
    """Return (cpu_percent, mem_mb) for a container."""
    try:
        r = subprocess.run(
            ["docker", "stats", "--no-stream", "--format",
             "{{.CPUPerc}}|{{.MemUsage}}", container],
            capture_output=True, text=True, timeout=10,
        )
        if r.returncode != 0 or not r.stdout.strip():
            return 0, 0
        parts = r.stdout.strip().split("|")
        cpu = float(parts[0].rstrip("%")) if parts[0] else 0
        # MemUsage format: "123.4MiB / 7.5GiB" — parse first part
        mem_str = parts[1].split("/")[0].strip() if len(parts) > 1 else "0"
        if "GiB" in mem_str:
            mem = float(mem_str.replace("GiB", "").strip()) * 1024
        elif "MiB" in mem_str:
            mem = float(mem_str.replace("MiB", "").strip())
        elif "KiB" in mem_str:
            mem = float(mem_str.replace("KiB", "").strip()) / 1024
        else:
            mem = 0
        return round(cpu, 1), round(mem, 1)
    except Exception:
        return 0, 0


def _check_napcat() -> bool:
    try:
        r = subprocess.run(
            ["curl", "-s", "-o", "/dev/null", "-w", "%{http_code}",
             "--connect-timeout", "3", f"{NAPCAT_URL}/get_group_list"],
            capture_output=True, text=True, timeout=5,
        )
        return r.stdout.strip() == "200"
    except Exception:
        return False


async def run_maimbot_health_check(app_state):
    """Scheduled every 5 minutes. Checks MaiMBot container health."""
    db_path = app_state.settings.database_path

    # Check if monitoring is enabled
    async with db_conn() as db:
        row = await (await db.execute(
            "SELECT value FROM settings WHERE key='maimbot_enabled'"
        )).fetchone()
    enabled = row and row["value"] not in ("0", "false", "no", "")
    if not enabled:
        return

    core_running = _docker_running(CORE_CONTAINER)
    napcat_running = _docker_running(NAPCAT_CONTAINER)
    napcat_alive = _check_napcat() if napcat_running else False

    core_cpu, core_ram = _docker_cpu_mem(CORE_CONTAINER) if core_running else (0, 0)
    napcat_cpu, napcat_ram = _docker_cpu_mem(NAPCAT_CONTAINER) if napcat_running else (0, 0)

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
        # Trim old entries
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
