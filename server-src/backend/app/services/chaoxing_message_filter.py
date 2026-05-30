from __future__ import annotations
import json
import re
from datetime import datetime, timedelta, timezone

import aiosqlite

from .memory_models import display_text, key_text, parse_iso, sha256_hex


class ChaoxingTextNormalizer:
    @staticmethod
    def display_text(value: str) -> str:
        return display_text(value)

    @staticmethod
    def key_text(value: str) -> str:
        return key_text(value)

    @staticmethod
    def preview(value: str, limit: int) -> str:
        text = display_text(value)
        return text if len(text) <= limit else text[: max(0, limit - 3)] + "..."


NOISE_TYPES = {"READ_ACK", "DELIVER_ACK", "RECALL"}
SHORT_CHATTER = {
    "好", "好的", "收到", "收到了", "ok", "OK", "嗯", "嗯嗯",
    "是", "不是", "谢谢", "辛苦了", "+1", "晚安", "哈哈", "强强", "666",
}
FUTURE_CUES = [
    "今天", "明天", "后天", "本周", "下周", "周一", "周二", "周三", "周四", "周五",
    "周六", "周日", "截止", "考试", "上课", "调课", "停课", "补课", "教室", "DDL", "ddl",
]

ONE_HOUR = timedelta(hours=1)
ONE_DAY = timedelta(days=1)
SEVEN_DAYS = timedelta(days=7)
THIRTY_DAYS = timedelta(days=30)


def normalize_message(msg: dict) -> dict:
    text = display_text(msg.get("text", ""))
    sent_dt = parse_iso(msg.get("sent_at")) or datetime.now(timezone.utc)
    fingerprint_base = "|".join([
        str(msg.get("conversation_id") or ""),
        str(msg.get("sender_id") or "unknown"),
        str(int(sent_dt.timestamp() / 60)),
        key_text(text),
        ",".join(msg.get("image_urls") or []),
    ])
    return {
        "source_id": str(msg.get("id") or ""),
        "fingerprint": sha256_hex(fingerprint_base),
        "conversation_id": str(msg.get("conversation_id") or ""),
        "conversation_name": display_text(msg.get("conversation_name") or ""),
        "is_group": bool(msg.get("is_group")),
        "sender_id": str(msg.get("sender_id") or "unknown"),
        "sender_name": msg.get("sender_name"),
        "sent_at": sent_dt.isoformat(),
        "type": msg.get("type") or "TEXT",
        "text": text,
        "normalized_text": key_text(text),
        "image_urls": msg.get("image_urls") or [],
        "_raw": msg,
    }


def contains_future_cue(text: str) -> bool:
    if any(cue in text for cue in FUTURE_CUES):
        return True
    return re.search(r"\d{1,2}[月/-]\d{1,2}", text) is not None


def is_pure_chatter(text: str) -> bool:
    normalized = display_text(text).strip()
    if not normalized:
        return True
    if normalized in SHORT_CHATTER:
        return True
    return len(normalized) <= 3 and not contains_future_cue(normalized)


def is_duplicate_assignment_notice(msg: dict, assignments: list[dict]) -> bool:
    text = msg.get("text") or ""
    if not any(token in text.lower() for token in ("作业", "任务", "截止", "ddl")):
        return False
    normalized = msg.get("normalized_text") or key_text(text)
    for assignment in assignments:
        title_key = key_text(assignment.get("title") or "")
        if title_key and title_key in normalized:
            return True
    return False


async def load_sync_state(db_path: str) -> dict:
    async with aiosqlite.connect(db_path) as db:
        processed_rows = await (await db.execute(
            "SELECT message_id FROM chaoxing_processed_ids"
        )).fetchall()
        fingerprint_rows = await (await db.execute(
            "SELECT fingerprint FROM chaoxing_processed_fingerprints"
        )).fetchall()
        init_row = await (await db.execute(
            "SELECT value FROM chaoxing_sync_state WHERE key='initialized_at'"
        )).fetchone()
        conv_rows = await (await db.execute("""
            SELECT conversation_id, last_seen_sent_at, last_seen_message_id, seen_count, created_at, updated_at
            FROM chaoxing_conversation_sync
        """)).fetchall()
    return {
        "processed_source_ids": {r[0] for r in processed_rows},
        "processed_fingerprints": {r[0] for r in fingerprint_rows},
        "initialized_at": init_row[0] if init_row else None,
        "conversations": {
            r[0]: {
                "last_seen_sent_at": r[1],
                "last_seen_message_id": r[2],
                "seen_count": r[3],
                "created_at": r[4],
                "updated_at": r[5],
            }
            for r in conv_rows
        },
    }


async def save_sync_state(db_path: str, result: dict, messages: list[dict], now: datetime) -> None:
    now_iso = now.isoformat()
    processed_ids = result.get("processed_source_ids") or set()
    processed_fingerprints = result.get("processed_fingerprints") or set()
    async with aiosqlite.connect(db_path) as db:
        for source_id in processed_ids:
            await db.execute(
                "INSERT OR IGNORE INTO chaoxing_processed_ids (message_id, processed_at) VALUES (?,?)",
                (source_id, now_iso),
            )
        for fingerprint in processed_fingerprints:
            await db.execute(
                "INSERT OR IGNORE INTO chaoxing_processed_fingerprints (fingerprint, processed_at) VALUES (?,?)",
                (fingerprint, now_iso),
            )
        init_row = await (await db.execute(
            "SELECT value FROM chaoxing_sync_state WHERE key='initialized_at'"
        )).fetchone()
        if not init_row:
            await db.execute(
                "INSERT OR REPLACE INTO chaoxing_sync_state (key, value) VALUES ('initialized_at', ?)",
                (now_iso,),
            )

        by_conversation: dict[str, list[dict]] = {}
        for msg in messages:
            cid = msg.get("conversation_id")
            if cid:
                by_conversation.setdefault(cid, []).append(msg)
        for cid, conv_msgs in by_conversation.items():
            conv_msgs.sort(key=lambda m: m.get("sent_at") or "", reverse=True)
            newest = conv_msgs[0]
            existing = await (await db.execute(
                "SELECT seen_count, created_at FROM chaoxing_conversation_sync WHERE conversation_id=?",
                (cid,),
            )).fetchone()
            seen_count = (existing[0] if existing else 0) + len(conv_msgs)
            created_at = existing[1] if existing else now_iso
            await db.execute("""
                INSERT OR REPLACE INTO chaoxing_conversation_sync
                (conversation_id, last_seen_sent_at, last_seen_message_id, seen_count, created_at, updated_at)
                VALUES (?,?,?,?,?,?)
            """, (cid, newest.get("sent_at"), newest.get("source_id") or newest.get("id"), seen_count, created_at, now_iso))

        await _trim_processed(db, "chaoxing_processed_ids", "message_id")
        await _trim_processed(db, "chaoxing_processed_fingerprints", "fingerprint")
        await db.commit()


async def _trim_processed(db, table: str, id_column: str) -> None:
    row = await (await db.execute(f"SELECT COUNT(*) FROM {table}")).fetchone()
    if not row or row[0] <= 4000:
        return
    await db.execute(f"""
        DELETE FROM {table}
        WHERE {id_column} IN (
            SELECT {id_column} FROM {table}
            ORDER BY processed_at ASC
            LIMIT 2000
        )
    """)


def run(
    messages: list[dict],
    sync_state: dict,
    assignments: list[dict],
    muted_names: set[str] | None = None,
    now: datetime | None = None,
) -> dict:
    now = now or datetime.now(timezone.utc)
    if now.tzinfo is None:
        now = now.replace(tzinfo=timezone.utc)
    muted = {(name or "").lower() for name in (muted_names or set())}
    processed_source_ids = set(sync_state.get("processed_source_ids") or set())
    processed_fingerprints = set(sync_state.get("processed_fingerprints") or set())
    candidates: list[dict] = []
    dropped_reasons: dict[str, str] = {}

    for raw in messages:
        msg = normalize_message(raw)
        sid = msg["source_id"]

        if sid in processed_source_ids or msg["fingerprint"] in processed_fingerprints:
            dropped_reasons[sid] = "already_processed"
            continue
        if msg["conversation_name"].lower() in muted:
            dropped_reasons[sid] = "muted_conversation"
            continue
        if msg["type"] in NOISE_TYPES:
            dropped_reasons[sid] = "noise_type"
            continue
        if not msg["text"] and not msg["image_urls"]:
            dropped_reasons[sid] = "empty_message"
            continue

        sent_dt = parse_iso(msg["sent_at"]) or now
        msg_age = now - sent_dt
        if msg_age <= ONE_HOUR:
            candidates.append(msg)
            continue
        skip_time_checks = msg_age <= ONE_DAY

        if msg_age > THIRTY_DAYS and not contains_future_cue(msg["text"]):
            dropped_reasons[sid] = "stale_30d"
            continue
        if not skip_time_checks and sync_state.get("initialized_at") is None:
            if msg_age > SEVEN_DAYS and not contains_future_cue(msg["text"]):
                dropped_reasons[sid] = "bootstrap_old_without_future_cue"
                continue
        if not skip_time_checks and msg_age > SEVEN_DAYS and not contains_future_cue(msg["text"]):
            dropped_reasons[sid] = "stale_without_future_cue"
            continue

        if is_pure_chatter(msg["text"]):
            dropped_reasons[sid] = "pure_chatter"
            continue
        if is_duplicate_assignment_notice(msg, assignments):
            dropped_reasons[sid] = "duplicate_assignment_notice"
            continue
        candidates.append(msg)

    candidates = candidates[-40:]
    return {
        "candidates": candidates,
        "processed_source_ids": {m["source_id"] for m in candidates},
        "processed_fingerprints": {m["fingerprint"] for m in candidates},
        "dropped_reasons": dropped_reasons,
    }
