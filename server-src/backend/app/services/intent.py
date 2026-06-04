"""
Intent routing for the schedule agent (P3).

Replaces the two hard-coded keyword dictionaries that used to live inline in
schedule_agent.py (orchestrator_plan + _filter_schedule_tools). Goals:

- Single source of truth for routing keywords.
- Synonym expansion so more phrasings hit the right route (recall).
- Scored matching (count of distinct matched terms) instead of pure boolean,
  with a graceful fallback when nothing scores.

This is deliberately non-LLM: cheap, deterministic, unit-testable. An optional
LLM router can layer on top later (design doc P3 step 2) without changing the
call sites, since this module owns the routing contract.
"""
from __future__ import annotations

# ── Synonym expansion ───────────────────────────────────────────────────────
# Map a CANONICAL term to the surface variants that should also count as it.
# At match time we augment the lowercased message: if any variant appears, the
# canonical term is appended so keyword lists only need to reference canonicals.
SYNONYMS: dict[str, list[str]] = {
    "提醒":   ["待办", "todo", "to-do", "事项", "代办", "记得", "别忘", "记一下"],
    "课程":   ["课表", "课程表", "上课", "选课", "节课", "第几节"],
    "作业":   ["assignment", "homework", "ddl", "deadline", "截止", "待交", "交作业"],
    "日历":   ["calendar", "日程", "行程", "活动", "事件"],
    "会议":   ["meeting", "开会", "例会", "组会"],
    "删除":   ["删掉", "删了", "去掉", "移除", "清掉", "去除", "remove", "delete"],
    "修改":   ["改成", "改一下", "更新", "调整", "换成", "edit", "update", "改为"],
    "创建":   ["添加", "新建", "加个", "设个", "建一个", "新增", "create", "add"],
    "完成":   ["做完", "搞定", "勾掉", "标记完成", "done", "finish"],
    "学习通": ["chaoxing", "超星", "学习强国"],  # 学习强国 is a common mis-say
    "钉钉":   ["dingtalk", "钉"],
    "记忆":   ["memory", "记录", "记下来"],
    "推送":   ["通知", "push", "提醒我", "告诉我"],
    "刷新":   ["扫描", "重新扫", "重新拉", "更新一下", "拉一下", "refresh", "scan", "同步"],
    "系统":   ["status", "状态", "运行", "健康", "health", "cpu", "内存", "ram", "磁盘", "disk", "uptime", "standby"],
    "偏好":   ["习惯", "我喜欢", "我一般", "我通常", "记住"],
}

# ── Sub-agent routing (orchestrator_plan) ───────────────────────────────────
SUBAGENT_KEYWORDS: dict[str, list[str]] = {
    "calendar":  ["日历", "会议", "安排", "冲突"],
    "reminders": ["提醒", "完成"],
    "courses":   ["课程", "教室", "调课", "停课", "补课"],
    "chaoxing":  ["学习通", "作业", "推送", "消息"],
}

MUTATION_KEYWORDS = ["创建", "修改", "删除", "完成", "取消", "提醒"]

# ── Tool routing (_filter_schedule_tools) ───────────────────────────────────
# Canonical terms here are auto-expanded via SYNONYMS at match time.
TOOL_KEYWORDS: dict[str, list[str]] = {
    "get_schedule_context":          ["课程", "作业", "日历", "提醒", "今天", "明天", "安排", "有什么", "看一下"],
    "read_message_memory":           ["学习通", "记忆", "消息", "推送", "重要"],
    "refresh_message_memory":        ["刷新", "更新记忆"],
    "get_chaoxing_assignments":      ["作业", "提交"],
    "get_chaoxing_messages":         ["学习通", "原始消息", "群消息", "最近消息"],
    "read_dingtalk_messages":        ["钉钉", "群消息", "私信", "群聊"],
    "delete_message_memory":         ["删除记忆", "删除"],
    "list_reminders":                ["提醒", "清单"],
    "create_reminder":               ["创建", "提醒"],
    "update_reminder":               ["修改", "提醒"],
    "complete_reminder":             ["完成"],
    "delete_reminder":               ["删除", "提醒"],
    "list_courses":                  ["课程", "教室", "调课", "停课", "补课"],
    "import_timetable":              ["导入课程", "导入课表", "录入课程", "录入课表"],
    "list_calendar_events":          ["日历", "会议", "安排"],
    "create_calendar_event":         ["创建", "日历", "会议"],
    "update_calendar_event":         ["修改", "日历", "事件"],
    "delete_calendar_event":         ["删除", "日历", "事件", "会议"],
    "list_scheduled_notifications":  ["定时推送", "定时通知", "待发通知", "推送列表"],
    "schedule_notification":         ["定时推送", "定时提醒", "安排推送", "到时候", "提醒我"],
    "cancel_scheduled_notification": ["取消推送", "取消定时", "取消通知", "取消提醒"],
    "send_push_notification":        ["推送", "立刻通知", "马上提醒", "作业"],
    "get_memory_insights":           ["学习通", "记忆", "洞察", "分析"],
    "get_system_status":             ["系统", "钉钉"],
    "save_memory":                   ["偏好", "记忆"],
    "delete_memory":                 ["忘记", "删除记忆", "删除偏好"],
    "list_memories":                 ["我的记忆", "我的偏好", "记忆列表", "所有记忆"],
    "trigger_memory_scan":           ["刷新", "立刻检查", "帮我扫", "触发扫描", "检查学习通"],
    "set_push_config":               ["静默", "免打扰", "推送设置", "推送配置", "间隔", "quiet"],
}

# Always available regardless of score — the agent's bread-and-butter read.
ALWAYS_INCLUDE = {"get_schedule_context"}


def _normalize(text: str) -> str:
    """Lowercase + append canonical terms for any synonym variant present.

    Additive (never removes): preserves the original text so canonical terms
    that appear verbatim still match, while variant phrasings also count.
    """
    low = (text or "").lower()
    extra: list[str] = []
    for canonical, variants in SYNONYMS.items():
        if canonical in low or any(v in low for v in variants):
            extra.append(canonical)
    return low + " " + " ".join(extra) if extra else low


def _score(norm: str, keywords: list[str]) -> int:
    """Count of distinct keywords present in the normalized message."""
    return sum(1 for kw in set(keywords) if kw.lower() in norm)


def plan_subagents(user_text: str) -> dict:
    """Return {'sub_agents': [...], 'expects_mutation': bool} for collect_reports."""
    norm = _normalize(user_text)
    sub_agents = [
        name for name, kws in SUBAGENT_KEYWORDS.items() if _score(norm, kws) > 0
    ]
    expects_mutation = _score(norm, MUTATION_KEYWORDS) > 0
    return {"sub_agents": sub_agents[:4], "expects_mutation": expects_mutation}


def filter_tool_names(user_text: str, available: list[str]) -> list[str]:
    """Return the subset of `available` tool names relevant to the message.

    Scored by synonym-expanded keyword overlap. Tools in ALWAYS_INCLUDE are
    always kept. If nothing matches at all, fall back to the full set so the
    agent is never left tool-less.
    """
    norm = _normalize(user_text)
    selected = [
        name for name in available
        if name in ALWAYS_INCLUDE or _score(norm, TOOL_KEYWORDS.get(name, [name])) > 0
    ]
    return selected if selected else list(available)
