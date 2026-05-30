"""Token usage analytics endpoint."""
from __future__ import annotations

import json
from collections import defaultdict
from datetime import datetime, timedelta, timezone

from fastapi import APIRouter, Query
from app.database import db_conn
from app.services.api_service import estimate_cost

router = APIRouter(prefix="/api/analytics", tags=["analytics"])


def _parse_usage(usage_json: str | None) -> dict:
    if not usage_json:
        return {"input_tokens": 0, "output_tokens": 0}
    try:
        return json.loads(usage_json)
    except (json.JSONDecodeError, TypeError):
        return {"input_tokens": 0, "output_tokens": 0}


def _add_cost(entry: dict, model: str) -> float:
    """Add cost_usd to entry in-place, return cost."""
    cost = estimate_cost(model, entry.get("input_tokens", 0), entry.get("output_tokens", 0))
    entry["cost_usd"] = round(cost, 6) if cost else 0.0
    return entry["cost_usd"]


@router.get("/tokens")
async def token_analytics(days: int = Query(7, ge=1, le=90)):
    """Aggregate token usage and estimated costs across all LLM sources."""
    cutoff = (datetime.now(timezone.utc) - timedelta(days=days)).isoformat()

    daily: dict[str, dict] = defaultdict(lambda: {
        "chat": {"input_tokens": 0, "output_tokens": 0, "cost_usd": 0.0},
        "schedule": {"input_tokens": 0, "output_tokens": 0, "cost_usd": 0.0},
        "standby": {"input_tokens": 0, "output_tokens": 0, "cost_usd": 0.0},
    })

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

        # 2. Schedule messages
        sched_rows = await (await db.execute(
            "SELECT timestamp, usage_json FROM schedule_messages "
            "WHERE role='assistant' AND usage_json IS NOT NULL AND timestamp >= ?",
            (cutoff,),
        )).fetchall()
        # Get the configured schedule model for cost estimation
        model_row = await (await db.execute(
            "SELECT value FROM settings WHERE key='standby_agent_model'"
        )).fetchone()
        sched_model = (model_row[0] if model_row else "gpt-4o-mini") or "gpt-4o-mini"

        for r in sched_rows:
            u = _parse_usage(r["usage_json"])
            date = (r["timestamp"] or "")[:10]
            if not date:
                continue
            d = daily[date]["schedule"]
            d["input_tokens"] += u.get("input_tokens", 0)
            d["output_tokens"] += u.get("output_tokens", 0)

        # 3. Standby agent log
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
            d["input_tokens"] += r["input_tokens"] or 0
            d["output_tokens"] += r["output_tokens"] or 0

    # Compute costs and totals
    total_input = total_output = total_cost = 0.0
    result_daily = []

    for date in sorted(daily.keys()):
        entry = daily[date]
        for source in ("chat", "schedule", "standby"):
            s = entry[source]
            model = sched_model if source == "schedule" else "mimo-v2.5-pro"
            _add_cost(s, model)
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

    return {
        "days": days,
        "daily": result_daily,
        "totals": {
            "input_tokens": int(total_input),
            "output_tokens": int(total_output),
            "cost_usd": round(total_cost, 6),
        },
        "today": today_data["total"] if today_data else {"input_tokens": 0, "output_tokens": 0, "cost_usd": 0.0},
        "yesterday": yesterday_data["total"] if yesterday_data else {"input_tokens": 0, "output_tokens": 0, "cost_usd": 0.0},
    }
