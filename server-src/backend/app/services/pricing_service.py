"""External model pricing via OpenRouter API with 24h cache."""
from __future__ import annotations

import logging
import time

logger = logging.getLogger("pricing")

_OPENROUTER_MODELS_URL = "https://openrouter.ai/api/v1/models"
_CACHE_TTL = 86400  # 24 hours

_cache: dict = {"data": {}, "ts": 0}


async def fetch_openrouter_pricing() -> dict[str, tuple[float, float]]:
    """Fetch model pricing from OpenRouter. Returns {model_id: (input_per_1M, output_per_1M)} in USD."""
    import httpx

    now = time.time()
    if now - _cache["ts"] < _CACHE_TTL and _cache["data"]:
        return _cache["data"]

    try:
        async with httpx.AsyncClient(timeout=15.0) as client:
            r = await client.get(_OPENROUTER_MODELS_URL)
            r.raise_for_status()
            models = r.json().get("data", [])

        pricing = {}
        for m in models:
            mid = m.get("id", "")
            p = m.get("pricing", {})
            inp = float(p.get("prompt", 0)) * 1_000_000  # per-token → per-1M
            out = float(p.get("completion", 0)) * 1_000_000
            if inp > 0 or out > 0:
                pricing[mid] = (inp, out)

        _cache["data"] = pricing
        _cache["ts"] = now
        logger.info("Fetched %d model prices from OpenRouter", len(pricing))
        return pricing
    except Exception as e:
        logger.warning("OpenRouter fetch failed: %s", e)
        return _cache["data"]  # return stale cache if available


def bust_cache():
    """Force next fetch to re-query OpenRouter."""
    _cache["ts"] = 0
