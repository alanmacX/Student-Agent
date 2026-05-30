from __future__ import annotations
import json
from typing import Any

from app.config import settings
from app.database import db_conn


BUILTIN_PROVIDERS: list[dict[str, Any]] = [
    {
        "id": "xiaomimimo",
        "name": "小米 MiMo",
        "api_type": "xiaomiMimo",
        "base_url": "https://token-plan-sgp.xiaomimimo.com/v1",
        "models": ["mimo-v2.5-pro"],
        "icon_name": "m-circle",
        "color_hex": "FF6900",
        "is_builtin": True,
    },
]

PROVIDER_ALIASES = {
    "mimo": "xiaomimimo",
    # Legacy defaults now route to the only configured provider.
    "openai": "xiaomimimo",
    "anthropic": "xiaomimimo",
    "gemini": "xiaomimimo",
}

API_KEY_SETTINGS = {
    "xiaomimimo": ("mimo_api_key", "mimo_api_key"),
}


def normalize_provider_id(provider_id: str | None) -> str:
    provider_id = (provider_id or "openai").strip()
    return PROVIDER_ALIASES.get(provider_id, provider_id)


async def list_custom_providers() -> list[dict[str, Any]]:
    async with db_conn() as db:
        rows = await (await db.execute("SELECT id, data_json FROM custom_providers")).fetchall()
    providers = []
    for row in rows:
        try:
            data = json.loads(row["data_json"])
        except json.JSONDecodeError:
            continue
        providers.append(
            {
                "id": row["id"],
                "is_builtin": False,
                "icon_name": data.get("icon_name", "network"),
                "color_hex": data.get("color_hex", "6B7280"),
                **data,
            }
        )
    return providers


async def list_all_providers() -> dict[str, list[dict[str, Any]]]:
    return {
        "builtin": [dict(provider) for provider in BUILTIN_PROVIDERS],
        "custom": await list_custom_providers(),
    }


async def get_provider_config(provider_id: str | None) -> dict[str, Any] | None:
    normalized = normalize_provider_id(provider_id)
    for provider in BUILTIN_PROVIDERS:
        if provider["id"] == normalized:
            return dict(provider)

    for provider in await list_custom_providers():
        if provider["id"] == normalized:
            return provider

    return None


async def get_setting_value(key: str) -> str:
    async with db_conn() as db:
        row = await (await db.execute("SELECT value FROM settings WHERE key=?", (key,))).fetchone()
    if not row:
        return ""
    value = row["value"]
    return value if isinstance(value, str) else str(value)


async def get_provider_api_key(provider_id: str | None, provider: dict[str, Any] | None = None) -> str:
    provider = provider or await get_provider_config(provider_id)
    if not provider:
        return ""

    if not provider.get("is_builtin", False):
        return provider.get("api_key", "")

    normalized = normalize_provider_id(provider.get("id") or provider_id)
    db_key, settings_attr = API_KEY_SETTINGS.get(normalized, ("", ""))
    if not db_key:
        return ""

    saved = (await get_setting_value(db_key)).strip()
    if saved:
        return saved
    return getattr(settings, settings_attr, "") or ""


async def resolve_provider(provider_id: str | None) -> tuple[dict[str, Any], str]:
    provider = await get_provider_config(provider_id) or dict(BUILTIN_PROVIDERS[0])
    api_key = await get_provider_api_key(provider_id, provider)
    return provider, api_key
