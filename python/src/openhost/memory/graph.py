"""Public facade for the temporal knowledge graph memory."""
from __future__ import annotations

from dataclasses import dataclass
from typing import Optional

from . import _db, recall as _recall
from .extractor import Triple, extract_triples


@dataclass
class Fact:
    id: int
    subject: str
    relation: str
    object: Optional[str]
    value_text: Optional[str]
    valid_from: int
    valid_to: Optional[int]
    confidence: float


class Memory:
    """A named temporal knowledge-graph memory.

    Feed it text with :meth:`observe`. Query it with :meth:`recall` or
    :meth:`facts`. Persisted to ``~/.openhost/memory.db``.
    """

    def __init__(self, memory_id: str, extractor_model: str) -> None:
        self.memory_id = memory_id
        self.extractor_model = extractor_model

    # ---- Write ----

    def observe(self, text: str, *, session_id: Optional[str] = None) -> list[Fact]:
        """Extract triples from ``text`` and add them to the graph."""
        text = (text or "").strip()
        if not text:
            return []
        episode_id = _db.record_episode(self.memory_id, text, session_id=session_id)
        triples: list[Triple] = extract_triples(text, self.extractor_model)
        created: list[Fact] = []
        for t in triples:
            if not t.subject or not t.relation:
                continue
            subj_id = _db.upsert_entity(self.memory_id, t.subject)
            obj_id: Optional[int] = None
            if t.object:
                obj_id = _db.upsert_entity(self.memory_id, t.object)
            fact_id = _db.insert_fact(
                memory_id=self.memory_id,
                subject_id=subj_id,
                relation=t.relation,
                object_id=obj_id,
                value_text=t.value_text,
                confidence=float(t.confidence or 0.8),
                source_episode_id=episode_id,
            )
            created.append(
                Fact(
                    id=fact_id,
                    subject=t.subject,
                    relation=t.relation,
                    object=t.object,
                    value_text=t.value_text,
                    valid_from=_now_row_timestamp(fact_id, self.memory_id),
                    valid_to=None,
                    confidence=float(t.confidence or 0.8),
                )
            )
        return created

    # ---- Read ----

    def facts(self, *, about: Optional[str] = None, at_time: Optional[int] = None, limit: int = 50) -> list[Fact]:
        rows = _db.facts_about(self.memory_id, about, at_time=at_time, limit=limit)
        return [
            Fact(
                id=r["id"],
                subject=r["subject"],
                relation=r["relation"],
                object=r["object"],
                value_text=r["value_text"],
                valid_from=r["valid_from"],
                valid_to=r["valid_to"],
                confidence=r["confidence"] or 0.0,
            )
            for r in rows
        ]

    def recall(self, query: str, *, at_time: Optional[int] = None, max_facts: int = 12) -> str:
        """Return a compact natural-language context block relevant to ``query``.

        Uses graph traversal anchored on entities mentioned in the query, plus
        FTS5 text search as a backup.
        """
        entities = self._extract_query_entities(query)
        return _recall.recall_text(
            self.memory_id,
            query,
            extracted_entities=entities,
            at_time=at_time,
            max_facts=max_facts,
        )

    def _extract_query_entities(self, query: str) -> list[str]:
        """Light entity-hint extractor for recall. Pulls proper nouns and
        alpha tokens whose exact lowercase/capitalized form exists in the
        entity table. No extra LLM call — keeps recall cheap."""
        # Tokenize roughly; keep alpha tokens of length ≥ 3
        tokens = [tok for tok in _tokenize(query) if len(tok) >= 3]
        if not tokens:
            return []
        seen: list[str] = []
        with _db._lock, _db._connect() as conn:
            for tok in tokens:
                row = conn.execute(
                    "SELECT name FROM entities WHERE memory_id=? AND "
                    "(lower(name)=lower(?) OR name=?)",
                    (self.memory_id, tok, tok),
                ).fetchone()
                if row:
                    seen.append(row[0])
        return seen


def _tokenize(text: str) -> list[str]:
    out: list[str] = []
    word = ""
    for ch in text:
        if ch.isalpha():
            word += ch
        else:
            if word:
                out.append(word)
                word = ""
    if word:
        out.append(word)
    return out


def _now_row_timestamp(fact_id: int, memory_id: str) -> int:
    """Best-effort: read back the valid_from we just wrote (cheap sqlite lookup)."""
    with _db._lock, _db._connect() as conn:
        row = conn.execute(
            "SELECT valid_from FROM facts WHERE id=? AND memory_id=?",
            (fact_id, memory_id),
        ).fetchone()
        return row[0] if row else 0


def memory(memory_id: str, *, extractor_model: str) -> Memory:
    """Open or create a named memory."""
    return Memory(memory_id, extractor_model)
