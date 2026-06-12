#!/usr/bin/env python3
from __future__ import annotations

import argparse
import json
import os
import sys
import time
import uuid
import urllib.error
import urllib.request
from pathlib import Path
from typing import Any


DEFAULT_QUERIES = [
    "今天有什么课？",
    "最近和计组课设验收有关的都有什么？",
    "下周有什么 ddl 和重要通知？",
]


def main() -> int:
    parser = argparse.ArgumentParser(description="Benchmark /api/schedule/chat SSE token usage.")
    parser.add_argument("--base-url", default=os.environ.get("BASE_URL", "http://localhost"))
    parser.add_argument("--token", default=os.environ.get("ACCESS_TOKEN", ""))
    parser.add_argument("--label", default="run")
    parser.add_argument("--query", action="append", dest="queries", help="Query to run. Can be repeated.")
    parser.add_argument("--timeout", type=int, default=120)
    parser.add_argument("--out", default="")
    parser.add_argument("--baseline-json", default="", help="Existing token_compare JSON to compare against.")
    args = parser.parse_args()

    queries = args.queries or DEFAULT_QUERIES
    started = time.strftime("%Y-%m-%dT%H:%M:%S%z")
    results = []
    for i, query in enumerate(queries, 1):
        print(f"[{i}/{len(queries)}] {query}", file=sys.stderr)
        results.append(run_query(args.base_url, args.token, query, args.timeout))

    summary = summarize(results)
    payload: dict[str, Any] = {
        "label": args.label,
        "base_url": args.base_url,
        "started_at": started,
        "summary": summary,
        "results": results,
    }
    if args.baseline_json:
        payload["comparison"] = compare(load_json(args.baseline_json), payload)

    text = json.dumps(payload, ensure_ascii=False, indent=2)
    if args.out:
        Path(args.out).write_text(text + "\n", encoding="utf-8")
    print(text)
    return 0 if all(r["ok"] for r in results) else 2


def run_query(base_url: str, token: str, query: str, timeout: int) -> dict[str, Any]:
    url = base_url.rstrip("/") + "/api/schedule/chat"
    session_id = "bench-" + uuid.uuid4().hex[:12]
    body = json.dumps({"message": query, "session_id": session_id}, ensure_ascii=False).encode("utf-8")
    headers = {
        "Accept": "text/event-stream",
        "Content-Type": "application/json",
        "User-Agent": "curl/8.0 token-compare",
    }
    if token:
        headers["Authorization"] = f"Bearer {token}"
    request = urllib.request.Request(url, data=body, headers=headers, method="POST")
    usage_events: list[dict[str, Any]] = []
    tools: list[str] = []
    text_parts: list[str] = []
    errors: list[str] = []
    started = time.perf_counter()
    try:
        with urllib.request.urlopen(request, timeout=timeout) as response:
            for raw in response:
                line = raw.decode("utf-8", "replace").strip()
                if not line or not line.startswith("data:"):
                    continue
                try:
                    event = json.loads(line[5:].strip())
                except json.JSONDecodeError as exc:
                    errors.append(f"bad_sse_json: {exc}")
                    continue
                etype = event.get("type")
                if etype == "usage" and isinstance(event.get("usage"), dict):
                    usage_events.append(event["usage"])
                elif etype == "tool_start":
                    for tool in event.get("tools") or []:
                        name = tool.get("name")
                        if name:
                            tools.append(name)
                elif etype == "text":
                    text_parts.append(event.get("content") or "")
                elif etype == "error":
                    errors.append(event.get("message") or "unknown error")
    except urllib.error.HTTPError as exc:
        errors.append(f"http_{exc.code}: {exc.read().decode('utf-8', 'replace')[:500]}")
    except Exception as exc:
        errors.append(f"{type(exc).__name__}: {exc}")

    elapsed = round(time.perf_counter() - started, 3)
    totals = token_totals(usage_events)
    return {
        "ok": not errors,
        "query": query,
        "session_id": session_id,
        "elapsed_s": elapsed,
        "input_tokens": totals["input_tokens"],
        "output_tokens": totals["output_tokens"],
        "total_tokens": totals["input_tokens"] + totals["output_tokens"],
        "usage_events": usage_events,
        "tools": tools,
        "answer_preview": "".join(text_parts).strip()[:300],
        "errors": errors,
    }


def token_totals(events: list[dict[str, Any]]) -> dict[str, int]:
    return {
        "input_tokens": sum(int(e.get("input_tokens") or 0) for e in events),
        "output_tokens": sum(int(e.get("output_tokens") or 0) for e in events),
    }


def summarize(results: list[dict[str, Any]]) -> dict[str, Any]:
    input_tokens = sum(r["input_tokens"] for r in results)
    output_tokens = sum(r["output_tokens"] for r in results)
    return {
        "queries": len(results),
        "ok": sum(1 for r in results if r["ok"]),
        "failed": sum(1 for r in results if not r["ok"]),
        "elapsed_s": round(sum(r["elapsed_s"] for r in results), 3),
        "input_tokens": input_tokens,
        "output_tokens": output_tokens,
        "total_tokens": input_tokens + output_tokens,
    }


def compare(baseline: dict[str, Any], current: dict[str, Any]) -> dict[str, Any]:
    base_by_query = {r.get("query"): r for r in baseline.get("results", [])}
    rows = []
    for cur in current.get("results", []):
        base = base_by_query.get(cur.get("query"))
        if not base:
            continue
        before = int(base.get("total_tokens") or 0)
        after = int(cur.get("total_tokens") or 0)
        saved = before - after
        rows.append({
            "query": cur.get("query"),
            "before_tokens": before,
            "after_tokens": after,
            "saved_tokens": saved,
            "saved_percent": round(saved / before * 100, 1) if before else None,
        })
    before_total = sum(r["before_tokens"] for r in rows)
    after_total = sum(r["after_tokens"] for r in rows)
    saved_total = before_total - after_total
    return {
        "rows": rows,
        "before_total_tokens": before_total,
        "after_total_tokens": after_total,
        "saved_tokens": saved_total,
        "saved_percent": round(saved_total / before_total * 100, 1) if before_total else None,
    }


def load_json(path: str) -> dict[str, Any]:
    return json.loads(Path(path).read_text(encoding="utf-8"))


if __name__ == "__main__":
    raise SystemExit(main())
