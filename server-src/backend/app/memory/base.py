"""app/memory/base.py

Shared types and the MemoryRepository — the single write/read interface
for all memory providers.  No provider should touch chaoxing_memory_entries
directly; go through this module.
"""
from __future__ import annotations

import json
import uuid
from dataclasses import dataclass, field
from datetime import datetime, timedelta, timezone
from typing import Any

import aiosqlite

# Physical table name (legacy; kept as-is to avoid a risky rename migration)
_TABLE = "chaoxing_memory_entries"

# Kinds eligible for cross-source fuzzy reconciliation (title-containment).
# Deliberately excludes 'message' — free-form chat titles vary too much and
# would over-merge.
_RECONCILE_KINDS = {"assignment", "course", "reminder", "exam"}


# ── Hierarchy tiers ───────────────────────────────────────────────────────────
class Tier:
    CRITICAL   = 0   # expires today / explicit urgent flag
    ACTIONABLE = 1   # expires this week, has action_hint
    CONTEXT    = 2   # background info worth noting
    REFERENCE  = 3   # ideas, notes, long-term reference
    HISTORICAL = 4   # compressed summaries of past events


def compute_tier(
    importance: str,
    expires_at: datetime | None,
    for_automation: bool,
    now: datetime,
) -> int:
    if expires_at:
        days_left = (expires_at - now).total_seconds() / 86400
        if days_left <= 1:
            return Tier.CRITICAL
        if days_left <= 7 and for_automation:
            return Tier.ACTIONABLE
    if importance == "high" and for_automation:
        return Tier.ACTIONABLE
    if importance in ("high", "medium"):
        return Tier.CONTEXT
    return Tier.REFERENCE


# ── Data class ────────────────────────────────────────────────────────────────
@dataclass
class MemoryEntry:
    # Core
    title:        str
    summary:      str
    reason:       str
    importance:   str    = "medium"    # high | medium | low
    action_hint:  str    = ""
    category:     str    = "notice"
    kind:         str    = "message"   # message | assignment | course | reminder | idea
    source_type:  str    = "chaoxing"  # chaoxing | dingtalk | idea | shopping | user

    # Time
    content_time: datetime | None = None
    expires_at:   datetime | None = None

    # Routing
    hierarchy_tier:  int  = Tier.CONTEXT
    for_automation:  bool = False

    # Dedup
    dedupe_key:   str  = ""

    # Provenance (stored as JSON arrays)
    source_ids:           list[str] = field(default_factory=list)
    conversation_ids:     list[str] = field(default_factory=list)
    conversation_names:   list[str] = field(default_factory=list)
    sender_names:         list[str] = field(default_factory=list)

    # Optional linkage
    linked_assignment_key: str | None = None
    linked_course_key:     str | None = None
    confidence:            float      = 0.8


# ── Repository ────────────────────────────────────────────────────────────────
class MemoryRepository:
    """
    Thin async wrapper around chaoxing_memory_entries.
    All providers call upsert_entry(); all consumers call query_*().
    """

    def __init__(self, db_path: str):
        self.db_path = db_path

    # ── Write ─────────────────────────────────────────────────────────────────

    async def upsert_entry(self, entry: MemoryEntry, now: datetime) -> str:
        """Insert or update a MemoryEntry.  Returns the entry id."""
        if now.tzinfo is None:
            now = now.replace(tzinfo=timezone.utc)

        expires_at = entry.expires_at or (now + timedelta(days=14))
        content_time = entry.content_time
        tier = entry.hierarchy_tier
        ni = now.isoformat()

        async with aiosqlite.connect(self.db_path) as db:
            db.row_factory = aiosqlite.Row

            # Layer 1 — exact dedup key (same entity, same source convention).
            existing = None
            if entry.dedupe_key:
                existing = await (await db.execute(
                    f"SELECT id, source_type FROM {_TABLE} WHERE dedupe_key=?",
                    (entry.dedupe_key,),
                )).fetchone()

            # Layer 2 — cross-source reconciliation. When two sources disagree on
            # the exact key (e.g. the LLM titles an assignment slightly
            # differently than the structured sync), fall back to a conservative
            # same-kind title-containment match so we update the canonical row
            # instead of creating a duplicate.
            reconciled = False
            if not existing and entry.kind in _RECONCILE_KINDS:
                existing = await self._reconcile(db, entry)
                reconciled = existing is not None

            if existing:
                eid = existing["id"]
                # On a fuzzy reconcile-merge, preserve the existing row's
                # source_type (the structured/canonical anchor) rather than
                # letting a later automation pass overwrite it.
                src = entry.source_type
                if reconciled and existing["source_type"]:
                    src = existing["source_type"]
                await db.execute(
                    f"""UPDATE {_TABLE} SET
                        title=?, summary=?, importance=?, action_hint=?,
                        expires_at=?, hierarchy_tier=?, for_automation=?,
                        source_type=?, kind=?, category=?,
                        confidence=?, updated_at=?, archived_at=NULL
                        WHERE id=?""",
                    (
                        entry.title, entry.summary, entry.importance,
                        entry.action_hint,
                        expires_at.isoformat(), tier,
                        1 if entry.for_automation else 0,
                        src, entry.kind, entry.category,
                        entry.confidence, ni, eid,
                    ),
                )
            else:
                eid = str(uuid.uuid4())
                await db.execute(
                    f"""INSERT INTO {_TABLE}
                        (id, title, summary, reason, importance, action_hint,
                         category, kind, source_type, confidence,
                         hierarchy_tier, for_automation,
                         expires_at, content_time,
                         dedupe_key,
                         source_ids_json, conversation_ids_json,
                         conversation_names_json, sender_names_json,
                         source_fingerprints_json, related_ids_json,
                         sent_at, extracted_at, created_at, updated_at)
                        VALUES (?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?)""",
                    (
                        eid,
                        entry.title, entry.summary, entry.reason,
                        entry.importance, entry.action_hint,
                        entry.category, entry.kind, entry.source_type,
                        entry.confidence,
                        tier, 1 if entry.for_automation else 0,
                        expires_at.isoformat(),
                        content_time.isoformat() if content_time else None,
                        entry.dedupe_key,
                        json.dumps(entry.source_ids, ensure_ascii=False),
                        json.dumps(entry.conversation_ids, ensure_ascii=False),
                        json.dumps(entry.conversation_names, ensure_ascii=False),
                        json.dumps(entry.sender_names, ensure_ascii=False),
                        "[]", "[]",
                        ni, ni, ni, ni,
                    ),
                )
            # Index high-signal keys for cross-source reconciliation + the
            # engine's "related entries" context. Idempotent (PK on key+id).
            await self._index_entity(db, eid, entry, expires_at)
            await db.commit()
        return eid

    async def _reconcile(self, db, entry: MemoryEntry):
        """Conservative same-kind reconciliation by normalized-title containment.

        Returns an existing row (id, source_type) describing the same
        real-world entity, or None. Both titles must be >= 6 normalized chars to
        avoid over-merging on generic words.
        """
        from app.memory.keys import normalize

        nt = normalize(entry.title)
        if len(nt) < 6:
            return None
        rows = await (await db.execute(
            f"SELECT id, title, source_type FROM {_TABLE} "
            f"WHERE kind=? AND archived_at IS NULL",
            (entry.kind,),
        )).fetchall()
        for r in rows:
            et = normalize(r["title"])
            if len(et) < 6:
                continue
            if nt == et or nt in et or et in nt:
                return r
        return None

    async def _index_entity(self, db, eid: str, entry: MemoryEntry,
                            expires_at: datetime) -> None:
        from app.memory.keys import reconcile_keys

        expires_iso = expires_at.isoformat() if expires_at else None
        for key in reconcile_keys(entry.kind, entry.title):
            await db.execute(
                """INSERT OR REPLACE INTO memory_topic_index
                   (entity_key, entity_type, memory_id, source_type, expires_at)
                   VALUES (?,?,?,?,?)""",
                (key, entry.kind, eid, entry.source_type, expires_iso),
            )

    async def mark_source_synced(
        self, source_type: str, last_ts: int, entry_count: int, now: datetime
    ) -> None:
        async with aiosqlite.connect(self.db_path) as db:
            await db.execute(
                """INSERT OR REPLACE INTO memory_sync_state
                   (source_type, last_synced_ts, last_run_at, entry_count)
                   VALUES (?,?,?,?)""",
                (source_type, last_ts, now.isoformat(), entry_count),
            )
            await db.commit()

    async def get_last_synced_ts(self, source_type: str) -> int:
        async with aiosqlite.connect(self.db_path) as db:
            row = await (await db.execute(
                "SELECT last_synced_ts FROM memory_sync_state WHERE source_type=?",
                (source_type,),
            )).fetchone()
        return row[0] if row else 0

    async def sweep(self, now: datetime, cap: int = 120) -> dict:
        """Delete expired entries, trim active count to cap, and clean up the
        ``memory_topic_index`` rows that those deletes orphan.

        (Despite the historical name this hard-deletes rather than archiving —
        the table is a rolling cache, not an audit log. The orphan cleanup
        matters: ``_index_entity``/``_update_topic_index`` only ever insert, so
        without this the index grows unbounded and pollutes context matching.)
        """
        if now.tzinfo is None:
            now = now.replace(tzinfo=timezone.utc)
        deleted_expired = trimmed = 0
        async with aiosqlite.connect(self.db_path) as db:
            cur = await db.execute(
                f"DELETE FROM {_TABLE} WHERE expires_at IS NOT NULL AND expires_at <= ?",
                (now.isoformat(),),
            )
            deleted_expired = cur.rowcount
            row = await (await db.execute(
                f"SELECT COUNT(*) FROM {_TABLE} WHERE archived_at IS NULL"
            )).fetchone()
            count = row[0] if row else 0
            if count > cap:
                excess = count - cap
                await db.execute(
                    f"""DELETE FROM {_TABLE}
                        WHERE id IN (
                            SELECT id FROM {_TABLE}
                            WHERE archived_at IS NULL
                            ORDER BY hierarchy_tier DESC,
                                     CASE importance WHEN 'high' THEN 3
                                                     WHEN 'medium' THEN 2
                                                     ELSE 1 END ASC,
                                     COALESCE(updated_at, created_at) ASC
                            LIMIT ?
                        )""",
                    (excess,),
                )
                trimmed = excess
            # Cascade: drop topic-index rows whose memory entry no longer exists.
            idx = await db.execute(
                f"""DELETE FROM memory_topic_index
                    WHERE memory_id NOT IN (SELECT id FROM {_TABLE})"""
            )
            orphans_cleaned = idx.rowcount
            await db.commit()
        return {"deleted_expired": deleted_expired, "trimmed": trimmed,
                "topic_index_orphans_cleaned": orphans_cleaned}

    # ── Read ──────────────────────────────────────────────────────────────────

    async def query_for_agent(
        self,
        now: datetime,
        user_message: str = "",
        max_tier: int = Tier.CONTEXT,
        limit: int = 8,
    ) -> list[dict[str, Any]]:
        """
        Two-layer retrieval:
          Layer A: tier 0-1 (always, deadline/urgent)
          Layer B: tier 2+ filtered by keyword overlap with user_message
        """
        if now.tzinfo is None:
            now = now.replace(tzinfo=timezone.utc)

        async with aiosqlite.connect(self.db_path) as db:
            db.row_factory = aiosqlite.Row

            # Layer A: critical + actionable (always inject)
            tier_a = list(await (await db.execute(
                f"""SELECT id, title, action_hint, importance, hierarchy_tier,
                           expires_at, source_type, kind
                    FROM {_TABLE}
                    WHERE hierarchy_tier <= 1
                      AND archived_at IS NULL
                      AND (expires_at IS NULL OR expires_at > ?)
                    ORDER BY hierarchy_tier ASC, expires_at ASC
                    LIMIT 4""",
                (now.isoformat(),),
            )).fetchall())

            # Layer B: context entries matching keywords
            tier_b: list = []
            keywords = _extract_keywords(user_message)
            if keywords and max_tier >= Tier.CONTEXT:
                rows = await (await db.execute(
                    f"""SELECT id, title, action_hint, importance, hierarchy_tier,
                               expires_at, source_type, kind
                        FROM {_TABLE}
                        WHERE hierarchy_tier BETWEEN 2 AND ?
                          AND archived_at IS NULL
                          AND (expires_at IS NULL OR expires_at > ?)
                        ORDER BY hierarchy_tier ASC, importance DESC
                        LIMIT 20""",
                    (max_tier, now.isoformat()),
                )).fetchall()
                # Score by keyword overlap
                scored = [
                    (row, _keyword_score(row["title"] + " " + (row["action_hint"] or ""), keywords))
                    for row in rows
                ]
                scored.sort(key=lambda x: -x[1])
                tier_b = [r for r, s in scored if s > 0][:3]

        seen = set()
        result = []
        for r in list(tier_a) + tier_b:
            key = r["title"]
            if key not in seen:
                seen.add(key)
                result.append(dict(r))
        return result[:limit]

    async def query_for_automation(
        self,
        now: datetime,
        window_hours: int = 48,
        source_type: str | None = None,
    ) -> list[dict[str, Any]]:
        """Pure SQL, zero LLM. Used by standby_agent, notification_sender."""
        if now.tzinfo is None:
            now = now.replace(tzinfo=timezone.utc)
        deadline = (now + timedelta(hours=window_hours)).isoformat()
        source_clause = "AND source_type=?" if source_type else ""
        params: list = [now.isoformat(), deadline]
        if source_type:
            params.append(source_type)
        async with aiosqlite.connect(self.db_path) as db:
            db.row_factory = aiosqlite.Row
            rows = await (await db.execute(
                f"""SELECT title, action_hint, importance, hierarchy_tier,
                           expires_at, source_type, kind, category
                    FROM {_TABLE}
                    WHERE for_automation=1
                      AND action_hint IS NOT NULL AND action_hint != ''
                      AND archived_at IS NULL
                      AND expires_at BETWEEN ? AND ?
                      {source_clause}
                    ORDER BY hierarchy_tier ASC, expires_at ASC
                    LIMIT 20""",
                params,
            )).fetchall()
        return [dict(r) for r in rows]


# ── Helpers ───────────────────────────────────────────────────────────────────

def _extract_keywords(text: str) -> list[str]:
    """Very cheap keyword extraction — no NLP library needed."""
    import re
    # Remove punctuation, split CJK by character + split ASCII by word
    text = text.lower()
    cjk = re.findall(r'[一-鿿]{2,}', text)
    ascii_words = [w for w in re.findall(r'[a-z]{3,}', text) if w not in _STOP]
    # Bigrams for CJK
    all_kw: list[str] = ascii_words[:]
    for chunk in cjk:
        all_kw.append(chunk)
        for i in range(len(chunk) - 1):
            all_kw.append(chunk[i:i+2])
    return list(dict.fromkeys(all_kw))  # deduplicate, preserve order


def _keyword_score(text: str, keywords: list[str]) -> int:
    text = text.lower()
    return sum(1 for kw in keywords if kw in text)


_STOP = {"the", "and", "for", "are", "but", "not", "you", "all", "can", "was", "has"}
