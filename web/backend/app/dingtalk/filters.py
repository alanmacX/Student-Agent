"""DingTalk message filtering, classification & routing.

Two-stage design (per product spec):

  Stage 1 — keyword coarse filter (this module, cheap, deterministic):
    * drop obvious noise (system events, recalls, admin notices, attendance)
    * keep obvious course content (homework / exam / ddl keywords, 1:1 chats)
    * route everything uncertain in *group* chats to the LLM (needs_llm)

  Stage 2 — LLM fine filter (classifier.py, persona-aware):
    * decide notify / interest / drop for the uncertain bucket
    * judge CS relevance against the user persona

Final routing buckets (the ``verdict`` field):
    notify   -> push + store (course content, 1:1, CS-strong)
    interest -> store under "你可能感兴趣", no push (CS-related but non-urgent)
    drop     -> ignore (pure noise, non-CS activities/recruitment)
    needs_llm-> placeholder until classifier runs
"""
import json
import os
import re
from typing import Any, Dict, List, Optional, Tuple

SELF_UID = os.getenv("DINGTALK_SELF_UID", "2679549222")

# Service / system account uids are small integers; human uids are 8-10 digits.
SYSTEM_UID_MAX = int(os.getenv("DINGTALK_SYSTEM_UID_MAX", "10000000"))
EXPLICIT_SYSTEM_UIDS = {"20991", "21000", "1", "2"}
SYSTEM_TITLE_RE = re.compile(r"(工作通知|钉钉|安全助手|系统通知|DING|审批|签到|考勤打卡)", re.I)

# ── content type -> (media_type, type_keep, needs_ocr) ────────────────────────
CONTENT_TYPE_MAP: Dict[int, Tuple[str, bool, bool]] = {
    1: ("text", True, False),
    2: ("image", True, True),
    3: ("audio", True, False),
    5: ("video", True, False),
    102: ("file", True, True),
    500: ("file", True, True),
    501: ("card", False, False),
    1201: ("link_card", False, False),
    2950: ("interactive_card", False, False),
}
DEFAULT_KEEP_UNKNOWN = False
OCR_FILE_EXT_RE = re.compile(r"\.(pdf|png|jpe?g|bmp|tiff?|webp|heic)$", re.I)

# ── category keyword tables (coarse) ──────────────────────────────────────────
# Order matters: first match wins in classify_category().
CATEGORY_PATTERNS: List[Tuple[str, Any]] = [
    ("system_event", re.compile(r"(通过扫描.*加入该群|加入了群聊|移出了?群聊|撤回了一条消息|该消息被撤回|开启了群直播|发起了群直播)")),
    ("course", re.compile(r"(作业|实验报告|实验课|课程设计|课设|ddl|截止|交.{0,3}报告|提交.{0,4}(作业|代码|报告)|考试|补考|重修|复习|课件|课堂|上课|调课|停课|助教|答疑|实验室开放|期中|期末|论文.{0,3}(提交|批改))", re.I)),
    ("competition", re.compile(r"(竞赛|大赛|挑战赛|算法赛|程序设计大赛|ACM|蓝桥杯|数模|数学建模|天梯赛|CTF|kaggle|hackathon|黑客松)", re.I)),
    ("recruitment", re.compile(r"(招聘|宣讲会|双选会|招新|纳新|实习|内推|offer|求职|招募|招干|社团|志愿者|志愿活动|文艺|晚会|文体|运动会|球赛|联谊|团建)")),
    ("admin", re.compile(r"(考勤|打卡|学风|通报|查寝|查课|到课率|卫生检查|班会|团日|易班|资助|困难补助|心理普查|安全教育|国家安全|疫情|核酸|问卷|填表|统计.{0,4}(信息|名单)|收取.{0,4}费)")),
    ("academic_affair", re.compile(r"(大创|大学生创新|结题|中期检查|立项|评奖|评优|奖学金|助学金|转专业|学籍|选课|绩点|保研|推免|学分|教务|成绩单|四六级|英语等级)")),
]

# CS relevance (persona: CS undergrad). Used to gate the "interest" bucket.
CS_RELATED_RE = re.compile(
    r"(计算机|算法|编程|程序|代码|软件|开发|前端|后端|全栈|数据库|数据结构|操作系统|网络|人工智能|机器学习|深度学习|神经网络|大模型|AI|LLM|python|java|c\+\+|golang|rust|javascript|linux|算力|GPU|ACM|蓝桥|CTF|kaggle|leetcode|github)",
    re.I,
)


def _parse_cid(cid: str) -> Tuple[Optional[str], bool]:
    if not cid:
        return None, False
    if ":" not in cid:
        return None, True  # group conversation
    parts = cid.split(":")
    peer = next((p for p in parts if p != SELF_UID), parts[0])
    return peer, False


def is_system_conversation(cid: str, title: Optional[str]) -> bool:
    peer_uid, is_group = _parse_cid(cid)
    if not is_group and peer_uid is not None:
        if peer_uid in EXPLICIT_SYSTEM_UIDS:
            return True
        if peer_uid.isdigit() and int(peer_uid) < SYSTEM_UID_MAX:
            return True
    if title and SYSTEM_TITLE_RE.search(title):
        return True
    return False


def classify_content_type(content_type: Optional[int]) -> Tuple[str, bool, bool]:
    if content_type is None:
        return ("unknown", DEFAULT_KEEP_UNKNOWN, False)
    if content_type in CONTENT_TYPE_MAP:
        return CONTENT_TYPE_MAP[content_type]
    if content_type >= 200:
        return ("card", False, False)
    return ("unknown", DEFAULT_KEEP_UNKNOWN, False)


def classify_category(text: Optional[str]) -> str:
    """Coarse content category from keywords. Returns 'unknown' if no match."""
    if not text:
        return "unknown"
    for name, pat in CATEGORY_PATTERNS:
        if pat.search(text):
            return name
    return "unknown"


def is_cs_related(text: Optional[str]) -> bool:
    return bool(text and CS_RELATED_RE.search(text))


def parse_attachments(raw_content: Optional[str]) -> List[Dict[str, Any]]:
    if not raw_content:
        return []
    try:
        payload = json.loads(raw_content)
    except Exception:
        return []
    out: List[Dict[str, Any]] = []
    for att in payload.get("attachments", []) or []:
        if not isinstance(att, dict):
            continue
        out.append({
            "type": att.get("type"),
            "url": att.get("url") or "",
            "name": att.get("name") or att.get("fileName") or "",
            "size": att.get("size") or 0,
            "media_id": att.get("mediaId") or att.get("spaceId") or "",
        })
    media = payload.get("authMedia") or payload.get("pictureDownloadInfo")
    if isinstance(media, dict):
        out.append({
            "type": "image",
            "url": media.get("url") or "",
            "media_id": media.get("authMediaId") or media.get("mediaId") or "",
            "name": "",
            "size": 0,
        })
    return out


def needs_ocr_for(media_type: str, attachments: List[Dict[str, Any]]) -> bool:
    if media_type == "image":
        return True
    if media_type == "file":
        for att in attachments:
            if att.get("name") and OCR_FILE_EXT_RE.search(str(att["name"])):
                return True
        return True
    return False


def _has_link(text: Optional[str], attachments: List[Dict[str, Any]]) -> bool:
    if text and re.search(r"https?://", text):
        return True
    return any(a.get("url", "").startswith("http") for a in attachments)


# Buckets
NOTIFY, INTEREST, DROP, NEEDS_LLM = "notify", "interest", "drop", "needs_llm"


def evaluate(msg: Dict[str, Any]) -> Dict[str, Any]:
    """Stage-1 coarse evaluation. Sets media/ocr fields and an initial verdict.

    verdict == NEEDS_LLM means the classifier must make the final call.
    """
    cid = msg.get("cid") or ""
    title = msg.get("conversation_title")
    content_type = msg.get("content_type")
    text = (msg.get("text") or "").strip()

    media_type, type_keep, type_needs_ocr = classify_content_type(content_type)
    system_conv = is_system_conversation(cid, title)
    attachments = parse_attachments(msg.get("raw_content"))
    needs_ocr = type_needs_ocr or needs_ocr_for(media_type, attachments)
    _peer, is_group = _parse_cid(cid)
    category = classify_category(text)
    cs = is_cs_related(text) or is_cs_related(title)
    has_link = _has_link(text, attachments)

    # ── verdict decision ──
    verdict = NEEDS_LLM
    reason = ""

    if system_conv:
        verdict, reason = DROP, "system conversation"
    elif not type_keep:
        verdict, reason = DROP, f"noise content type ({media_type})"
    elif category == "system_event":
        verdict, reason = DROP, "group system event"
    elif not is_group:
        # 1:1 chats are always relevant (with text or media)
        if text or needs_ocr or media_type in ("audio", "video"):
            verdict, reason = NOTIFY, "direct message"
        else:
            verdict, reason = DROP, "empty direct message"
    else:
        # group chat
        if category == "course":
            verdict, reason = NOTIFY, "course keyword"
        elif category == "admin":
            verdict, reason = DROP, "admin notice"
        elif category in ("recruitment", "academic_affair", "competition"):
            # CS-related -> interest; otherwise let LLM confirm (links/long text
            # may still be CS-relevant). Pure non-CS recruitment/admin -> LLM/drop.
            if cs:
                verdict, reason = INTEREST, f"{category} (cs)"
            else:
                verdict, reason = NEEDS_LLM, f"{category} (non-cs, needs llm)"
        elif needs_ocr:
            # image/file in group: needs OCR before we can judge -> LLM later
            verdict, reason = NEEDS_LLM, "group media needs ocr+llm"
        elif has_link:
            verdict, reason = NEEDS_LLM, "group link needs llm"
        elif not text:
            verdict, reason = DROP, "empty group message"
        else:
            verdict, reason = NEEDS_LLM, "group text uncertain"

    keep = verdict in (NOTIFY, INTEREST, NEEDS_LLM)
    out = dict(msg)
    out.update({
        "media_type": media_type,
        "category": category,
        "is_cs_related": 1 if cs else 0,
        "is_system": 1 if system_conv else 0,
        "is_group": 1 if is_group else 0,
        "has_link": 1 if has_link else 0,
        "needs_ocr": 1 if (keep and needs_ocr) else 0,
        "ocr_status": "pending" if (keep and needs_ocr) else "none",
        "attachments": json.dumps(attachments, ensure_ascii=False) if attachments else None,
        "verdict": verdict,
        "verdict_reason": reason,
        "_keep": keep,
        "_needs_llm": verdict == NEEDS_LLM,
    })
    return out
