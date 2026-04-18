"""SQLite schema + queries for temporal knowledge graph memory."""
from __future__ import annotations

import sqlite3
import threading
import time
from pathlib import Path
from typing import Optional

from .. import paths


_SCHEMA = """
CREATE TABLE IF NOT EXISTS entities (
    id INTEGER PRIMARY KEY AUTOINCREMENT,
    memory_id TEXT NOT NULL,
    name TEXT NOT NULL,
    type TEXT,
    created_at INTEGER NOT NULL,
    UNIQUE(memory_id, name)
);
CREATE TABLE IF NOT EXISTS facts (
    id INTEGER PRIMARY KEY AUTOINCREMENT,
    memory_id TEXT NOT NULL,
    subject_id INTEGER NOT NULL,
    relation TEXT NOT NULL,
    object_id INTEGER,
    value_text TEXT,
    valid_from INTEGER NOT NULL,
    valid_to INTEGER,
    confidence REAL DEFAULT 0.8,
    source_episode_id INTEGER,
    FOREIGN KEY (subject_id) REFERENCES entities(id),
    FOREIGN KEY (object_id) REFERENCES entities(id)
);
CREATE TABLE IF NOT EXISTS episodes (
    id INTEGER PRIMARY KEY AUTOINCREMENT,
    memory_id TEXT NOT NULL,
    content TEXT NOT NULL,
    created_at INTEGER NOT NULL,
    session_id TEXT
);
CREATE INDEX IF NOT EXISTS idx_facts_subject ON facts(memory_id, subject_id, valid_to);
CREATE INDEX IF NOT EXISTS idx_facts_relation ON facts(memory_id, relation);
CREATE INDEX IF NOT EXISTS idx_entities_mem ON entities(memory_id, name);

CREATE VIRTUAL TABLE IF NOT EXISTS facts_fts USING fts5(
    content, content_rowid = UNINDEXED, memory_id UNINDEXED
);
"""


_lock = threading.Lock()


def _db_path() -> Path:
    paths.ensure_dirs()
    return paths.openhost_home() / "memory.db"


def _connect() -> sqlite3.Connection:
    conn = sqlite3.connect(_db_path(), timeout=30, isolation_level=None)
    conn.execute("PRAGMA journal_mode=WAL")
    conn.execute("PRAGMA foreign_keys=ON")
    conn.executescript(_SCHEMA)
    return conn


def upsert_entity(memory_id: str, name: str, etype: Optional[str] = None) -> int:
    name = name.strip()
    with _lock, _connect() as conn:
        cur = conn.execute(
            "INSERT OR IGNORE INTO entities(memory_id, name, type, created_at) VALUES (?, ?, ?, ?)",
            (memory_id, name, etype, int(time.time())),
        )
        if cur.lastrowid:
            return cur.lastrowid
        row = conn.execute(
            "SELECT id FROM entities WHERE memory_id=? AND name=?", (memory_id, name)
        ).fetchone()
        return row[0]


def record_episode(memory_id: str, content: str, session_id: Optional[str] = None) -> int:
    with _lock, _connect() as conn:
        cur = conn.execute(
            "INSERT INTO episodes(memory_id, content, created_at, session_id) VALUES (?, ?, ?, ?)",
            (memory_id, content, int(time.time()), session_id),
        )
        return cur.lastrowid


def insert_fact(
    memory_id: str,
    subject_id: int,
    relation: str,
    object_id: Optional[int],
    value_text: Optional[str],
    confidence: float,
    source_episode_id: Optional[int],
) -> int:
    now = int(time.time())
    with _lock, _connect() as conn:
        # Temporal invalidation: close any currently-valid fact with the same
        # (subject, relation) — new observation supersedes old.
        conn.execute(
            "UPDATE facts SET valid_to=? "
            "WHERE memory_id=? AND subject_id=? AND relation=? AND valid_to IS NULL",
            (now, memory_id, subject_id, relation),
        )
        cur = conn.execute(
            "INSERT INTO facts(memory_id, subject_id, relation, object_id, value_text, "
            "valid_from, valid_to, confidence, source_episode_id) "
            "VALUES (?, ?, ?, ?, ?, ?, NULL, ?, ?)",
            (memory_id, subject_id, relation, object_id, value_text, now, confidence, source_episode_id),
        )
        fact_id = cur.lastrowid
        # Keep an FTS row for hybrid retrieval
        fts_content = _render_fact_for_fts(conn, memory_id, fact_id)
        conn.execute(
            "INSERT INTO facts_fts(rowid, content, memory_id) VALUES (?, ?, ?)",
            (fact_id, fts_content, memory_id),
        )
        return fact_id


def _render_fact_for_fts(conn: sqlite3.Connection, memory_id: str, fact_id: int) -> str:
    row = conn.execute(
        "SELECT e1.name, f.relation, e2.name, f.value_text "
        "FROM facts f "
        "JOIN entities e1 ON e1.id = f.subject_id "
        "LEFT JOIN entities e2 ON e2.id = f.object_id "
        "WHERE f.id=? AND f.memory_id=?",
        (fact_id, memory_id),
    ).fetchone()
    if not row:
        return ""
    subj, rel, obj, value = row
    obj_text = obj or value or ""
    return f"{subj} {rel} {obj_text}".strip()


def facts_about(
    memory_id: str,
    entity_name: Optional[str],
    at_time: Optional[int] = None,
    limit: int = 50,
) -> list[dict]:
    with _lock, _connect() as conn:
        params: list = [memory_id]
        sql = (
            "SELECT f.id, e1.name, f.relation, e2.name, f.value_text, "
            "f.valid_from, f.valid_to, f.confidence "
            "FROM facts f "
            "JOIN entities e1 ON e1.id = f.subject_id "
            "LEFT JOIN entities e2 ON e2.id = f.object_id "
            "WHERE f.memory_id=?"
        )
        if entity_name:
            sql += " AND (e1.name=? OR e2.name=?)"
            params.extend([entity_name, entity_name])
        if at_time is not None:
            sql += " AND f.valid_from <= ? AND (f.valid_to IS NULL OR f.valid_to > ?)"
            params.extend([at_time, at_time])
        else:
            sql += " AND f.valid_to IS NULL"
        sql += " ORDER BY f.valid_from DESC LIMIT ?"
        params.append(limit)
        rows = conn.execute(sql, params).fetchall()
    return [
        {
            "id": r[0],
            "subject": r[1],
            "relation": r[2],
            "object": r[3],
            "value_text": r[4],
            "valid_from": r[5],
            "valid_to": r[6],
            "confidence": r[7],
        }
        for r in rows
    ]


def search_facts_text(memory_id: str, query: str, limit: int = 20) -> list[dict]:
    """FTS5 text search over fact strings."""
    with _lock, _connect() as conn:
        rows = conn.execute(
            "SELECT f.id, e1.name, f.relation, e2.name, f.value_text, "
            "f.valid_from, f.valid_to, f.confidence "
            "FROM facts_fts "
            "JOIN facts f ON f.id = facts_fts.rowid "
            "JOIN entities e1 ON e1.id = f.subject_id "
            "LEFT JOIN entities e2 ON e2.id = f.object_id "
            "WHERE facts_fts MATCH ? AND f.memory_id=? AND f.valid_to IS NULL "
            "ORDER BY bm25(facts_fts) LIMIT ?",
            (query, memory_id, limit),
        ).fetchall()
    return [
        {
            "id": r[0],
            "subject": r[1],
            "relation": r[2],
            "object": r[3],
            "value_text": r[4],
            "valid_from": r[5],
            "valid_to": r[6],
            "confidence": r[7],
        }
        for r in rows
    ]


def neighbor_entity_names(memory_id: str, name: str) -> list[str]:
    """All entity names connected to the given entity via any fact."""
    with _lock, _connect() as conn:
        rows = conn.execute(
            "SELECT DISTINCT e2.name FROM facts f "
            "JOIN entities e1 ON e1.id = f.subject_id "
            "LEFT JOIN entities e2 ON e2.id = f.object_id "
            "WHERE f.memory_id=? AND e1.name=? AND e2.name IS NOT NULL",
            (memory_id, name),
        ).fetchall()
    return [r[0] for r in rows]
