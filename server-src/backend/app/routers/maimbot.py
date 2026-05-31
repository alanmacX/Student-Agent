"""MaiMBot health monitoring API."""
from __future__ import annotations

import json
import subprocess
from datetime import datetime, timezone

from fastapi import APIRouter
from app.database import db_conn

router = APIRouter(prefix="/api/maimbot", tags=["maimbot"])

CORE_CONTAINER = "maim-bot-core"
NAPCAT_CONTAINER = "maim-bot-napcat"
NAPCAT_URL = "http://host.docker.internal:6099"


def _docker_inspect(container: str) -> dict | None:
    """Get container state via docker inspect."""
    try:
        r = subprocess.run(
            ["docker", "inspect", "--format", '{{json .State}}', container],
            capture_output=True, text=True, timeout=5,
        )
        if r.returncode == 0:
            return json.loads(r.stdout.strip())
    except Exception:
        pass
    return None


def _docker_stats(container: str) -> dict | None:
    """Get container CPU/RAM via docker stats (one-shot)."""
    try:
        r = subprocess.run(
            ["docker", "stats", "--no-stream", "--format",
             '{"cpu":"{{.CPUPerc}}","mem":"{{.MemUsage}}","mem_pct":"{{.MemPerc}}"}',
             container],
            capture_output=True, text=True, timeout=10,
        )
        if r.returncode == 0 and r.stdout.strip():
            return json.loads(r.stdout.strip())
    except Exception:
        pass
    return None


def _docker_logs(container: str, lines: int = 50) -> str:
    """Get recent container logs."""
    try:
        r = subprocess.run(
            ["docker", "logs", "--tail", str(lines), "--timestamps", container],
            capture_output=True, text=True, timeout=10,
        )
        return r.stderr or r.stdout
    except Exception as e:
        return f"Error: {e}"


def _check_napcat() -> bool:
    """Check if NapCat HTTP API is reachable."""
    try:
        r = subprocess.run(
            ["curl", "-s", "-o", "/dev/null", "-w", "%{http_code}",
             "--connect-timeout", "3", f"{NAPCAT_URL}/get_group_list"],
            capture_output=True, text=True, timeout=5,
        )
        return r.stdout.strip() == "200"
    except Exception:
        return False


@router.get("/status")
async def get_status():
    """Comprehensive MaiMBot status."""
    core_state = _docker_inspect(CORE_CONTAINER)
    napcat_state = _docker_inspect(NAPCAT_CONTAINER)

    core_running = bool(core_state and core_state.get("Running"))
    napcat_running = bool(napcat_state and napcat_state.get("Running"))
    napcat_alive = _check_napcat() if napcat_running else False

    # Resource usage
    core_stats = _docker_stats(CORE_CONTAINER) if core_running else None
    napcat_stats = _docker_stats(NAPCAT_CONTAINER) if napcat_running else None

    def _parse_mem_pct(stats):
        if not stats:
            return 0
        try:
            return float(stats.get("mem_pct", "0%").rstrip("%"))
        except (ValueError, TypeError):
            return 0

    def _parse_cpu(stats):
        if not stats:
            return 0
        try:
            return float(stats.get("cpu", "0%").rstrip("%"))
        except (ValueError, TypeError):
            return 0

    # Recent health log
    async with db_conn() as db:
        recent = await (await db.execute(
            "SELECT * FROM maimbot_health_log ORDER BY checked_at DESC LIMIT 20"
        )).fetchall()

    # Error count in last hour
    async with db_conn() as db:
        err_row = await (await db.execute(
            "SELECT COUNT(*) as cnt FROM maimbot_health_log "
            "WHERE error != '' AND checked_at > datetime('now', '-1 hour')"
        )).fetchone()

    return {
        "core": {
            "running": core_running,
            "status": core_state.get("Status", "") if core_state else "not_found",
            "started_at": core_state.get("StartedAt", "") if core_state else "",
            "cpu_percent": _parse_cpu(core_stats),
            "mem_percent": _parse_mem_pct(core_stats),
            "mem_usage": core_stats.get("mem", "") if core_stats else "",
        },
        "napcat": {
            "running": napcat_running,
            "api_alive": napcat_alive,
            "status": napcat_state.get("Status", "") if napcat_state else "not_found",
            "started_at": napcat_state.get("StartedAt", "") if napcat_state else "",
            "cpu_percent": _parse_cpu(napcat_stats),
            "mem_percent": _parse_mem_pct(napcat_stats),
            "mem_usage": napcat_stats.get("mem", "") if napcat_stats else "",
        },
        "healthy": core_running and napcat_running and napcat_alive,
        "recent_checks": [dict(r) for r in recent],
        "error_count_1h": err_row["cnt"] if err_row else 0,
        "checked_at": datetime.now(timezone.utc).isoformat(),
    }


@router.get("/logs")
async def get_logs(container: str = "core", lines: int = 100):
    """Get recent container logs."""
    name = CORE_CONTAINER if container == "core" else NAPCAT_CONTAINER
    return {"logs": _docker_logs(name, min(lines, 500))}


@router.post("/restart")
async def restart_container(container: str = "core"):
    """Restart a MaiMBot container."""
    name = CORE_CONTAINER if container == "core" else NAPCAT_CONTAINER
    try:
        r = subprocess.run(
            ["docker", "restart", name],
            capture_output=True, text=True, timeout=30,
        )
        if r.returncode == 0:
            return {"ok": True, "message": f"{name} restarted"}
        return {"ok": False, "error": r.stderr.strip()}
    except Exception as e:
        return {"ok": False, "error": str(e)}


@router.get("/config")
async def get_config():
    """Read MaiMBot configuration files."""
    import os
    config_dir = "/maimbot_data/MaiMBot"
    configs = {}
    try:
        for fname in os.listdir(config_dir):
            fpath = os.path.join(config_dir, fname)
            if os.path.isfile(fpath) and fname.endswith((".yml", ".yaml", ".json", ".toml", ".env", ".cfg")):
                try:
                    with open(fpath, "r") as f:
                        configs[fname] = f.read()
                except Exception:
                    configs[fname] = "(read error)"
    except FileNotFoundError:
        return {"error": "MaiMBot data directory not found", "configs": {}}
    return {"configs": configs, "config_dir": config_dir}
