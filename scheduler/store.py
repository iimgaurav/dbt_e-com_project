"""SQLite run history for the local scheduler.

One row per dbt invocation. Kept deliberately small so the dashboard can read
it on every poll without touching dbt's own artefacts.
"""

from __future__ import annotations

import sqlite3
from contextlib import contextmanager
from datetime import datetime, timezone
from typing import Any, Iterator

try:  # package import: python -m scheduler.app
    from .config import DB_PATH, ensure_dirs
except ImportError:  # script import: python scheduler/app.py
    from config import DB_PATH, ensure_dirs

SCHEMA = """
CREATE TABLE IF NOT EXISTS runs (
    id          INTEGER PRIMARY KEY AUTOINCREMENT,
    trigger     TEXT NOT NULL,
    target      TEXT NOT NULL,
    status      TEXT NOT NULL,
    started_at  TEXT NOT NULL,
    finished_at TEXT,
    duration_s  REAL,
    exit_code   INTEGER,
    warnings    INTEGER NOT NULL DEFAULT 0,
    errors      INTEGER NOT NULL DEFAULT 0,
    command     TEXT NOT NULL DEFAULT '',
    log_path    TEXT NOT NULL DEFAULT '',
    summary     TEXT NOT NULL DEFAULT '',
    error       TEXT NOT NULL DEFAULT ''
);
CREATE INDEX IF NOT EXISTS idx_runs_started_at ON runs (started_at DESC);
"""


def _now() -> str:
    return datetime.now(timezone.utc).isoformat(timespec="seconds")


def _connect() -> sqlite3.Connection:
    ensure_dirs()
    conn = sqlite3.connect(DB_PATH, timeout=30)
    conn.row_factory = sqlite3.Row
    conn.execute("PRAGMA journal_mode=WAL")
    conn.execute("PRAGMA busy_timeout=5000")
    return conn


@contextmanager
def _db() -> Iterator[sqlite3.Connection]:
    conn = _connect()
    try:
        yield conn
        conn.commit()
    except Exception:
        conn.rollback()
        raise
    finally:
        conn.close()


def init_db() -> None:
    with _db() as conn:
        conn.executescript(SCHEMA)


def mark_stale_runs() -> int:
    """Close out runs left in 'running' state by a previous process."""
    with _db() as conn:
        cur = conn.execute(
            """
            UPDATE runs
               SET status = 'interrupted',
                   finished_at = ?,
                   error = CASE WHEN error = '' THEN ? ELSE error END
             WHERE status = 'running'
            """,
            (_now(), "Scheduler stopped while this run was in progress."),
        )
        return cur.rowcount


def create_run(trigger: str, target: str) -> int:
    with _db() as conn:
        cur = conn.execute(
            "INSERT INTO runs (trigger, target, status, started_at) VALUES (?, ?, 'running', ?)",
            (trigger, target, _now()),
        )
        return int(cur.lastrowid)


def set_run_details(run_id: int, command: str, log_path: str) -> None:
    with _db() as conn:
        conn.execute(
            "UPDATE runs SET command = ?, log_path = ? WHERE id = ?",
            (command, log_path, run_id),
        )


def finish_run(
    run_id: int,
    status: str,
    *,
    exit_code: int | None,
    duration_s: float,
    summary: str = "",
    error: str = "",
    warnings: int = 0,
    errors: int = 0,
) -> None:
    with _db() as conn:
        conn.execute(
            """
            UPDATE runs
               SET status = ?, finished_at = ?, duration_s = ?, exit_code = ?,
                   summary = ?, error = ?, warnings = ?, errors = ?
             WHERE id = ?
            """,
            (
                status,
                _now(),
                round(duration_s, 1),
                exit_code,
                summary,
                error,
                warnings,
                errors,
                run_id,
            ),
        )


def _row_to_dict(row: sqlite3.Row) -> dict[str, Any]:
    return dict(row)


def get_run(run_id: int) -> dict[str, Any] | None:
    with _db() as conn:
        row = conn.execute("SELECT * FROM runs WHERE id = ?", (run_id,)).fetchone()
    return _row_to_dict(row) if row else None


def list_runs(limit: int = 25) -> list[dict[str, Any]]:
    limit = max(1, min(int(limit), 200))
    with _db() as conn:
        rows = conn.execute(
            "SELECT * FROM runs ORDER BY id DESC LIMIT ?", (limit,)
        ).fetchall()
    return [_row_to_dict(row) for row in rows]


def latest_run() -> dict[str, Any] | None:
    with _db() as conn:
        row = conn.execute("SELECT * FROM runs ORDER BY id DESC LIMIT 1").fetchone()
    return _row_to_dict(row) if row else None
