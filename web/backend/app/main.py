from contextlib import asynccontextmanager
from fastapi import FastAPI
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


@app.get("/health")
async def health():
    return {"status": "ok", "chaoxing_logged_in": app.state.chaoxing_svc.is_logged_in}


from app.routers import conversations, chat, schedule, chaoxing, providers, settings as settings_router, push, reminders, data
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

if settings.debug:
    from app.routers.debug import router as debug_router
    app.include_router(debug_router)
    print("⚠️  Debug endpoints enabled at /api/debug/*")
