"""Local web scheduler for the sales_analytics dbt project.

Run with:  python scheduler/app.py
The dashboard binds to 127.0.0.1 only and is intended for a single local user.
"""

from __future__ import annotations

import argparse
import atexit
import logging
import os
import threading
import time
import webbrowser
from datetime import datetime, timezone
from logging.handlers import RotatingFileHandler
from pathlib import Path
from typing import Any

from apscheduler.schedulers.background import BackgroundScheduler
from apscheduler.triggers.cron import CronTrigger
from flask import Flask, jsonify, render_template, request

try:  # package import: python -m scheduler.app
    from . import config as cfgmod
    from . import runner, store
except ImportError:  # script import: python scheduler/app.py
    import config as cfgmod
    import runner
    import store

APP_NAME = "sales_analytics scheduler"
JOB_ID = "daily_dbt_build"

app = Flask(__name__)
app.config["SEND_FILE_MAX_AGE_DEFAULT"] = 0
app.json.sort_keys = False

scheduler = BackgroundScheduler(daemon=True)
run_gate = threading.Lock()
log = logging.getLogger("scheduler")


# ---------------------------------------------------------------------------
# Scheduling
# ---------------------------------------------------------------------------


def build_trigger(cfg: dict[str, Any]) -> CronTrigger:
    hour, minute = cfgmod.parse_time(cfg["schedule_time"])
    tz = cfgmod.resolve_timezone(cfg["timezone"])
    return CronTrigger(hour=hour, minute=minute, timezone=tz)


def configure_job() -> None:
    """Create or reschedule the daily job, honouring the enabled flag."""
    cfg = cfgmod.load_config()
    trigger = build_trigger(cfg)
    job = scheduler.get_job(JOB_ID)

    if cfg["enabled"]:
        if job:
            scheduler.reschedule_job(JOB_ID, trigger=trigger)
        else:
            scheduler.add_job(
                scheduled_run,
                trigger=trigger,
                id=JOB_ID,
                name="Daily dbt build",
                replace_existing=True,
                max_instances=1,
                coalesce=True,
                misfire_grace_time=3600,
            )
        scheduler.resume_job(JOB_ID)
    else:
        if job:
            # next_run_time=None pauses the job without a reschedule/pause race.
            scheduler.modify_job(JOB_ID, trigger=trigger, next_run_time=None)
        else:
            scheduler.add_job(
                scheduled_run,
                trigger=trigger,
                id=JOB_ID,
                name="Daily dbt build",
                replace_existing=True,
                max_instances=1,
                coalesce=True,
                misfire_grace_time=3600,
                next_run_time=None,
            )


def scheduled_run() -> None:
    run_id, error = start_run("schedule")
    if run_id is None:
        log.warning("Scheduled run skipped: %s", error)
    else:
        log.info("Scheduled run %s started", run_id)


# ---------------------------------------------------------------------------
# Run lifecycle
# ---------------------------------------------------------------------------


def _validated_overrides(payload: dict[str, Any]) -> dict[str, Any]:
    overrides: dict[str, Any] = {}

    if "target" in payload:
        target = payload["target"]
        if target not in cfgmod.VALID_TARGETS:
            raise ValueError("target must be 'dev' or 'prod'.")
        cfgmod.ensure_target_allowed(target)
        overrides["target"] = target

    if "select" in payload:
        select = payload["select"]
        if not isinstance(select, str):
            raise ValueError("select must be a string.")
        if len(select) > 200:
            raise ValueError("select must be 200 characters or fewer.")
        overrides["select"] = select.strip()

    if "full_refresh" in payload:
        full_refresh = payload["full_refresh"]
        if not isinstance(full_refresh, bool):
            raise ValueError("full_refresh must be true or false.")
        overrides["full_refresh"] = full_refresh

    return overrides


def start_run(trigger: str, overrides: dict[str, Any] | None = None) -> tuple[int | None, str | None]:
    """Start a build in the background. Returns (run_id, error)."""
    if not run_gate.acquire(blocking=False):
        return None, "A dbt run is already in progress."

    run_id: int | None = None
    try:
        cfg = cfgmod.load_config()
        if overrides:
            requested_target = overrides.get("target")
            if requested_target:
                cfgmod.ensure_target_allowed(requested_target)
            merged = {**cfg, **overrides}
            cfg = cfgmod._coerce(merged)
        cfgmod.ensure_target_allowed(cfg["target"])

        dbt_path = runner.find_dbt()
        if not dbt_path:
            raise RuntimeError(
                "dbt was not found. Install dbt Fusion or set the DBT_EXE environment variable."
            )

        creds = runner.load_credentials()
        if not creds["token"]:
            raise RuntimeError(
                "No Databricks token found. Set DATABRICKS_TOKEN or add a token to "
                f"{creds['path']}."
            )

        run_id = store.create_run(trigger, cfg["target"])
        stamp = datetime.now().strftime("%Y%m%d-%H%M%S")
        log_path = cfgmod.RUNS_DIR / f"{stamp}-run{run_id}.log"
        command = runner.build_command(cfg, dbt_path)
        store.set_run_details(run_id, runner.command_display(command), str(log_path))

        thread = threading.Thread(
            target=_execute_run,
            args=(run_id, cfg, dbt_path, creds["token"], log_path, trigger),
            name=f"dbt-run-{run_id}",
            daemon=True,
        )
        thread.start()
        log.info(
            "Run %s started (trigger=%s target=%s select=%r full_refresh=%s)",
            run_id,
            trigger,
            cfg["target"],
            cfg["select"],
            cfg["full_refresh"],
        )
        return run_id, None
    except Exception as exc:  # noqa: BLE001 - surfaced to the UI
        if run_id is not None:
            store.finish_run(
                run_id,
                "failed",
                exit_code=None,
                duration_s=0,
                error=str(exc),
            )
        run_gate.release()
        log.exception("Could not start run")
        return None, str(exc)


def _execute_run(
    run_id: int,
    cfg: dict[str, Any],
    dbt_path: str,
    token: str,
    log_path: Path,
    trigger: str,
) -> None:
    started = time.monotonic()
    try:
        result = runner.run_build(cfg, dbt_path, token, log_path, run_id, trigger)
        status = "success" if result["exit_code"] == 0 else "failed"
        store.finish_run(
            run_id,
            status,
            exit_code=result["exit_code"],
            duration_s=time.monotonic() - started,
            summary=result["summary"],
            error=result["error"],
            warnings=result["warnings"],
            errors=result["errors"],
        )
        log.info(
            "Run %s finished status=%s exit=%s duration=%.1fs warnings=%s errors=%s",
            run_id,
            status,
            result["exit_code"],
            time.monotonic() - started,
            result["warnings"],
            result["errors"],
        )
    except Exception as exc:  # noqa: BLE001 - persisted for the dashboard
        store.finish_run(
            run_id,
            "failed",
            exit_code=None,
            duration_s=time.monotonic() - started,
            error=f"Scheduler error: {exc}",
        )
        log.exception("Run %s crashed", run_id)
    finally:
        run_gate.release()


# ---------------------------------------------------------------------------
# Status payload
# ---------------------------------------------------------------------------


def status_payload() -> dict[str, Any]:
    cfg = cfgmod.load_config()
    job = scheduler.get_job(JOB_ID)
    next_run = None
    if job and job.next_run_time:
        next_run = job.next_run_time.isoformat()

    return {
        "now": datetime.now(timezone.utc).isoformat(timespec="seconds"),
        "scheduler": {
            "started": scheduler.running,
            "enabled": cfg["enabled"],
            "paused": bool(job and job.next_run_time is None),
            "next_run": next_run,
            "timezone": str(scheduler.timezone),
            "active_run": run_gate.locked(),
            "job_id": JOB_ID,
        },
        "config": cfg,
        "guards": {
            "prod_locked": not cfgmod.prod_allowed(),
            "prod_flag": cfgmod.PROD_ENV_FLAG,
        },
        "preflight": runner.preflight(cfg["target"]),
        "latest_run": store.latest_run(),
    }


# ---------------------------------------------------------------------------
# Routes
# ---------------------------------------------------------------------------


@app.get("/")
def index() -> str:
    return render_template("index.html", app_name=APP_NAME)


@app.get("/api/health")
def health() -> Any:
    return jsonify({"ok": True, "scheduler_running": scheduler.running})


@app.get("/api/status")
def api_status() -> Any:
    return jsonify(status_payload())


@app.get("/api/runs")
def api_runs() -> Any:
    limit = request.args.get("limit", default=25, type=int)
    return jsonify({"runs": store.list_runs(limit or 25)})


@app.get("/api/runs/<int:run_id>")
def api_run(run_id: int) -> Any:
    run = store.get_run(run_id)
    if not run:
        return jsonify({"error": "Run not found."}), 404
    return jsonify({"run": run})


def _safe_log_path(run: dict[str, Any]) -> Path | None:
    raw = run.get("log_path") or ""
    if not raw:
        return None
    try:
        path = Path(raw).resolve()
    except OSError:
        return None
    if not path.is_relative_to(cfgmod.RUNS_DIR.resolve()):
        return None
    return path


@app.get("/api/runs/<int:run_id>/log")
def api_run_log(run_id: int) -> Any:
    run = store.get_run(run_id)
    if not run:
        return jsonify({"error": "Run not found."}), 404

    path = _safe_log_path(run)
    if path is None:
        return jsonify({"error": "This run has no readable log file."}), 404

    tail = request.args.get("tail", default=500, type=int) or 500
    return jsonify({"run": run, "log": runner.read_log_tail(path, tail)})


@app.post("/api/run")
def api_run_now() -> Any:
    payload = request.get_json(silent=True) or {}
    try:
        overrides = _validated_overrides(payload)
    except ValueError as exc:
        return jsonify({"error": str(exc)}), 400

    run_id, error = start_run("manual", overrides)
    if run_id is None:
        return jsonify({"error": error}), 409
    return jsonify({"run_id": run_id}), 202


@app.post("/api/config")
def api_config() -> Any:
    payload = request.get_json(silent=True) or {}
    if not isinstance(payload, dict):
        return jsonify({"error": "Expected a JSON object."}), 400

    current = cfgmod.load_config()
    updated = dict(current)

    if "schedule_time" in payload:
        try:
            cfgmod.parse_time(str(payload["schedule_time"]))
        except ValueError as exc:
            return jsonify({"error": str(exc)}), 400
        updated["schedule_time"] = str(payload["schedule_time"]).strip()

    if "target" in payload:
        if payload["target"] not in cfgmod.VALID_TARGETS:
            return jsonify({"error": "target must be 'dev' or 'prod'."}), 400
        try:
            cfgmod.ensure_target_allowed(payload["target"])
        except ValueError as exc:
            return jsonify({"error": str(exc)}), 403
        updated["target"] = payload["target"]

    if "enabled" in payload:
        if not isinstance(payload["enabled"], bool):
            return jsonify({"error": "enabled must be true or false."}), 400
        updated["enabled"] = payload["enabled"]

    if "select" in payload:
        if not isinstance(payload["select"], str):
            return jsonify({"error": "select must be a string."}), 400
        if len(payload["select"]) > 200:
            return jsonify({"error": "select must be 200 characters or fewer."}), 400
        updated["select"] = payload["select"].strip()

    if "full_refresh" in payload:
        if not isinstance(payload["full_refresh"], bool):
            return jsonify({"error": "full_refresh must be true or false."}), 400
        updated["full_refresh"] = payload["full_refresh"]

    if "timezone" in payload:
        if not isinstance(payload["timezone"], str):
            return jsonify({"error": "timezone must be a string."}), 400
        try:
            cfgmod.resolve_timezone(payload["timezone"].strip())
        except ValueError as exc:
            return jsonify({"error": str(exc)}), 400
        updated["timezone"] = payload["timezone"].strip()

    saved = cfgmod.save_config(updated)
    configure_job()
    runner.clear_preflight_cache()
    log.info("Configuration saved: %s", saved)
    return jsonify(status_payload())


@app.post("/api/pause")
def api_pause() -> Any:
    cfg = cfgmod.load_config()
    cfg["enabled"] = False
    cfgmod.save_config(cfg)
    configure_job()
    log.info("Scheduler paused")
    return jsonify(status_payload())


@app.post("/api/resume")
def api_resume() -> Any:
    cfg = cfgmod.load_config()
    cfg["enabled"] = True
    cfgmod.save_config(cfg)
    configure_job()
    log.info("Scheduler resumed")
    return jsonify(status_payload())


@app.post("/api/preflight")
def api_preflight() -> Any:
    cfg = cfgmod.load_config()
    runner.clear_preflight_cache()
    return jsonify(runner.preflight(cfg["target"], force=True))


@app.after_request
def no_store(response: Any) -> Any:
    if request.path.startswith("/api/"):
        response.headers["Cache-Control"] = "no-store"
    return response


# ---------------------------------------------------------------------------
# Startup
# ---------------------------------------------------------------------------


def setup_logging() -> None:
    cfgmod.ensure_dirs()
    formatter = logging.Formatter("[scheduler] %(asctime)s %(levelname)s %(message)s", "%H:%M:%S")
    root = logging.getLogger()
    root.setLevel(logging.INFO)

    console = logging.StreamHandler()
    console.setFormatter(formatter)
    root.addHandler(console)

    file_handler = RotatingFileHandler(
        cfgmod.SCHEDULER_DIR / "scheduler.log",
        maxBytes=1_000_000,
        backupCount=3,
        encoding="utf-8",
    )
    file_handler.setFormatter(formatter)
    root.addHandler(file_handler)


def parse_args() -> argparse.Namespace:
    parser = argparse.ArgumentParser(description="Local web scheduler for dbt")
    parser.add_argument(
        "--host",
        default=os.environ.get("SCHEDULER_HOST", "127.0.0.1"),
        help="Bind address (default: 127.0.0.1)",
    )
    parser.add_argument(
        "--port",
        type=int,
        default=int(os.environ.get("SCHEDULER_PORT", "5055")),
        help="Port (default: 5055)",
    )
    parser.add_argument(
        "--no-browser",
        action="store_true",
        help="Do not open the dashboard in a browser on startup.",
    )
    parser.add_argument("--debug", action="store_true", help="Enable Flask debug output.")
    return parser.parse_args()


def main() -> None:
    args = parse_args()
    setup_logging()
    cfgmod.ensure_dirs()
    store.init_db()
    interrupted = store.mark_stale_runs()
    if interrupted:
        log.warning("Marked %s stale run(s) as interrupted", interrupted)

    scheduler.start()
    configure_job()

    cfg = cfgmod.load_config()
    job = scheduler.get_job(JOB_ID)
    next_run = job.next_run_time if job else None
    log.info(
        "%s listening on http://%s:%s (target=%s schedule=%s enabled=%s next=%s)",
        APP_NAME,
        args.host,
        args.port,
        cfg["target"],
        cfg["schedule_time"],
        cfg["enabled"],
        next_run,
    )

    atexit.register(runner.terminate_active)
    atexit.register(lambda: scheduler.shutdown(wait=False) if scheduler.running else None)

    url = f"http://{'127.0.0.1' if args.host in ('0.0.0.0', '::') else args.host}:{args.port}/"
    if not args.no_browser and not args.debug:
        threading.Timer(1.5, lambda: webbrowser.open(url)).start()

    if args.debug:
        app.run(
            host=args.host,
            port=args.port,
            debug=True,
            use_reloader=False,
            threaded=True,
        )
        return

    try:
        from waitress import serve
    except ImportError:
        log.warning("Waitress is not installed; falling back to the Flask dev server")
        app.run(host=args.host, port=args.port, debug=False, use_reloader=False, threaded=True)
        return

    log.info("Serving with Waitress")
    serve(app, host=args.host, port=args.port, threads=8)


if __name__ == "__main__":
    main()
