"""Stage-2 LLM fine classifier (screening-card aware).

Takes the messages that coarse filtering marked as ``needs_llm`` and decides
the final bucket: notify / interest / drop. Judges relevance against the user
persona (a CS undergrad), so that:
  * course / CS-strong / actionable  -> notify
  * CS-related but non-urgent         -> interest ("你可能感兴趣")
  * non-CS activities / chit-chat     -> drop

Uses the chatbot's existing LLM stack (agent_complete + resolve_provider).
Runs as a batch (one call for many messages) to keep cost/latency low.
"""
from __future__ import annotations

import json
import logging
import os
import re
from typing import Any, Dict, List

logger = logging.getLogger("dingtalk.classifier")

PERSONA = os.getenv(
    "DINGTALK_PERSONA",
    "浙江工业大学计算机学院2024级本科生，关注：课程/作业/考试/ddl、"
    "与计算机相关的竞赛(ACM/蓝桥/算法/AI/CTF等)、技术讲座、计算机方向的实习与科研机会。"
    "对非计算机相关的招聘、文体志愿活动、行政考勤通报、转专业等不感兴趣。",
)

BATCH_SIZE = int(os.getenv("DINGTALK_LLM_BATCH", "15"))
LLM_PROVIDER = os.getenv("DINGTALK_LLM_PROVIDER", "")  # "" -> use filter_provider/standby provider

SYSTEM_PROMPT = """你是一个钉钉群消息 F2 筛选器。根据用户人设和筛查卡，把每条群消息分到三个去向之一。

编码：
- v=2 notify：课程/作业/考试/ddl/调课/停课/老师助教通知，或筛查卡课程/watch 明确命中，值得打扰。
- v=1 interest：专业相关但不紧急，如 CS 竞赛、技术讲座、实习科研机会；归档，不打扰。
- v=0 drop：无关噪音、闲聊、水群、文体志愿、行政通报、非专业招聘/活动。

用户人设：
{persona}

筛查卡：
{screening_card}

判断原则：
1. 宁可 drop 也不要误 notify——只有真正相关且重要的才 notify。
2. 命中筛查卡里的课程名、课程别名、watch 关键词，且文本不是纯闲聊时，优先 v=2。
3. 不确定是否专业相关、但可能有价值的，归 v=1。
4. 纯事务性/无关内容一律 v=0。

只输出 JSON 数组，每个元素：{{"i": 序号, "v": 0|1|2, "r": "10字内理由"}}
不要输出任何其它文字。"""


def _build_user_prompt(messages: List[Dict[str, Any]]) -> str:
    lines = []
    for i, m in enumerate(messages):
        title = m.get("conversation_title") or m.get("cid") or ""
        sender = m.get("sender_name") or m.get("sender_id") or "?"
        text = (m.get("text") or "").replace("\n", " ").strip()
        atts = m.get("attachments")
        extra = ""
        if not text and atts:
            extra = f" [附件:{atts[:80]}]"
        lines.append(f'{i}. 群「{title}」 {sender}: {text[:200]}{extra}')
    return "待分类消息：\n" + "\n".join(lines)


def _parse_llm_json(text: str) -> List[Dict[str, Any]]:
    if not text:
        return []
    s = text.strip()
    # strip code fences
    if s.startswith("```"):
        s = s.split("```")[1] if "```" in s[3:] else s[3:]
        s = s.lstrip("json").lstrip()
    # find the JSON array
    start = s.find("[")
    end = s.rfind("]")
    if start == -1 or end == -1 or end < start:
        return []
    try:
        return json.loads(s[start:end + 1])
    except Exception:
        logger.warning("Failed to parse LLM classification JSON: %s", s[:200])
        return []


async def _classify_batch(
    batch: List[Dict[str, Any]],
    provider: dict,
    model: str,
    api_key: str,
    db_path: str,
    screening_card: str,
    important_terms: list[str],
    provider_id: str = "",
    app_state=None,
) -> None:
    from app.services.agent_service import AgentMsg, agent_complete, merge_system_messages

    messages = merge_system_messages([
        AgentMsg(role="system", content=SYSTEM_PROMPT.format(
            persona=PERSONA,
            screening_card=screening_card or "（暂无筛查卡，按用户人设和消息上下文判断）",
        )),
        AgentMsg(role="user", content=_build_user_prompt(batch)),
    ])
    try:
        resp = await agent_complete(messages, [], provider, model, api_key, thinking_budget=0)
        if resp.usage:
            from app.services.budget import log_usage

            await log_usage(db_path, "dingtalk_f2", provider_id, model, resp.usage)
    except Exception:
        logger.exception("LLM classify call failed; using deterministic fallback")
        for m in batch:
            verdict = _fallback_verdict(m, important_terms)
            m["verdict"] = verdict
            m["verdict_reason"] = f"llm error -> {verdict}"
            if verdict == "drop":
                m["_keep"] = False
        if app_state and provider_id:
            from app.tasks.health_monitor import alert_api_failure
            await alert_api_failure(app_state, provider_id)
        return

    # Success — reset failure counter
    if provider_id:
        from app.tasks.health_monitor import reset_api_failure_count
        reset_api_failure_count(provider_id)

    results = _parse_llm_json(resp.text or "")
    by_id = {(r.get("i") if "i" in r else r.get("id")): r for r in results if isinstance(r, dict)}
    for i, m in enumerate(batch):
        r = by_id.get(i)
        verdict = _result_verdict(r)
        if not verdict:
            verdict = _fallback_verdict(m, important_terms)
            m["verdict"] = verdict
            m["verdict_reason"] = f"llm no verdict -> {verdict}"
            if verdict == "drop":
                m["_keep"] = False
            continue
        m["verdict"] = verdict
        m["verdict_reason"] = f"f2:v{r.get('v', '')}:{r.get('r') or r.get('reason','')}"[:80]
        if m["verdict"] == "drop":
            m["_keep"] = False


async def classify_messages(messages: List[Dict[str, Any]], app_state=None) -> List[Dict[str, Any]]:
    """Finalize verdicts for messages whose verdict == 'needs_llm'.

    Mutates and returns the same list. Messages already decided by the coarse
    filter are left untouched.
    """
    pending = [m for m in messages if m.get("_needs_llm") or m.get("verdict") == "needs_llm"]
    if not pending:
        return messages

    from app.config import settings
    from app.services.budget import is_budget_exhausted
    from app.services.provider_registry import get_setting_value, resolve_provider

    db_path = getattr(getattr(app_state, "settings", None), "database_path", None) or settings.database_path
    screening_card, important_terms = await _load_screening_context(db_path)

    if await is_budget_exhausted(db_path):
        for m in pending:
            verdict = _fallback_verdict(m, important_terms)
            m["verdict"], m["verdict_reason"] = verdict, f"budget exhausted -> {verdict}"
            if verdict == "drop":
                m["_keep"] = False
        return messages

    provider_id = (
        LLM_PROVIDER
        or await get_setting_value("filter_provider")
        or getattr(
        getattr(app_state, "settings", None), "standby_agent_provider", None
        )
        or "openai"
    )
    try:
        provider, api_key = await resolve_provider(provider_id)
    except Exception:
        logger.exception("Could not resolve LLM provider; using deterministic fallback")
        for m in pending:
            verdict = _fallback_verdict(m, important_terms)
            m["verdict"], m["verdict_reason"] = verdict, f"no provider -> {verdict}"
            if verdict == "drop":
                m["_keep"] = False
        return messages

    model = (
        await get_setting_value("filter_model")
        or getattr(getattr(app_state, "settings", None), "standby_agent_model", None)
        or (provider.get("models") or ["gpt-4o-mini"])[0]
    )

    for start in range(0, len(pending), BATCH_SIZE):
        await _classify_batch(
            pending[start:start + BATCH_SIZE],
            provider, model, api_key, db_path, screening_card, important_terms,
            provider_id=provider_id, app_state=app_state,
        )

    return messages


def _result_verdict(r: dict | None) -> str | None:
    if not isinstance(r, dict):
        return None
    if r.get("verdict") in ("notify", "interest", "drop"):
        return r["verdict"]
    try:
        v = int(r.get("v"))
    except (TypeError, ValueError):
        return None
    return {2: "notify", 1: "interest", 0: "drop"}.get(v)


def _fallback_verdict(message: dict, important_terms: list[str]) -> str:
    text = f"{message.get('conversation_title') or ''}\n{message.get('text') or ''}"
    if message.get("category") == "course":
        return "notify"
    if _matches_any_term(text, important_terms):
        return "notify"
    if re.search(r"(作业|实验|考试|ddl|截止|调课|停课|补课|上课|助教|老师|课程)", text, re.I):
        return "notify"
    return "interest"


async def _load_screening_context(db_path: str) -> tuple[str, list[str]]:
    import aiosqlite

    terms: list[str] = []
    async with aiosqlite.connect(db_path) as db:
        db.row_factory = aiosqlite.Row
        card_row = await (await db.execute(
            "SELECT value FROM settings WHERE key='screening_card'"
        )).fetchone()
        rows = await (await db.execute(
            """SELECT name, aliases FROM entities
               WHERE status='active' AND etype IN ('course','watch')
               ORDER BY etype, name LIMIT 200"""
        )).fetchall()
    for row in rows:
        if row["name"]:
            terms.append(row["name"])
        try:
            aliases = json.loads(row["aliases"] or "[]")
        except Exception:
            aliases = []
        terms.extend(str(a) for a in aliases if str(a or "").strip())
    return (card_row["value"] if card_row else ""), list(dict.fromkeys(terms))


def _matches_any_term(text: str, terms: list[str]) -> bool:
    lowered = (text or "").lower()
    for term in terms:
        clean = str(term or "").strip()
        if len(clean) >= 2 and clean.lower() in lowered:
            return True
    return False
