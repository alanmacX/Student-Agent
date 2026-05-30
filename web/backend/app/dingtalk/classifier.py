"""Stage-2 LLM fine classifier (persona-aware).

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
from typing import Any, Dict, List

logger = logging.getLogger("dingtalk.classifier")

PERSONA = os.getenv(
    "DINGTALK_PERSONA",
    "浙江工业大学计算机学院2024级本科生，关注：课程/作业/考试/ddl、"
    "与计算机相关的竞赛(ACM/蓝桥/算法/AI/CTF等)、技术讲座、计算机方向的实习与科研机会。"
    "对非计算机相关的招聘、文体志愿活动、行政考勤通报、转专业等不感兴趣。",
)

BATCH_SIZE = int(os.getenv("DINGTALK_LLM_BATCH", "15"))
LLM_PROVIDER = os.getenv("DINGTALK_LLM_PROVIDER", "")  # "" -> use standby provider

SYSTEM_PROMPT = """你是一个钉钉群消息分类助手。根据用户人设，把每条群消息分到三个去向之一：

- notify（提醒）：与用户课程/学习直接相关、需要本人行动或知晓的，如作业、实验、考试、ddl、调课、老师/助教通知、与用户专业强相关且重要的内容。
- interest（可能感兴趣）：与用户专业方向相关但不紧急的，如本专业相关的竞赛、技术讲座、相关实习/科研机会。归档供用户闲时浏览，不打扰。
- drop（丢弃）：与用户无关的噪音，如非本专业的招聘/竞赛/活动、文体志愿、行政考勤学风通报、失物招领、闲聊水群、与学习无关的链接。

用户人设：
{persona}

判断原则：
1. 宁可 drop 也不要误 notify——只有真正相关且重要的才 notify。
2. 不确定是否本专业相关、但可能有价值的，归 interest。
3. 纯事务性/无关内容一律 drop。

只输出 JSON 数组，每个元素：{{"id": 序号, "verdict": "notify|interest|drop", "category": "简短类别", "reason": "10字内理由"}}
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
    provider_id: str = "",
    app_state=None,
) -> None:
    from app.services.agent_service import AgentMsg, agent_complete, merge_system_messages

    messages = merge_system_messages([
        AgentMsg(role="system", content=SYSTEM_PROMPT.format(persona=PERSONA)),
        AgentMsg(role="user", content=_build_user_prompt(batch)),
    ])
    try:
        resp = await agent_complete(messages, [], provider, model, api_key, thinking_budget=0)
    except Exception:
        logger.exception("LLM classify call failed; defaulting batch to interest")
        for m in batch:
            m["verdict"] = "interest"
            m["verdict_reason"] = "llm error -> interest"
        if app_state and provider_id:
            from app.tasks.health_monitor import alert_api_failure
            await alert_api_failure(app_state, provider_id)
        return

    # Success — reset failure counter
    if provider_id:
        from app.tasks.health_monitor import reset_api_failure_count
        reset_api_failure_count(provider_id)

    results = _parse_llm_json(resp.text or "")
    by_id = {r.get("id"): r for r in results if isinstance(r, dict)}
    for i, m in enumerate(batch):
        r = by_id.get(i)
        if not r or r.get("verdict") not in ("notify", "interest", "drop"):
            m["verdict"] = "interest"
            m["verdict_reason"] = "llm no verdict -> interest"
            continue
        m["verdict"] = r["verdict"]
        m["verdict_reason"] = f"llm:{r.get('category','')}:{r.get('reason','')}"[:80]
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

    from app.services.provider_registry import resolve_provider

    provider_id = LLM_PROVIDER or getattr(
        getattr(app_state, "settings", None), "standby_agent_provider", None
    ) or "openai"
    try:
        provider, api_key = await resolve_provider(provider_id)
    except Exception:
        logger.exception("Could not resolve LLM provider; defaulting pending to interest")
        for m in pending:
            m["verdict"], m["verdict_reason"] = "interest", "no provider -> interest"
        return messages

    model = getattr(getattr(app_state, "settings", None), "standby_agent_model", None) or "gpt-4o-mini"

    for start in range(0, len(pending), BATCH_SIZE):
        await _classify_batch(
            pending[start:start + BATCH_SIZE],
            provider, model, api_key,
            provider_id=provider_id, app_state=app_state,
        )

    return messages
