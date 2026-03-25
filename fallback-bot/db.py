import sqlite3
from typing import Optional, List

from config import DATA_DIR, MAX_HISTORY

DB_PATH = DATA_DIR / "history.db"

_conn = None  # type: Optional[sqlite3.Connection]


def init_db():
    # type: () -> None
    global _conn
    DATA_DIR.mkdir(parents=True, exist_ok=True)
    _conn = sqlite3.connect(str(DB_PATH))
    _conn.execute("PRAGMA journal_mode=WAL")
    _conn.row_factory = sqlite3.Row
    _conn.executescript("""
        CREATE TABLE IF NOT EXISTS messages (
            id INTEGER PRIMARY KEY AUTOINCREMENT,
            chat_id INTEGER NOT NULL,
            role TEXT NOT NULL CHECK (role IN ('user', 'assistant')),
            content TEXT NOT NULL,
            created_at TEXT DEFAULT (datetime('now', 'localtime'))
        );
        CREATE INDEX IF NOT EXISTS idx_messages_chat_id
            ON messages (chat_id, created_at DESC);
    """)


def _get_conn():
    # type: () -> sqlite3.Connection
    if _conn is None:
        raise RuntimeError("Database not initialized. Call init_db() first.")
    return _conn


def save_message(chat_id, role, content):
    # type: (int, str, str) -> None
    conn = _get_conn()
    conn.execute(
        "INSERT INTO messages (chat_id, role, content) VALUES (?, ?, ?)",
        (chat_id, role, content),
    )
    conn.commit()


def get_history(chat_id, limit=None):
    # type: (int, Optional[int]) -> str
    if limit is None:
        limit = MAX_HISTORY
    conn = _get_conn()
    rows = conn.execute(
        "SELECT role, content FROM messages "
        "WHERE chat_id = ? "
        "ORDER BY id DESC LIMIT ?",
        (chat_id, limit),
    ).fetchall()
    rows = list(reversed(rows))
    lines = []
    for row in rows:
        prefix = "User" if row["role"] == "user" else "Assistant"
        lines.append("{}: {}".format(prefix, row["content"]))
    return "\n".join(lines)
