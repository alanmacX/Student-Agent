"""Token usage analytics endpoint."""
from __future__ import annotations

import json
from collections import defaultdict
from datetime import datetime, timedelta, timezone

from fastapi import APIRouter, Query, Request
from app.database import db_conn
from app.services.api_service import estimate_cost, KNOWN_PRICING

router = APIRouter(prefix="/api/analytics", tags=["analytics"])


def _parse_usage(usage_json: str | None) -> dict:
    if not usage_json:
        return {"input_tokens": 0, "output_tokens": 0, "model": "", "provider": ""}
    try:
        d = json.loads(usage_json)
        return {
            "input_tokens": d.get("input_tokens", 0),
            "output_tokens": d.get("output_tokens", 0),
            "model": d.get("model", ""),
            "provider": d.get("provider", ""),
        }
    except (json.JSONDecodeError, TypeError):
        return {"input_tokens": 0, "output_tokens": 0, "model": "", "provider": ""}


async def _add_cost(entry: dict, model: str, provider: str = ""):
    """Add cost_usd to entry in-place."""
    cost = await estimate_cost(model, entry.get("input_tokens", 0), entry.get("output_tokens", 0), provider)
    entry["cost_usd"] = round(cost, 6) if cost else 0.0


@router.get("/tokens")
async def token_analytics(days: int = Query(7, ge=1, le=90)):
    """Aggregate token usage and estimated costs across all LLM sources."""
    cutoff = (datetime.now(timezone.utc) - timedelta(days=days)).isoformat()

    daily: dict[str, dict] = defaultdict(lambda: {
        "chat": {"input_tokens": 0, "output_tokens": 0, "cost_usd": 0.0, "_models": defaultdict(lambda: {"input_tokens": 0, "output_tokens": 0, "cost_usd": 0.0})},
        "schedule": {"input_tokens": 0, "output_tokens": 0, "cost_usd": 0.0, "_models": defaultdict(lambda: {"input_tokens": 0, "output_tokens": 0, "cost_usd": 0.0})},
        "standby": {"input_tokens": 0, "output_tokens": 0, "cost_usd": 0.0, "_models": defaultdict(lambda: {"input_tokens": 0, "output_tokens": 0, "cost_usd": 0.0})},
    })

    # Fallback model for historical data without model in usage_json
    async with db_conn() as db:
        model_row = await (await db.execute(
            "SELECT value FROM settings WHERE key='standby_agent_model'"
        )).fetchone()
    sched_model = (model_row[0] if model_row else "gpt-4o-mini") or "gpt-4o-mini"

    async with db_conn() as db:
        # 1. Chat messages
        rows = await (await db.execute(
            "SELECT timestamp, usage_json FROM messages "
            "WHERE role='assistant' AND usage_json IS NOT NULL AND timestamp >= ?",
            (cutoff,),
        )).fetchall()
        for r in rows:
            u = _parse_usage(r["usage_json"])
            date = (r["timestamp"] or "")[:10]
            if not date:
                continue
            d = daily[date]["chat"]
            d["input_tokens"] += u.get("input_tokens", 0)
            d["output_tokens"] += u.get("output_tokens", 0)
            model = u.get("model") or "mimo-v2.5-pro"
            provider = u.get("provider", "")
            m = d["_models"][model]
            m["input_tokens"] += u.get("input_tokens", 0)
            m["output_tokens"] += u.get("output_tokens", 0)
            m["_provider"] = provider

        # 2. Schedule messages
        sched_rows = await (await db.execute(
            "SELECT timestamp, usage_json FROM schedule_messages "
            "WHERE role='assistant' AND usage_json IS NOT NULL AND timestamp >= ?",
            (cutoff,),
        )).fetchall()
        for r in sched_rows:
            u = _parse_usage(r["usage_json"])
            date = (r["timestamp"] or "")[:10]
            if not date:
                continue
            d = daily[date]["schedule"]
            d["input_tokens"] += u.get("input_tokens", 0)
            d["output_tokens"] += u.get("output_tokens", 0)
            model = u.get("model") or sched_model
            provider = u.get("provider", "")
            m = d["_models"][model]
            m["input_tokens"] += u.get("input_tokens", 0)
            m["output_tokens"] += u.get("output_tokens", 0)
            m["_provider"] = provider

        # 3. Standby agent log (has per-row model column)
        standby_rows = await (await db.execute(
            "SELECT ran_at, model, input_tokens, output_tokens FROM standby_agent_log "
            "WHERE ran_at >= ?",
            (cutoff,),
        )).fetchall()
        for r in standby_rows:
            date = (r["ran_at"] or "")[:10]
            if not date:
                continue
            d = daily[date]["standby"]
            inp = r["input_tokens"] or 0
            out = r["output_tokens"] or 0
            d["input_tokens"] += inp
            d["output_tokens"] += out
            model = r["model"] or sched_model
            m = d["_models"][model]
            m["input_tokens"] += inp
            m["output_tokens"] += out

    # Compute costs and totals
    total_input = total_output = total_cost = 0.0
    result_daily = []
    by_model: dict[str, dict] = defaultdict(lambda: {"input_tokens": 0, "output_tokens": 0, "cost_usd": 0.0})

    for date in sorted(daily.keys()):
        entry = daily[date]
        for source in ("chat", "schedule", "standby"):
            s = entry[source]
            # Compute per-model costs
            models_dict = s.pop("_models")
            for model_name, m_data in models_dict.items():
                provider = m_data.pop("_provider", "")
                await _add_cost(m_data, model_name, provider)
                s["cost_usd"] += m_data["cost_usd"]
                bm = by_model[model_name]
                bm["input_tokens"] += m_data["input_tokens"]
                bm["output_tokens"] += m_data["output_tokens"]
                bm["cost_usd"] += m_data["cost_usd"]

        total = {
            "input_tokens": sum(entry[s]["input_tokens"] for s in ("chat", "schedule", "standby")),
            "output_tokens": sum(entry[s]["output_tokens"] for s in ("chat", "schedule", "standby")),
            "cost_usd": round(sum(entry[s]["cost_usd"] for s in ("chat", "schedule", "standby")), 6),
        }
        total_input += total["input_tokens"]
        total_output += total["output_tokens"]
        total_cost += total["cost_usd"]
        result_daily.append({
            "date": date,
            "chat": entry["chat"],
            "schedule": entry["schedule"],
            "standby": entry["standby"],
            "total": total,
        })

    # Extract today and yesterday for quick summary
    today_str = datetime.now(timezone.utc).strftime("%Y-%m-%d")
    yesterday_str = (datetime.now(timezone.utc) - timedelta(days=1)).strftime("%Y-%m-%d")
    today_data = next((d for d in result_daily if d["date"] == today_str), None)
    yesterday_data = next((d for d in result_daily if d["date"] == yesterday_str), None)

    # Round by_model costs
    by_model_out = {}
    for m, data in by_model.items():
        data["cost_usd"] = round(data["cost_usd"], 6)
        by_model_out[m] = data

    return {
        "days": days,
        "daily": result_daily,
        "totals": {
            "input_tokens": int(total_input),
            "output_tokens": int(total_output),
            "cost_usd": round(total_cost, 6),
        },
        "by_model": by_model_out,
        "today": today_data["total"] if today_data else {"input_tokens": 0, "output_tokens": 0, "cost_usd": 0.0},
        "yesterday": yesterday_data["total"] if yesterday_data else {"input_tokens": 0, "output_tokens": 0, "cost_usd": 0.0},
    }


# ── Pricing management endpoints ──────────────────────────────────────────

@router.get("/pricing")
async def list_pricing():
    """List all known model prices: user overrides + KNOWN_PRICING + OpenRouter (top models)."""
    from app.services.pricing_service import fetch_openrouter_pricing

    # User overrides
    user_pricing = {}
    async with db_conn() as db:
        rows = await (await db.execute("SELECT model, input_rate, output_rate FROM model_pricing")).fetchall()
    for r in rows:
        user_pricing[r["model"]] = {"input_rate": r["input_rate"], "output_rate": r["output_rate"], "source": "user"}

    # OpenRouter
    or_pricing = await fetch_openrouter_pricing()

    # Merge: user > KNOWN_PRICING > OpenRouter
    result = {}
    for model, (inp, out) in KNOWN_PRICING.items():
        result[model] = {"input_rate": inp, "output_rate": out, "source": "builtin"}
    for model, (inp, out) in or_pricing.items():
        if model not in result:
            result[model] = {"input_rate": inp, "output_rate": out, "source": "openrouter"}
    for model, data in user_pricing.items():
        result[model] = data  # user overrides everything

    return {"pricing": result, "total": len(result)}


@router.put("/pricing/{model:path}")
async def set_pricing(model: str, request: Request):
    """Override pricing for a model."""
    body = await request.json()
    input_rate = float(body.get("input_rate", 0))
    output_rate = float(body.get("output_rate", 0))
    async with db_conn() as db:
        await db.execute(
            "INSERT INTO model_pricing (model, input_rate, output_rate, updated_at) "
            "VALUES (?, ?, ?, datetime('now')) "
            "ON CONFLICT(model) DO UPDATE SET input_rate=excluded.input_rate, output_rate=excluded.output_rate, updated_at=excluded.updated_at",
            (model, input_rate, output_rate),
        )
        await db.commit()
    return {"ok": True, "model": model, "input_rate": input_rate, "output_rate": output_rate}


@router.delete("/pricing/{model:path}")
async def delete_pricing(model: str):
    """Remove user override for a model."""
    async with db_conn() as db:
        await db.execute("DELETE FROM model_pricing WHERE model=?", (model,))
        await db.commit()
    return {"ok": True, "model": model}


@router.post("/pricing/refresh")
async def refresh_pricing():
    """Force re-fetch pricing from OpenRouter."""
    from app.services.pricing_service import fetch_openrouter_pricing, bust_cache
    bust_cache()
    data = await fetch_openrouter_pricing()
    return {"ok": True, "models": len(data)}
