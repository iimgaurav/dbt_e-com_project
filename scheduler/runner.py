"""dbt process runner, credential loading, and preflight checks.

Everything here is standard library only so the scheduler can still explain
what is wrong even if a third-party package fails to import.
"""

from __future__ import annotations

import configparser
import json
import os
import re
import shutil
import subprocess
import threading
import time
from collections import deque
from datetime import datetime, timezone
from pathlib import Path
from typing import Any
from urllib.error import HTTPError, URLError
from urllib.parse import quote
from urllib.request import Request, urlopen

try:  # package import: python -m scheduler.app
    from . import config as cfgmod
except ImportError:  # script import: python scheduler/app.py
    import config as cfgmod

ANSI_RE = re.compile(r"\x1b\[[0-9;]*m")
SUMMARY_RE = re.compile(r"^\s*Summary:\s*(.+?)\s*$")
PROCESSED_RE = re.compile(r"^\s*Processed:\s*(.+?)\s*$")
WARN_PATTERNS = (
    re.compile(r"\bwarn=(\d+)\b", re.IGNORECASE),
    re.compile(r"\|\s*(\d+)\s+warn\b", re.IGNORECASE),
    re.compile(r"with\s+(\d+)\s+warnings?\b", re.IGNORECASE),
)
ERROR_PATTERNS = (
    re.compile(r"\berror=(\d+)\b", re.IGNORECASE),
    re.compile(r"\|\s*(\d+)\s+errors?\b", re.IGNORECASE),
    re.compile(r"with\s+(\d+)\s+errors?\b", re.IGNORECASE),
)

_ACTIVE_LOCK = threading.Lock()
_ACTIVE_PROC: subprocess.Popen[str] | None = None

_CATALOG_CACHE: dict[tuple[str, str], tuple[float, dict[str, Any]]] = {}
_CATALOG_LOCK = threading.Lock()
_CATALOG_TTL = 60.0


# ---------------------------------------------------------------------------
# Credentials
# ---------------------------------------------------------------------------


def databricks_config_path() -> Path:
    override = os.environ.get("DATABRICKS_CONFIG_FILE")
    return Path(override) if override else Path.home() / ".databrickscfg"


def _read_databrickscfg() -> tuple[dict[str, str], Path]:
    """Return the selected CLI profile as a lower-cased dict, plus its path."""
    path = databricks_config_path()
    data: dict[str, str] = {}
    if not path.exists():
        return data, path

    parser = configparser.ConfigParser(interpolation=None)
    try:
        parser.read(path, encoding="utf-8-sig")
    except (configparser.Error, OSError):
        return data, path

    profile = os.environ.get("DATABRICKS_CONFIG_PROFILE", "DEFAULT")
    if profile.upper() == "DEFAULT":
        data.update({k.lower(): v for k, v in parser.defaults().items()})

    for section in parser.sections():
        if section.lower() == profile.lower():
            data.update({k.lower(): v for k, v in parser.items(section)})

    if not data and parser.defaults():
        data.update({k.lower(): v for k, v in parser.defaults().items()})

    return data, path


def load_credentials() -> dict[str, str]:
    """Resolve token/host, preferring the environment over ~/.databrickscfg."""
    cfg_data, path = _read_databrickscfg()

    token = (os.environ.get("DATABRICKS_TOKEN") or "").strip().strip('"').strip("'")
    source = "DATABRICKS_TOKEN environment variable"
    if not token:
        token = (cfg_data.get("token") or "").strip().strip('"').strip("'")
        source = f"profile in {path}" if token else f"missing (checked {path})"

    host = (os.environ.get("DATABRICKS_HOST") or cfg_data.get("host") or "").strip()
    host = host.strip('"').strip("'").rstrip("/")
    if host and not host.startswith(("http://", "https://")):
        host = "https://" + host

    return {"token": token, "host": host, "source": source, "path": str(path)}


# ---------------------------------------------------------------------------
# Executable discovery
# ---------------------------------------------------------------------------


def find_dbt() -> str | None:
    candidates: list[str | None] = []
    override = os.environ.get("DBT_EXE")
    if override:
        candidates.append(override)
    candidates.append(shutil.which("dbt"))

    local_bin = Path.home() / ".local" / "bin"
    candidates.extend([str(local_bin / "dbt.exe"), str(local_bin / "dbt")])

    for candidate in candidates:
        if candidate and Path(candidate).is_file():
            return str(Path(candidate))
    return None


# ---------------------------------------------------------------------------
# Preflight
# ---------------------------------------------------------------------------


def _check_catalog(catalog: str, token: str, host: str, force: bool) -> dict[str, Any]:
    """Check a Unity Catalog catalog via the REST API (cached for 60s)."""
    if not token:
        return {"state": "unknown", "detail": "No token available to verify the catalog."}
    if not host:
        return {
            "state": "unknown",
            "detail": "No workspace host configured; set DATABRICKS_HOST or add host to ~/.databrickscfg.",
        }

    key = (host.rstrip("/"), catalog)
    now = time.monotonic()
    with _CATALOG_LOCK:
        cached = _CATALOG_CACHE.get(key)
        if cached and not force and now - cached[0] < _CATALOG_TTL:
            return cached[1]

    url = f"{host.rstrip('/')}/api/2.1/unity-catalog/catalogs/{quote(catalog, safe='')}"
    request = Request(
        url,
        headers={"Authorization": f"Bearer {token}", "Accept": "application/json"},
    )

    try:
        with urlopen(request, timeout=10) as response:
            body = response.read().decode("utf-8", errors="replace")
            name = catalog
            try:
                name = json.loads(body).get("name", catalog)
            except (json.JSONDecodeError, AttributeError):
                pass
            result = {"state": "exists", "detail": f"Catalog '{name}' is reachable."}
    except HTTPError as exc:
        if exc.code == 404:
            result = {
                "state": "missing",
                "detail": (
                    f"Catalog '{catalog}' does not exist. Create it in the Databricks UI "
                    f"(Catalog > Create catalog) or run: CREATE CATALOG {catalog};"
                ),
            }
        elif exc.code in (401, 403):
            result = {
                "state": "unauthorized",
                "detail": f"Token was rejected (HTTP {exc.code}); it may be expired or lack access.",
            }
        else:
            result = {
                "state": "unknown",
                "detail": f"Could not verify the catalog (HTTP {exc.code}).",
            }
    except (URLError, TimeoutError, OSError) as exc:
        result = {
            "state": "unknown",
            "detail": f"Could not reach the workspace to verify the catalog: {exc}",
        }

    with _CATALOG_LOCK:
        _CATALOG_CACHE[key] = (now, result)
    return result


def clear_preflight_cache() -> None:
    with _CATALOG_LOCK:
        _CATALOG_CACHE.clear()


def preflight(target: str, force: bool = False) -> dict[str, Any]:
    """Build the checklist shown in the dashboard."""
    target = target if target in cfgmod.VALID_TARGETS else "prod"
    catalog = cfgmod.target_catalog(target)
    creds = load_credentials()
    dbt_path = find_dbt()
    profiles = cfgmod.PROJECT_ROOT / "profiles.yml"

    checks: list[dict[str, str]] = []

    checks.append(
        {
            "name": "dbt executable",
            "status": "ok" if dbt_path else "error",
            "detail": dbt_path or "dbt was not found on PATH or in ~/.local/bin.",
        }
    )

    checks.append(
        {
            "name": "Databricks token",
            "status": "ok" if creds["token"] else "error",
            "detail": creds["source"],
        }
    )

    checks.append(
        {
            "name": "profiles.yml",
            "status": "ok" if profiles.is_file() else "error",
            "detail": str(profiles) if profiles.is_file() else f"Missing {profiles}",
        }
    )

    catalog_result = _check_catalog(catalog, creds["token"], creds["host"], force)
    state_to_status = {
        "exists": "ok",
        "missing": "error",
        "unauthorized": "error",
        "unknown": "warn",
    }
    checks.append(
        {
            "name": f"Catalog '{catalog}'",
            "status": state_to_status.get(catalog_result["state"], "warn"),
            "detail": catalog_result["detail"],
        }
    )

    return {
        "ok": all(check["status"] != "error" for check in checks),
        "target": target,
        "catalog": catalog,
        "host": creds["host"],
        "checks": checks,
        "checked_at": datetime.now(timezone.utc).isoformat(timespec="seconds"),
    }


# ---------------------------------------------------------------------------
# Build execution
# ---------------------------------------------------------------------------


def build_command(cfg: dict[str, Any], dbt_path: str) -> list[str]:
    command = [
        dbt_path,
        "build",
        "--profiles-dir",
        str(cfgmod.PROJECT_ROOT),
        "--target",
        cfg["target"],
    ]
    select = (cfg.get("select") or "").strip()
    if select:
        command.extend(["--select", select])
    if cfg.get("full_refresh"):
        command.append("--full-refresh")
    return command


def command_display(command: list[str]) -> str:
    if os.name == "nt":
        return subprocess.list2cmdline(command)
    return " ".join(shlex_quote(part) for part in command)


def shlex_quote(value: str) -> str:
    if not value:
        return "''"
    if re.fullmatch(r"[A-Za-z0-9_@%+=:,./\\-]+", value):
        return value
    return "'" + value.replace("'", "'\\''") + "'"


def _parse_counts(line: str) -> tuple[int | None, int | None]:
    warnings = errors = None
    for pattern in WARN_PATTERNS:
        match = pattern.search(line)
        if match:
            warnings = int(match.group(1))
            break
    for pattern in ERROR_PATTERNS:
        match = pattern.search(line)
        if match:
            errors = int(match.group(1))
            break
    return warnings, errors


def run_build(
    cfg: dict[str, Any],
    dbt_path: str,
    token: str,
    log_path: Path,
    run_id: int,
    trigger: str,
) -> dict[str, Any]:
    """Run ``dbt build`` synchronously, streaming output to the run log."""
    command = build_command(cfg, dbt_path)
    display = command_display(command)
    log_path.parent.mkdir(parents=True, exist_ok=True)

    warnings = 0
    errors = 0
    summary = ""
    processed = ""
    exit_code: int | None = None
    recent: deque[str] = deque(maxlen=30)
    started = datetime.now(timezone.utc)

    env = os.environ.copy()
    env["DATABRICKS_TOKEN"] = token
    env["DBT_TARGET"] = cfg["target"]
    env["NO_COLOR"] = "1"
    env["PYTHONUNBUFFERED"] = "1"

    creationflags = getattr(subprocess, "CREATE_NO_WINDOW", 0)

    with log_path.open("w", encoding="utf-8", newline="\n") as log:
        log.write("=== sales_analytics scheduler ===\n")
        log.write(f"run_id    : {run_id}\n")
        log.write(f"trigger   : {trigger}\n")
        log.write(f"target    : {cfg['target']}\n")
        log.write(f"started   : {started.isoformat(timespec='seconds')}\n")
        log.write(f"command   : {display}\n")
        log.write("=" * 34 + "\n\n")
        log.flush()

        try:
            proc = subprocess.Popen(
                command,
                cwd=str(cfgmod.PROJECT_ROOT),
                env=env,
                stdout=subprocess.PIPE,
                stderr=subprocess.STDOUT,
                text=True,
                encoding="utf-8",
                errors="replace",
                bufsize=1,
                creationflags=creationflags,
            )
        except OSError as exc:
            message = f"Could not start dbt: {exc}"
            log.write(f"ERROR: {message}\n")
            return {
                "exit_code": None,
                "summary": "",
                "warnings": 0,
                "errors": 1,
                "error": message,
            }

        with _ACTIVE_LOCK:
            global _ACTIVE_PROC
            _ACTIVE_PROC = proc

        try:
            assert proc.stdout is not None
            for raw in iter(proc.stdout.readline, ""):
                line = ANSI_RE.sub("", raw.rstrip("\r\n"))
                log.write(line + "\n")
                log.flush()
                if line.strip():
                    recent.append(line)

                match = SUMMARY_RE.match(line)
                if match:
                    summary = match.group(1)
                match = PROCESSED_RE.match(line)
                if match:
                    processed = match.group(1)

                line_warnings, line_errors = _parse_counts(line)
                if line_warnings is not None:
                    warnings = line_warnings
                if line_errors is not None:
                    errors = line_errors

            exit_code = proc.wait()
        finally:
            with _ACTIVE_LOCK:
                _ACTIVE_PROC = None

        duration = (datetime.now(timezone.utc) - started).total_seconds()
        log.write(
            f"\n=== finished: exit={exit_code} duration={duration:.1f}s "
            f"warnings={warnings} errors={errors} ===\n"
        )
        log.flush()

    error = ""
    if exit_code != 0:
        tail = [line for line in recent if line.strip()][-15:]
        error = "\n".join(tail) or f"dbt exited with code {exit_code}."

    final_summary = summary
    if processed:
        final_summary = f"{processed} | {summary}" if summary else processed

    return {
        "exit_code": exit_code,
        "summary": final_summary,
        "warnings": warnings,
        "errors": errors if exit_code == 0 else max(errors, 1),
        "error": error,
    }


def terminate_active() -> None:
    """Best-effort cleanup of a child process when the app shuts down."""
    with _ACTIVE_LOCK:
        proc = _ACTIVE_PROC
    if proc and proc.poll() is None:
        try:
            proc.terminate()
        except OSError:
            pass


# ---------------------------------------------------------------------------
# Log helpers
# ---------------------------------------------------------------------------


def read_log_tail(path: Path, lines: int = 400) -> str:
    if not path or not path.is_file():
        return ""
    lines = max(1, min(int(lines), 5000))
    try:
        with path.open("rb") as handle:
            handle.seek(0, os.SEEK_END)
            size = handle.tell()
            block = min(size, 256 * 1024)
            handle.seek(size - block)
            data = handle.read()
    except OSError as exc:
        return f"Could not read log: {exc}"
    text = data.decode("utf-8", errors="replace")
    return "\n".join(text.splitlines()[-lines:])
