"""
Dashboard Briefing
==================
Generates a short, natural-language "what should I focus on today" briefing
by feeding all active memory entries (assignments, courses, reminders, messages)
to the LLM.

Design:
  - Generation is gated on a content signature. We only call the LLM when the
    underlying data actually changed (new/changed memory entries, assignment
    count, etc.). This keeps cost ~0 on idle probes.
  - The result (text + signature + timestamp) is cached in chaoxing_sync_state
    (key-value table), so the sidebar endpoint just reads it — no LLM in the
    request path.
"""
from __future__ import annotations

import hashlib
import json
import logging
from datetime import datetime, timedelta, timezone

import aiosqlite

CST = timezone(timedelta(hours=8))

logger = logging.getLogger("briefing")

_SIG_KEY = "dashboard_briefing_sig"
_TEXT_KEY = "dashboard_briefing_text"
_TODOS_KEY = "dashboard_briefing_todos"
_TS_KEY = "dashboard_briefing_at"


# ── data gathering ──────────────────────────────────────────────────────────

async def _gather(db_path: str, now: datetime) -> dict:
    async with aiosqlite.connect(db_path) as db:
        db.row_factory = aiosqlite.Row

        mem = await (await db.execute(
            """SELECT kind, title, summary, action_hint, importance,
                      COALESCE(content_time, expires_at) AS date_hint
               FROM chaoxing_memory_entries
               WHERE archived_at IS NULL
                 AND (expires_at IS NULL OR expires_at > ?)
               ORDER BY CASE importance WHEN 'high' THEN 1 WHEN 'medium' THEN 2 ELSE 3 END,
                        COALESCE(content_time, expires_at) ASC
               LIMIT 40""",
            (now.isoformat(),),
        )).fetchall()

        # Build day window in the same timezone as the stored timestamps (+08:00)
        # so that string comparison works correctly.
        day_start = now.replace(hour=0, minute=0, second=0, microsecond=0)
        day_end = day_start + timedelta(days=1)
        courses = await (await db.execute(
            """SELECT title, start_at, location FROM server_courses
               WHERE end_at >= ? AND start_at < ?
               ORDER BY start_at ASC LIMIT 30""",
            (day_start.isoformat(), day_end.isoformat()),
        )).fetchall()

    return {
        "memory": [dict(r) for r in mem],
        "today_courses": [dict(r) for r in courses],
    }


def _signature(data: dict) -> str:
    """Stable hash of the data that matters for the briefing."""
    basis = []
    for m in data["memory"]:
        basis.append(f"{m.get('kind')}|{m.get('title')}|{m.get('importance')}|{m.get('action_hint')}|{m.get('date_hint')}")
    for c in data["today_courses"]:
        basis.append(f"course|{c.get('title')}|{c.get('start_at')}")
    raw = "\n".join(sorted(basis))
    return hashlib.sha256(raw.encode("utf-8")).hexdigest()[:16]


# ── prompt ──────────────────────────────────────────────────────────────────

def _system_prompt(now: datetime) -> str:
    weekday = ["周一", "周二", "周三", "周四", "周五", "周六", "周日"][now.weekday()]
    return f"""你是一个学生日程助手。现在是 {now.astimezone(CST).strftime('%Y-%m-%d %H:%M')}（{weekday}）。

根据下面的待办数据，由你自己判断「现在最紧急、最该先做的事」，并给出今天的重点。不要机械地照搬数据顺序，要像一个懂事的助理那样权衡 deadline 远近、重要性和影响。

请只输出一个 JSON 对象，不要任何额外文字、前缀或 markdown 代码块，格式如下：

{{
  "briefing": "一两句口语化的中文总结，像朋友提醒一样，点出今天整体节奏和最该上心的那件事。",
  "todos": [
    {{
      "title": "要做的事（简短，10 字以内最好）",
      "detail": "一句自然语言说明：为什么现在要做、还剩多久、做什么动作。",
      "when": "时间线索，如 今天 18:00 / 明天 / 周五 截止；没有就空字符串",
      "urgency": "high | medium | low"
    }}
  ]
}}

要求：
- todos 按你判断的优先级从高到低排列，最多 5 条，宁缺毋滥。
- urgency 由你判断：deadline 临近或影响大的用 high。
- 如果数据里有课程变动、考试、会议等通知（kind=message），通常该排在前面。
- 如果完全没有要紧的事，briefing 轻松说一句，todos 给空数组 []，不要硬凑。
- detail 用自然语言，不要写"根据数据"之类的机械措辞。
- 严格输出合法 JSON，字符串内不要出现未转义的换行。"""


def _user_payload(data: dict) -> str:
    return f"""=== 待办与通知（unified memory）===
{json.dumps(data['memory'], ensure_ascii=False, indent=2)}

=== 今天的课 ===
{json.dumps(data['today_courses'], ensure_ascii=False, indent=2)}"""


# ── public API ──────────────────────────────────────────────────────────────

async def load_briefing(db_path: str) -> dict | None:
    async with aiosqlite.connect(db_path) as db:
        rows = await (await db.execute(
            "SELECT key, value FROM chaoxing_sync_state WHERE key IN (?,?,?,?)",
            (_TEXT_KEY, _TODOS_KEY, _TS_KEY, _SIG_KEY),
        )).fetchall()
    kv = {k: v for k, v in rows}
    text = kv.get(_TEXT_KEY)
    if not text:
        return None
    todos = []
    if kv.get(_TODOS_KEY):
        try:
            todos = json.loads(kv[_TODOS_KEY]) or []
        except (json.JSONDecodeError, TypeError):
            todos = []
    return {"text": text, "todos": todos, "generated_at": kv.get(_TS_KEY)}


async def _store(db_path: str, text: str, todos: list, sig: str, now: datetime) -> None:
    async with aiosqlite.connect(db_path) as db:
        for k, v in (
            (_TEXT_KEY, text),
            (_TODOS_KEY, json.dumps(todos, ensure_ascii=False)),
            (_SIG_KEY, sig),
            (_TS_KEY, now.isoformat()),
        ):
            await db.execute(
                "INSERT OR REPLACE INTO chaoxing_sync_state (key, value) VALUES (?,?)",
                (k, v),
            )
        await db.commit()


def _parse_llm_json(raw: str) -> tuple[str, list]:
    """Parse the LLM's JSON output into (briefing_text, todos).
    Tolerates code fences and leading/trailing prose; falls back to treating
    the whole string as the briefing text with no todos."""
    s = (raw or "").strip()
    if s.startswith("```"):
        s = s.strip("`")
        # drop a leading 'json' language tag if present
        if s[:4].lower() == "json":
            s = s[4:]
    # Extract the outermost JSON object if there's surrounding prose.
    start = s.find("{")
    end = s.rfind("}")
    if start != -1 and end != -1 and end > start:
        candidate = s[start : end + 1]
        try:
            obj = json.loads(candidate)
            briefing = (obj.get("briefing") or "").strip()
            todos = obj.get("todos") or []
            if not isinstance(todos, list):
                todos = []
            # keep only well-formed items
            clean = []
            for t in todos[:5]:
                if not isinstance(t, dict):
                    continue
                title = (t.get("title") or "").strip()
                if not title:
                    continue
                clean.append({
                    "title": title,
                    "detail": (t.get("detail") or "").strip(),
                    "when": (t.get("when") or "").strip(),
                    "urgency": (t.get("urgency") or "medium").strip().lower(),
                })
            if briefing:
                return briefing, clean
        except json.JSONDecodeError:
            pass
    # Fallback: treat the raw text as the briefing.
    return raw.strip(), []


async def generate_and_store(
    db_path: str,
    provider: dict,
    model: str,
    api_key: str,
    now: datetime | None = None,
    force: bool = False,
) -> dict | None:
    """
    Gather data, compute signature, and (re)generate the briefing only if the
    signature changed (or force=True). Returns the stored briefing dict or None.
    """
    # Always work in Beijing time so TEXT timestamp comparisons match the
    # stored +08:00 course rows (SQLite compares them lexically).
    now = (now or datetime.now(CST)).astimezone(CST)
    data = await _gather(db_path, now)

    # Nothing at all → store an empty-state briefing without calling the LLM.
    if not data["memory"] and not data["today_courses"]:
        empty = "目前没有待办、课程或通知。导入课程表或登录学习通后，这里会自动汇总你最该关注的事。"
        await _store(db_path, empty, [], "empty", now)
        return {"text": empty, "todos": [], "generated_at": now.isoformat()}

    sig = _signature(data)

    if not force:
        async with aiosqlite.connect(db_path) as db:
            row = await (await db.execute(
                "SELECT value FROM chaoxing_sync_state WHERE key=?", (_SIG_KEY,)
            )).fetchone()
        if row and row[0] == sig:
            return await load_briefing(db_path)  # unchanged, skip LLM

    try:
        from .agent_service import AgentMsg, agent_complete
        response = await agent_complete(
            [
                AgentMsg(role="system", content=_system_prompt(now)),
                AgentMsg(role="user", content=_user_payload(data)),
            ],
            [], provider, model, api_key,
        )
        raw = (response.text or "").strip()
        if not raw:
            logger.warning("Briefing LLM returned empty text; keeping previous briefing")
            return await load_briefing(db_path)
        text, todos = _parse_llm_json(raw)
        if not text:
            return await load_briefing(db_path)
        await _store(db_path, text, todos, sig, now)
        logger.debug(f"Briefing regenerated ({len(text)} chars, {len(todos)} todos, sig={sig})")
        return {"text": text, "todos": todos, "generated_at": now.isoformat()}
    except Exception as e:
        logger.error(f"Briefing generation failed: {e}")
        return await load_briefing(db_path)
