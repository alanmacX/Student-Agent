from __future__ import annotations

from fastapi import APIRouter

from app.services.dashboard_v2 import dashboard_today

router = APIRouter(prefix="/api/dashboard", tags=["dashboard"])


@router.get("/today")
async def dashboard_today_route():
    return await dashboard_today()
