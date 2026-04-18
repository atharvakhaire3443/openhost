"""SQLite storage for branching chat sessions."""
from __future__ import annotations

import sqlite3
import threading
import time
from pathlib import Path
from typing import Optional

from . import paths


_SCHEMA = """
CREATE TABLE IF NOT EXISTS sessions (
    id TEXT PRIMARY KEY,
    model_id TEXT NOT NULL,
    created_at INTEGER NOT NULL
);
CREATE TABLE IF NOT EXISTS turns (
    turn_id INTEGER PRIMARY KEY AUTOINCREMENT,
    session_id TEXT NOT NULL,
    parent_turn_id INTEGER,
    branch_name TEXT NOT NULL DEFAULT 'main',
    role TEXT NOT NULL,
    content TEXT NOT NULL,
    stats_json TEXT,
    created_at INTEGER NOT NULL,
    FOREIGN KEY (session_id) REFERENCES sessions(id),
    FOREIGN KEY (parent_turn_id) REFERENCES turns(turn_id)
);
CREATE INDEX IF NOT EXISTS idx_turns_session ON turns(session_id, branch_name, turn_id);
"""


_lock = threading.Lock()


def _db_path() -> Path:
    paths.ensure_dirs()
    return paths.openhost_home() / "sessions.db"


def _connect() -> sqlite3.Connection:
    conn = sqlite3.connect(_db_path(), timeout=30, isolation_level=None)
    conn.execute("PRAGMA journal_mode=WAL")
    conn.execute("PRAGMA foreign_keys=ON")
    conn.executescript(_SCHEMA)
    return conn


def ensure_session(session_id: str, model_id: str) -> None:
    with _lock, _connect() as conn:
        conn.execute(
            "INSERT OR IGNORE INTO sessions(id, model_id, created_at) VALUES (?, ?, ?)",
            (session_id, model_id, int(time.time())),
        )


def session_exists(session_id: str) -> bool:
    with _lock, _connect() as conn:
        row = conn.execute("SELECT 1 FROM sessions WHERE id=?", (session_id,)).fetchone()
        return row is not None


def get_model_id(session_id: str) -> Optional[str]:
    with _lock, _connect() as conn:
        row = conn.execute("SELECT model_id FROM sessions WHERE id=?", (session_id,)).fetchone()
        return row[0] if row else None


def head_turn_id(session_id: str, branch: str) -> Optional[int]:
    with _lock, _connect() as conn:
        row = conn.execute(
            "SELECT turn_id FROM turns WHERE session_id=? AND branch_name=? "
            "ORDER BY turn_id DESC LIMIT 1",
            (session_id, branch),
        ).fetchone()
        return row[0] if row else None


def append_turn(
    session_id: str,
    branch: str,
    role: str,
    content: str,
    parent_turn_id: Optional[int],
    stats_json: Optional[str] = None,
) -> int:
    with _lock, _connect() as conn:
        cur = conn.execute(
            "INSERT INTO turns(session_id, parent_turn_id, branch_name, role, content, "
            "stats_json, created_at) VALUES (?, ?, ?, ?, ?, ?, ?)",
            (session_id, parent_turn_id, branch, role, content, stats_json, int(time.time())),
        )
        return cur.lastrowid


def list_turns(session_id: str, branch: str) -> list[tuple[int, str, str, int]]:
    """Return turns on a branch as (turn_id, role, content, created_at)."""
    with _lock, _connect() as conn:
        rows = conn.execute(
            "SELECT turn_id, role, content, created_at FROM turns "
            "WHERE session_id=? AND branch_name=? ORDER BY turn_id",
            (session_id, branch),
        ).fetchall()
        return [(r[0], r[1], r[2], r[3]) for r in rows]


def list_branches(session_id: str) -> list[tuple[str, int]]:
    """Return (branch_name, head_turn_id) for every branch with at least one turn."""
    with _lock, _connect() as conn:
        rows = conn.execute(
            "SELECT branch_name, MAX(turn_id) FROM turns WHERE session_id=? GROUP BY branch_name "
            "ORDER BY branch_name",
            (session_id,),
        ).fetchall()
        return [(r[0], r[1]) for r in rows]


def delete_session(session_id: str) -> None:
    with _lock, _connect() as conn:
        conn.execute("DELETE FROM turns WHERE session_id=?", (session_id,))
        conn.execute("DELETE FROM sessions WHERE id=?", (session_id,))
