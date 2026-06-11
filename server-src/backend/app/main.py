from __future__ import annotations

from contextlib import asynccontextmanager
from fastapi import FastAPI
from fastapi.responses import JSONResponse
from fastapi.middleware.cors import CORSMiddleware
from app.services.api_service import init_http_client, close_http_client
from app.services.chaoxing_service import ChaoxingService
from app.database import run_migrations
from app.config import settings
from app.tasks.scheduler import init_scheduler, scheduler


@asynccontextmanager
async def lifespan(app: FastAPI):
    await run_migrations(settings.database_path)
    await init_http_client()

    chaoxing_svc = ChaoxingService(settings.database_path)
    await chaoxing_svc.init()
    app.state.chaoxing_svc = chaoxing_svc
    app.state.settings = settings

    # Pre-warm model pricing cache from OpenRouter
    from app.services.pricing_service import fetch_openrouter_pricing
    import asyncio
    asyncio.create_task(fetch_openrouter_pricing())

    init_scheduler(app.state)

    yield

    scheduler.shutdown(wait=False)
    await close_http_client()


app = FastAPI(title="ChatBot API", lifespan=lifespan)

app.add_middleware(
    CORSMiddleware,
    allow_origins=["*"],
    allow_methods=["*"],
    allow_headers=["*"],
)


PUBLIC_API_PATHS = {
    "/api/push/vapid-public-key",
    "/api/push/received",
    "/api/push/clicked",
    "/api/push/dismissed",
    "/api/notifications/feedback",
}


@app.middleware("http")
async def access_token_middleware(request, call_next):
    token = (settings.access_token or "").strip()
    path = request.url.path
    if token and path.startswith("/api/") and path not in PUBLIC_API_PATHS:
        supplied = request.query_params.get("token") or ""
        auth = request.headers.get("authorization") or ""
        if auth.lower().startswith("bearer "):
            supplied = auth[7:].strip()
        if supplied != token:
            return JSONResponse({"error": "unauthorized"}, status_code=401)
    return await call_next(request)


@app.get("/health")
async def health():
    return {"status": "ok", "chaoxing_logged_in": app.state.chaoxing_svc.is_logged_in}


@app.get("/api/health/detail")
async def health_detail():
    import time as _time
    result = {"backend": "ok"}
    try:
        import psutil
        result["cpu_percent"] = round(psutil.cpu_percent(interval=0.3), 1)
        result["ram_percent"] = round(psutil.virtual_memory().percent, 1)
        result["disk_percent"] = round(psutil.disk_usage("/").percent, 1)
        result["uptime_hours"] = round((_time.time() - psutil.boot_time()) / 3600, 1)
    except Exception:
        result["cpu_percent"] = result["ram_percent"] = result["disk_percent"] = result["uptime_hours"] = None
    # DingTalk WAL status
    try:
        from app.tasks.health_monitor import WAL_PATH, WAL_STALE_SECONDS
        import os
        mtime = os.path.getmtime(WAL_PATH)
        age_min = int((_time.time() - mtime) / 60)
        result["dingtalk"] = {
            "status": "alive" if (_time.time() - mtime) < WAL_STALE_SECONDS else "stale",
            "wal_age_minutes": age_min,
        }
    except Exception:
        result["dingtalk"] = {"status": "unknown"}
    # Chaoxing
    result["chaoxing"] = {"logged_in": getattr(app.state.chaoxing_svc, "is_logged_in", False)}
    return result


from app.routers import conversations, chat, schedule, chaoxing, providers, settings as settings_router, push, reminders, data, analytics, dashboard, agent_quick
from app.dingtalk.router import router as dingtalk_router

app.include_router(conversations.router)
app.include_router(chat.router)
app.include_router(schedule.router)
app.include_router(chaoxing.router)
app.include_router(providers.router)
app.include_router(settings_router.router)
app.include_router(push.router)
app.include_router(push.notifications_router)
app.include_router(reminders.router)
app.include_router(data.router)
app.include_router(dingtalk_router)
app.include_router(analytics.router)
app.include_router(dashboard.router)
app.include_router(agent_quick.router)

if settings.debug:
    from app.routers.debug import router as debug_router
    app.include_router(debug_router)
    print("⚠️  Debug endpoints enabled at /api/debug/*")
