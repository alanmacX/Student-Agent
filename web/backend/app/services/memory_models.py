from __future__ import annotations
import hashlib
import re
import unicodedata
from datetime import datetime, timezone


def display_text(value: str | None) -> str:
    text = (value or "").replace("\u00a0", " ").replace("\r", "\n")
    return " ".join(part for part in re.split(r"\s+", text) if part).strip()


def key_text(value: str | None) -> str:
    normalized = display_text(value).lower()
    return "".join(
        ch for ch in normalized
        if not unicodedata.category(ch).startswith(("P", "Z"))
        and not ch.isspace()
    )


def preview(value: str | None, limit: int) -> str:
    text = display_text(value)
    if limit <= 0 or len(text) <= limit:
        return text
    return text[: max(0, limit - 3)] + "..."


def sha256_hex(value: str) -> str:
    return hashlib.sha256(value.encode("utf-8")).hexdigest()


def parse_iso(value: str | None) -> datetime | None:
    if not value:
        return None
    try:
        dt = datetime.fromisoformat(str(value).replace("Z", "+00:00"))
    except ValueError:
        return None
    if dt.tzinfo is None:
        dt = dt.replace(tzinfo=timezone.utc)
    return dt.astimezone(timezone.utc)


def normalize_importance(value: str | None) -> str:
    raw = (value or "medium").strip().lower()
    if raw in {"high", "重要", "高"}:
        return "high"
    if raw in {"low", "低", "普通"}:
        return "low"
    return "medium"


def make_assignment_key(course_name: str | None, title: str | None) -> str:
    return f"{key_text(course_name)}::{key_text(title)}"
