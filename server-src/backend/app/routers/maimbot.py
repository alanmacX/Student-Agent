"""MaiMBot health monitoring API — uses Docker socket via HTTP."""
from __future__ import annotations

import json
from datetime import datetime, timezone

import httpx
from fastapi import APIRouter
from app.database import db_conn

router = APIRouter(prefix="/api/maimbot", tags=["maimbot"])

CORE_CONTAINER = "maim-bot-core"
NAPCAT_CONTAINER = "maim-bot-napcat"
DOCKER_SOCKET = "/var/run/docker.sock"
NAPCAT_URL = "http://maim-bot-napcat:3000"


def _docker_transport():
    return httpx.AsyncHTTPTransport(uds=DOCKER_SOCKET)


async def _docker_inspect(container: str) -> dict | None:
    try:
        async with httpx.AsyncClient(transport=_docker_transport(), timeout=5.0) as client:
            r = await client.get(f"http://localhost/containers/{container}/json")
            if r.status_code == 200:
                data = r.json()
                return data.get("State", {})
    except Exception:
        pass
    return None


async def _docker_stats(container: str) -> dict | None:
    try:
        async with httpx.AsyncClient(transport=_docker_transport(), timeout=10.0) as client:
            r = await client.get(f"http://localhost/containers/{container}/stats?stream=false")
            if r.status_code == 200:
                return r.json()
    except Exception:
        pass
    return None


def _calc_cpu_percent(stats: dict) -> float:
    """Calculate CPU % from Docker stats JSON."""
    try:
        cpu = stats.get("cpu_stats", {})
        precpu = stats.get("precpu_stats", {})
        cpu_delta = cpu["cpu_usage"]["total_usage"] - precpu["cpu_usage"]["total_usage"]
        sys_delta = cpu["system_cpu_usage"] - precpu["system_cpu_usage"]
        n_cpus = cpu.get("online_cpus", 1)
        if sys_delta > 0:
            return round((cpu_delta / sys_delta) * n_cpus * 100, 1)
    except (KeyError, ZeroDivisionError, TypeError):
        pass
    return 0


def _calc_mem_mb(stats: dict) -> tuple[float, float]:
    """Return (usage_mb, limit_mb) from Docker stats JSON."""
    try:
        mem = stats.get("memory_stats", {})
        usage = mem.get("usage", 0) - mem.get("stats", {}).get("cache", 0)
        limit = mem.get("limit", 0)
        return round(usage / (1024 * 1024), 1), round(limit / (1024 * 1024), 1)
    except (KeyError, TypeError):
        pass
    return 0, 0


async def _docker_logs(container: str, lines: int = 50) -> str:
    try:
        async with httpx.AsyncClient(transport=_docker_transport(), timeout=10.0) as client:
            r = await client.get(
                f"http://localhost/containers/{container}/logs",
                params={"tail": str(lines), "timestamps": "true", "stdout": "true", "stderr": "true"},
            )
            if r.status_code == 200:
                # Docker log stream has 8-byte header per frame
                raw = r.content
                output = []
                i = 0
                while i < len(raw):
                    if i + 8 <= len(raw):
                        # stream_type = raw[i]  # 1=stdout, 2=stderr
                        sz = int.from_bytes(raw[i + 4:i + 8], "big")
                        i += 8
                        if i + sz <= len(raw):
                            output.append(raw[i:i + sz].decode("utf-8", errors="replace"))
                            i += sz
                        else:
                            break
                    else:
                        break
                return "".join(output)
    except Exception as e:
        return f"Error: {e}"
    return ""


async def _check_napcat() -> bool:
    try:
        async with httpx.AsyncClient(timeout=5.0) as client:
            r = await client.get(f"{NAPCAT_URL}/get_group_list")
            return r.status_code == 200
    except Exception:
        return False


@router.get("/status")
async def get_status():
    """Comprehensive MaiMBot status."""
    core_state = await _docker_inspect(CORE_CONTAINER)
    napcat_state = await _docker_inspect(NAPCAT_CONTAINER)

    core_running = bool(core_state and core_state.get("Running"))
    napcat_running = bool(napcat_state and napcat_state.get("Running"))
    napcat_alive = await _check_napcat() if napcat_running else False

    core_stats = await _docker_stats(CORE_CONTAINER) if core_running else None
    napcat_stats = await _docker_stats(NAPCAT_CONTAINER) if napcat_running else None

    core_cpu = _calc_cpu_percent(core_stats) if core_stats else 0
    core_mem, core_limit = _calc_mem_mb(core_stats) if core_stats else (0, 0)
    napcat_cpu = _calc_cpu_percent(napcat_stats) if napcat_stats else 0
    napcat_mem, napcat_limit = _calc_mem_mb(napcat_stats) if napcat_stats else (0, 0)

    core_mem_pct = round((core_mem / core_limit * 100), 1) if core_limit > 0 else 0
    napcat_mem_pct = round((napcat_mem / napcat_limit * 100), 1) if napcat_limit > 0 else 0

    async with db_conn() as db:
        recent = await (await db.execute(
            "SELECT * FROM maimbot_health_log ORDER BY checked_at DESC LIMIT 20"
        )).fetchall()

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
            "cpu_percent": core_cpu,
            "mem_percent": core_mem_pct,
            "mem_usage": f"{core_mem}MiB / {core_limit}MiB" if core_limit > 0 else "",
        },
        "napcat": {
            "running": napcat_running,
            "api_alive": napcat_alive,
            "status": napcat_state.get("Status", "") if napcat_state else "not_found",
            "started_at": napcat_state.get("StartedAt", "") if napcat_state else "",
            "cpu_percent": napcat_cpu,
            "mem_percent": napcat_mem_pct,
            "mem_usage": f"{napcat_mem}MiB / {napcat_limit}MiB" if napcat_limit > 0 else "",
        },
        "healthy": core_running and napcat_running and napcat_alive,
        "recent_checks": [dict(r) for r in recent],
        "error_count_1h": err_row["cnt"] if err_row else 0,
        "checked_at": datetime.now(timezone.utc).isoformat(),
    }


@router.get("/logs")
async def get_logs(container: str = "core", lines: int = 100):
    name = CORE_CONTAINER if container == "core" else NAPCAT_CONTAINER
    return {"logs": await _docker_logs(name, min(lines, 500))}


@router.post("/restart")
async def restart_container(container: str = "core"):
    name = CORE_CONTAINER if container == "core" else NAPCAT_CONTAINER
    try:
        async with httpx.AsyncClient(transport=_docker_transport(), timeout=30.0) as client:
            r = await client.post(f"http://localhost/containers/{name}/restart?t=10")
            if r.status_code in (200, 204):
                return {"ok": True, "message": f"{name} restarted"}
            return {"ok": False, "error": f"HTTP {r.status_code}"}
    except Exception as e:
        return {"ok": False, "error": str(e)}


@router.get("/config")
async def get_config():
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
