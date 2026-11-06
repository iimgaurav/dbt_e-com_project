"""Persistent configuration for the local dbt scheduler.

Runtime state lives under ``logs/scheduler`` (already git-ignored) so the app
never writes into the dbt project itself. The token is never persisted here.
"""

from __future__ import annotations

import json
import os
from datetime import tzinfo
from pathlib import Path
from typing import Any
from zoneinfo import ZoneInfo, ZoneInfoNotFoundError

PROJECT_ROOT = Path(__file__).resolve().parent.parent
# Keep runtime state out of dbt's logs/ directory: `dbt clean` deletes that.
SCHEDULER_DIR = Path(
    os.environ.get("SCHEDULER_HOME", PROJECT_ROOT / "scheduler" / "runtime")
)
RUNS_DIR = SCHEDULER_DIR / "runs"
CONFIG_PATH = SCHEDULER_DIR / "config.json"
DB_PATH = SCHEDULER_DIR / "scheduler.db"

DEFAULT_CONFIG: dict[str, Any] = {
    "schedule_time": "02:30",
    "target": "dev",
    "enabled": True,
    "select": "",
    "full_refresh": False,
    "timezone": "",
}

VALID_TARGETS = ("dev", "prod")

# Prod is locked by default. Set SCHEDULER_ALLOW_PROD=1 in the environment and
# restart the scheduler to permit prod runs; nothing else unlocks it.
PROD_ENV_FLAG = "SCHEDULER_ALLOW_PROD"
TRUTHY = {"1", "true", "yes", "on"}


class ProdLockedError(ValueError):
    """Raised when a prod target is requested while prod is locked."""


def prod_allowed() -> bool:
    """Return True only when the operator explicitly unlocks prod."""
    return (os.environ.get(PROD_ENV_FLAG) or "").strip().lower() in TRUTHY


def ensure_target_allowed(target: str) -> None:
    """Reject prod unless the environment flag has unlocked it."""
    if target == "prod" and not prod_allowed():
        raise ProdLockedError(
            "Target 'prod' is locked. Set SCHEDULER_ALLOW_PROD=1 and restart the "
            "scheduler to enable production runs."
        )


def ensure_dirs() -> None:
    """Create the runtime directories if they do not exist."""
    RUNS_DIR.mkdir(parents=True, exist_ok=True)


def _coerce(raw: dict[str, Any]) -> dict[str, Any]:
    cfg = dict(DEFAULT_CONFIG)
    if not isinstance(raw, dict):
        return cfg

    value = raw.get("schedule_time")
    if isinstance(value, str):
        try:
            parse_time(value)
            cfg["schedule_time"] = value.strip()
        except ValueError:
            pass

    value = raw.get("target")
    if value in VALID_TARGETS:
        cfg["target"] = value

    # Hard guard: a stale config on disk can never route a run to prod.
    if cfg["target"] == "prod" and not prod_allowed():
        cfg["target"] = "dev"

    if isinstance(raw.get("enabled"), bool):
        cfg["enabled"] = raw["enabled"]

    value = raw.get("select")
    if isinstance(value, str):
        cfg["select"] = value.strip()[:200]

    if isinstance(raw.get("full_refresh"), bool):
        cfg["full_refresh"] = raw["full_refresh"]

    value = raw.get("timezone")
    if isinstance(value, str):
        candidate = value.strip()
        if not candidate:
            cfg["timezone"] = ""
        else:
            try:
                ZoneInfo(candidate)
                cfg["timezone"] = candidate
            except (ZoneInfoNotFoundError, ValueError):
                pass

    return cfg


def load_config() -> dict[str, Any]:
    """Read config.json, falling back to defaults for missing/invalid values."""
    ensure_dirs()
    try:
        raw = json.loads(CONFIG_PATH.read_text(encoding="utf-8-sig"))
    except (FileNotFoundError, json.JSONDecodeError, OSError):
        return dict(DEFAULT_CONFIG)
    return _coerce(raw)


def save_config(cfg: dict[str, Any]) -> dict[str, Any]:
    """Validate, persist, and return the effective configuration."""
    ensure_dirs()
    clean = _coerce(cfg)
    tmp = CONFIG_PATH.with_suffix(".json.tmp")
    tmp.write_text(json.dumps(clean, indent=2) + "\n", encoding="utf-8")
    tmp.replace(CONFIG_PATH)
    return clean


def parse_time(value: str) -> tuple[int, int]:
    """Parse ``HH:MM`` (24-hour) into ``(hour, minute)``."""
    text = (value or "").strip()
    parts = text.split(":")
    if len(parts) != 2:
        raise ValueError("Time must use HH:MM (24-hour) format.")
    try:
        hour, minute = int(parts[0]), int(parts[1])
    except ValueError as exc:
        raise ValueError("Time must use HH:MM (24-hour) format.") from exc
    if not (0 <= hour <= 23 and 0 <= minute <= 59):
        raise ValueError("Time must be between 00:00 and 23:59.")
    return hour, minute


def resolve_timezone(name: str) -> tzinfo | None:
    """Return a tzinfo for an IANA name, or None to use the system local zone."""
    if not name:
        return None
    try:
        return ZoneInfo(name)
    except (ZoneInfoNotFoundError, ValueError) as exc:
        raise ValueError(f"Unknown timezone: {name}") from exc


def target_catalog(target: str) -> str:
    """Map a dbt target to its Unity Catalog catalog name."""
    if target == "prod":
        return os.environ.get("DBT_PROD_CATALOG", "dbt_prod")
    return os.environ.get("DBT_DEV_CATALOG", "dbt")
