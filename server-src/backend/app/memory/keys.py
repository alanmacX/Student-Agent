"""app/memory/keys.py — Canonical entity-key registry.

Single source of truth for the keys that identify a real-world entity across
*all* memory sources (structured sync, the LLM automation engine, and any
future provider). One entity → one key → one row, regardless of which source
saw it first.

Two responsibilities:

  canonical_dedupe_key(kind, **fields)
      Deterministic primary dedup key written to ``chaoxing_memory_entries.
      dedupe_key``. Same entity from any source must produce the same key.
      The per-kind builders below intentionally reproduce the historical key
      formats byte-for-byte so existing rows keep reconciling after upgrade.

  reconcile_keys(kind, title, **fields)
      High-signal lookup tokens used as a *fallback* when two sources can't
      agree on an exact dedupe key (e.g. the LLM titles an assignment slightly
      differently than the structured sync). Deliberately excludes noisy
      bigrams — see MemoryRepository._reconcile for how they're matched.

Extending — to add a new entity kind:

    from app.memory.keys import register_kind
    register_kind("exam", lambda f: "exam::" + normalize(
        f.get("course", "")) + "::" + normalize(f.get("title", "")))

No other module needs to change; providers just pass ``kind="exam"`` on the
MemoryEntry / intent. Unregistered kinds fall back to ``<kind>::<title>``.
"""
from __future__ import annotations

from typing import Callable

from app.services.memory_models import key_text as normalize

# A key builder takes a dict of fields and returns the canonical dedupe key.
KeyBuilder = Callable[[dict], str]

_BUILDERS: dict[str, KeyBuilder] = {}


def register_kind(kind: str, builder: KeyBuilder) -> None:
    """Register (or override) the canonical key builder for an entity kind."""
    _BUILDERS[kind] = builder


def _default_builder(kind: str) -> KeyBuilder:
    return lambda f: f"{kind}::" + normalize(str(f.get("title") or ""))


def canonical_dedupe_key(kind: str, **fields) -> str:
    """Build the canonical dedup key for an entity of ``kind``."""
    builder = _BUILDERS.get(kind) or _default_builder(kind)
    return builder(fields)


def reconcile_keys(kind: str, title: str, **fields) -> list[str]:
    """High-signal keys for cross-source reconciliation.

    Returns the canonical dedupe key plus the normalized full title. Short
    tokens (< 6 chars normalized) are dropped to avoid over-merging on generic
    words like "作业" / "通知".
    """
    keys: list[str] = []
    ck = canonical_dedupe_key(kind, title=title, **fields)
    if ck:
        keys.append(ck)
    nt = normalize(str(title or ""))
    if len(nt) >= 6:
        keys.append(nt)
    return list(dict.fromkeys(k for k in keys if k))


# ── Built-in kinds — these reproduce the pre-refactor key formats exactly ─────
# IMPORTANT: assignment historically concatenated course+title (the inner "::"
# is stripped by normalize), while course kept the "::" separators. Keep both
# as-is so existing dedupe_key values continue to match.

register_kind(
    "assignment",
    lambda f: "assignment::" + normalize(f"{f.get('course') or ''}::{f.get('title') or ''}"),
)
register_kind(
    "course",
    lambda f: "course::" + normalize(f.get("title") or "") + "::" + normalize(f.get("start") or ""),
)
register_kind(
    "reminder",
    lambda f: "reminder::" + normalize(f.get("title") or ""),
)
register_kind(
    "exam",
    lambda f: "exam::" + normalize(f"{f.get('course') or ''}::{f.get('title') or ''}"),
)


# ── entity_type (LLM IntentGraph) → memory kind mapping ───────────────────────
# The intent extractor speaks in entity_type; memory rows speak in kind.
_ENTITY_TYPE_TO_KIND = {
    "assignment": "assignment",
    "course": "course",
    "reminder": "reminder",
    "exam": "exam",
}


def kind_from_entity_type(entity_type: str | None) -> str:
    """Map an IntentGraph entity_type to a memory kind. Unknown → 'message'."""
    return _ENTITY_TYPE_TO_KIND.get((entity_type or "").strip().lower(), "message")
