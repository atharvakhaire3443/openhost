"""Hybrid graph + semantic recall over the memory store."""
from __future__ import annotations

from typing import Optional

from . import _db


def recall_text(
    memory_id: str,
    query: str,
    *,
    extracted_entities: Optional[list[str]] = None,
    at_time: Optional[int] = None,
    max_facts: int = 12,
) -> str:
    """Return a compact context block summarizing facts relevant to ``query``.

    Strategy (in order):
      1. Graph traversal from mentioned entities (depth 1 neighborhood).
      2. FTS5 fulltext search over fact strings.
      3. Dedupe + render.
    """
    collected: dict[int, dict] = {}

    # 1. Entity-anchored
    for name in extracted_entities or []:
        for fact in _db.facts_about(memory_id, name, at_time=at_time, limit=max_facts):
            collected[fact["id"]] = fact
        # Walk one hop to the neighborhood to pull in related facts
        for neighbor in _db.neighbor_entity_names(memory_id, name):
            for fact in _db.facts_about(memory_id, neighbor, at_time=at_time, limit=max_facts // 2):
                collected[fact["id"]] = fact

    # 2. Text search (only on currently-valid facts; historical queries skip this)
    if at_time is None and len(collected) < max_facts:
        cleaned_query = _fts_sanitize(query)
        if cleaned_query:
            try:
                for fact in _db.search_facts_text(memory_id, cleaned_query, limit=max_facts):
                    collected[fact["id"]] = fact
            except Exception:
                # FTS MATCH can throw on odd queries — ignore
                pass

    facts = list(collected.values())
    facts.sort(key=lambda f: (f.get("confidence") or 0.0, f["valid_from"]), reverse=True)
    facts = facts[:max_facts]
    if not facts:
        return ""
    return _render(facts)


def _render(facts: list[dict]) -> str:
    lines: list[str] = []
    for f in facts:
        obj = f.get("object") or f.get("value_text") or ""
        lines.append(f"- {f['subject']} {f['relation'].replace('_', ' ')} {obj}".rstrip())
    return "\n".join(lines)


def _fts_sanitize(query: str) -> str:
    """Turn a natural-language query into a permissive FTS MATCH clause."""
    tokens = [t for t in "".join(c if c.isalnum() or c == " " else " " for c in query).split() if len(t) > 2]
    if not tokens:
        return ""
    # OR the terms together with phrase prefix matching
    return " OR ".join(f'"{t}"*' for t in tokens)
