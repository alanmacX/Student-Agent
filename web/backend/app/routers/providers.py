from fastapi import APIRouter, Request
from app.database import db_conn
from app.models import CustomProviderCreate
from app.services.api_service import fetch_balance, check_reachability, fetch_models
from app.services.provider_registry import (
    list_all_providers,
    get_provider_api_key,
    get_provider_config,
)
import json
import uuid

router = APIRouter(prefix="/api/providers", tags=["providers"])


@router.get("")
async def list_providers():
    return await list_all_providers()


@router.post("")
async def create_provider(request: Request):
    body = await request.json()
    required = ["name", "base_url", "api_key"]
    if not all(body.get(k) for k in required):
        return {"error": "name, base_url, api_key required"}
    provider_id = body.get("id") or f"custom-{uuid.uuid4().hex[:8]}"
    data = {
        "id": provider_id,
        "name": body["name"],
        "base_url": body["base_url"].rstrip("/"),
        "api_key": body["api_key"],
        "api_type": body.get("api_type", "openAI"),
        "models": body.get("models", []),
    }
    async with db_conn() as db:
        await db.execute(
            "INSERT OR REPLACE INTO custom_providers (id, data_json) VALUES (?,?)",
            (provider_id, json.dumps(data)),
        )
        await db.commit()
    return {"ok": True, "id": provider_id}


@router.post("/custom")
async def add_custom_provider(body: CustomProviderCreate):
    async with db_conn() as db:
        data = {
            "name": body.name,
            "api_type": body.api_type,
            "base_url": body.base_url,
            "api_key": body.api_key,
            "models": body.models,
        }
        await db.execute(
            "INSERT OR REPLACE INTO custom_providers (id, data_json) VALUES (?,?)",
            (body.id, json.dumps(data)),
        )
        await db.commit()
        return {"ok": True}


@router.patch("/{provider_id}")
async def update_provider(provider_id: str, request: Request):
    body = await request.json()
    async with db_conn() as db:
        row = await (await db.execute(
            "SELECT data_json FROM custom_providers WHERE id=?", (provider_id,)
        )).fetchone()
        if not row:
            return {"error": "not found"}
        data = json.loads(row[0])
        for k in ["name", "base_url", "api_key", "models", "api_type"]:
            if k in body:
                data[k] = body[k]
        await db.execute(
            "UPDATE custom_providers SET data_json=? WHERE id=?",
            (json.dumps(data), provider_id),
        )
        await db.commit()
    return {"ok": True}


@router.delete("/{provider_id}")
async def delete_provider(provider_id: str):
    async with db_conn() as db:
        await db.execute("DELETE FROM custom_providers WHERE id=?", (provider_id,))
        await db.commit()
    return {"ok": True}


@router.delete("/custom/{provider_id}")
async def delete_custom_provider(provider_id: str):
    async with db_conn() as db:
        await db.execute("DELETE FROM custom_providers WHERE id=?", (provider_id,))
        await db.commit()
        return {"ok": True}


@router.post("/{provider_id}/fetch-models")
async def fetch_provider_models(provider_id: str, request: Request):
    body = await request.json()
    base_url = (body.get("base_url") or "").rstrip("/")
    api_key = body.get("api_key") or ""
    if not base_url or not api_key:
        async with db_conn() as db:
            row = await (await db.execute(
                "SELECT data_json FROM custom_providers WHERE id=?", (provider_id,)
            )).fetchone()
        if row:
            data = json.loads(row[0])
            base_url = base_url or data.get("base_url", "")
            api_key = api_key or data.get("api_key", "")
    try:
        import httpx
        async with httpx.AsyncClient(timeout=10) as client:
            r = await client.get(
                f"{base_url}/v1/models",
                headers={"Authorization": f"Bearer {api_key}"},
            )
            r.raise_for_status()
            data = r.json()
        model_ids = [m["id"] for m in data.get("data", [])]
        return {"ok": True, "models": model_ids}
    except Exception as e:
        return {"ok": False, "error": str(e), "models": []}


@router.get("/{provider_id}/balance")
async def get_balance(provider_id: str):
    provider = await get_provider_config(provider_id)
    api_key = await get_provider_api_key(provider_id, provider)
    if not api_key or not provider:
        return {"error": "provider not configured"}
    balance = await fetch_balance(api_key, provider["base_url"], provider["api_type"])
    return {"balance": balance}


@router.get("/{provider_id}/reachability")
async def check_provider(provider_id: str):
    provider = await get_provider_config(provider_id)
    api_key = await get_provider_api_key(provider_id, provider)
    if not provider:
        return {"error": "provider not found"}
    reachable = await check_reachability(api_key or "", provider["base_url"], provider["api_type"])
    return {"reachable": reachable}


@router.get("/{provider_id}/models")
async def list_models(provider_id: str):
    provider = await get_provider_config(provider_id)
    api_key = await get_provider_api_key(provider_id, provider)
    if not api_key or not provider:
        return {"models": provider.get("models", []) if provider else []}
    models = await fetch_models(api_key, provider["base_url"], provider["api_type"])
    if not models:
        models = provider.get("models", [])
    return {"models": models}
