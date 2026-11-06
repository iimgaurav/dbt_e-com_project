/* Local dashboard logic. Vanilla JS, no build step. */

const $ = (id) => document.getElementById(id);

const state = {
  config: null,
  formReady: false,
  preflightOk: undefined,
  activeRun: false,
  selectedRun: null,
  logTimer: null,
  bannerTimer: null,
  connectionDown: false,
};

/* ---------------------------------------------------------------- helpers */

async function api(path, options = {}) {
  const response = await fetch(path, {
    headers: { "Content-Type": "application/json" },
    cache: "no-store",
    ...options,
  });
  let body = null;
  try {
    body = await response.json();
  } catch (err) {
    body = null;
  }
  if (!response.ok) {
    throw new Error((body && body.error) || `Request failed (${response.status})`);
  }
  return body;
}

function fmtDateTime(value) {
  if (!value) return "—";
  const date = new Date(value);
  if (Number.isNaN(date.getTime())) return "—";
  return date.toLocaleString(undefined, { dateStyle: "medium", timeStyle: "short" });
}

function fmtClock(value) {
  if (!value) return "—";
  const date = new Date(value);
  if (Number.isNaN(date.getTime())) return "—";
  return date.toLocaleTimeString(undefined, { timeStyle: "short" });
}

function relTime(value) {
  if (!value) return "—";
  const target = new Date(value).getTime();
  if (Number.isNaN(target)) return "—";
  const diff = target - Date.now();
  const abs = Math.abs(diff);
  const units = [
    ["day", 86400000],
    ["hour", 3600000],
    ["min", 60000],
    ["sec", 1000],
  ];
  for (const [name, ms] of units) {
    if (abs >= ms || name === "sec") {
      const count = Math.max(1, Math.round(abs / ms));
      const label = `${count} ${name}${count === 1 ? "" : "s"}`;
      return diff >= 0 ? `in ${label}` : `${label} ago`;
    }
  }
  return "—";
}

function fmtDuration(seconds) {
  if (seconds === null || seconds === undefined || Number.isNaN(Number(seconds))) {
    return "—";
  }
  const value = Number(seconds);
  if (value < 60) return `${value.toFixed(1)}s`;
  const minutes = Math.floor(value / 60);
  const rest = Math.round(value % 60);
  return `${minutes}m ${rest}s`;
}

function elapsedSince(value) {
  if (!value) return null;
  const started = new Date(value).getTime();
  if (Number.isNaN(started)) return null;
  return (Date.now() - started) / 1000;
}

function setConnection(ok, detail) {
  const dot = $("live-dot");
  if (state.activeRun) {
    dot.className = "live-dot busy";
  } else {
    dot.className = `live-dot ${ok ? "ok" : "bad"}`;
  }
  dot.title = detail || (ok ? "Connected" : "Disconnected");
}

/* ---------------------------------------------------------------- banner */

function hideBanner() {
  clearTimeout(state.bannerTimer);
  $("banner").classList.add("hidden");
}

function showBanner(message, kind = "info", sticky = false) {
  const banner = $("banner");
  banner.textContent = message;
  banner.className = `banner ${kind}`;
  clearTimeout(state.bannerTimer);
  if (!sticky) {
    state.bannerTimer = setTimeout(() => banner.classList.add("hidden"), 7000);
  }
}

/* ------------------------------------------------------------- rendering */

function renderStatus(data) {
  const scheduler = data.scheduler;
  const cfg = data.config;
  const preflight = data.preflight;

  if (state.connectionDown) {
    hideBanner();
    state.connectionDown = false;
  }

  state.config = cfg;
  state.activeRun = Boolean(scheduler.active_run);

  const prodLocked = Boolean(data.guards && data.guards.prod_locked);
  const prodOption = $("target-select").querySelector('option[value="prod"]');
  if (prodOption) {
    prodOption.disabled = prodLocked;
    prodOption.textContent = prodLocked
      ? "prod · locked"
      : "prod · dbt_prod (confirm required)";
  }
  $("prod-lock-note").classList.toggle("hidden", !prodLocked);

  if (!state.formReady) {
    $("schedule_time").value = cfg.schedule_time;
    $("target-select").value = cfg.target;
    $("select").value = cfg.select || "";
    $("full_refresh").checked = Boolean(cfg.full_refresh);
    state.formReady = true;
  }

  const stateLabel = scheduler.active_run ? "Running" : cfg.enabled ? "Armed" : "Paused";
  $("sched-state").textContent = stateLabel;
  $("sched-state").className =
    scheduler.active_run ? "status-running" : cfg.enabled ? "status-success" : "status-interrupted";
  $("sched-detail").textContent = `${cfg.schedule_time} daily · ${scheduler.timezone}`;

  if (!cfg.enabled) {
    $("next-run").textContent = "Paused";
    $("next-run-rel").textContent = "Resume to schedule";
  } else if (scheduler.next_run) {
    $("next-run").textContent = fmtDateTime(scheduler.next_run);
    $("next-run-rel").textContent = relTime(scheduler.next_run);
  } else {
    $("next-run").textContent = "—";
    $("next-run-rel").textContent = "No upcoming run";
  }

  const last = data.latest_run;
  if (!last) {
    $("last-status").textContent = "No runs yet";
    $("last-status").className = "muted";
    $("last-detail").textContent = "Use Run now to start the first build";
  } else {
    const warningSuffix =
      last.status === "success" && last.warnings > 0 ? ` · ${last.warnings} warn` : "";
    $("last-status").textContent = `${last.status}${warningSuffix}`;
    $("last-status").className = `status-${last.status}`;
    const duration =
      last.status === "running" ? elapsedSince(last.started_at) : last.duration_s;
    $("last-detail").textContent = `${fmtDateTime(last.started_at)} · ${fmtDuration(duration)}`;
  }

  $("target").textContent = cfg.target;
  $("catalog").textContent = preflight.ok
    ? preflight.catalog
    : `${preflight.catalog} · not ready`;

  $("btn-run").disabled = scheduler.active_run;
  $("btn-run").textContent = scheduler.active_run ? "Running…" : "Run now";
  $("btn-smoke").disabled = scheduler.active_run;
  $("btn-toggle").textContent = cfg.enabled ? "Pause" : "Resume";

  renderPreflight(preflight);

  if (!preflight.ok) {
    const firstError = preflight.checks.find((check) => check.status === "error");
    showBanner(
      `Target '${preflight.target}' is not ready: ${
        firstError ? firstError.detail : "preflight failed."
      }`,
      "error",
      true
    );
    state.preflightOk = false;
  } else if (state.preflightOk === false) {
    hideBanner();
    state.preflightOk = true;
  } else {
    state.preflightOk = true;
  }

  setConnection(true, "Connected");
}

function renderPreflight(preflight) {
  const list = $("preflight");
  list.replaceChildren();

  for (const check of preflight.checks) {
    const item = document.createElement("li");
    item.className = `check-item ${check.status}`;

    const icon = document.createElement("span");
    icon.className = "check-icon";
    icon.textContent = check.status === "ok" ? "✓" : check.status === "warn" ? "!" : "✕";

    const body = document.createElement("div");
    const name = document.createElement("span");
    name.className = "check-name";
    name.textContent = check.name;
    const detail = document.createElement("span");
    detail.className = "check-detail";
    detail.textContent = check.detail;

    body.append(name, detail);
    item.append(icon, body);
    list.append(item);
  }
}

function renderRuns(runs) {
  const body = $("runs-body");
  body.replaceChildren();
  $("runs-count").textContent = runs.length ? `${runs.length} shown` : "";

  if (!runs.length) {
    const row = document.createElement("tr");
    const cell = document.createElement("td");
    cell.colSpan = 7;
    cell.className = "empty";
    cell.textContent = "No runs recorded yet.";
    row.append(cell);
    body.append(row);
    return;
  }

  for (const run of runs) {
    const row = document.createElement("tr");

    const started = document.createElement("td");
    started.textContent = fmtDateTime(run.started_at);
    started.title = run.started_at || "";

    const trigger = document.createElement("td");
    trigger.textContent = run.trigger === "schedule" ? "schedule" : "manual";

    const target = document.createElement("td");
    target.textContent = run.target;

    const status = document.createElement("td");
    const pill = document.createElement("span");
    pill.className = `pill ${run.status}`;
    pill.textContent = run.status === "success" && run.warnings ? "success · warn" : run.status;
    status.append(pill);

    const duration = document.createElement("td");
    duration.className = "numeric";
    duration.textContent =
      run.status === "running"
        ? fmtDuration(elapsedSince(run.started_at))
        : fmtDuration(run.duration_s);

    const summary = document.createElement("td");
    summary.className = "summary";
    const summaryText = run.summary || (run.error ? run.error.split("\n")[0] : "");
    summary.textContent = summaryText || "—";
    summary.title = run.error || run.summary || "";

    const actions = document.createElement("td");
    const logButton = document.createElement("button");
    logButton.type = "button";
    logButton.className = "btn tiny ghost";
    logButton.textContent = "Log";
    logButton.addEventListener("click", () => openLog(run.id));
    actions.append(logButton);

    row.append(started, trigger, target, status, duration, summary, actions);
    if (state.selectedRun === run.id) {
      row.style.background = "#fafbfc";
    }
    body.append(row);
  }
}

/* ------------------------------------------------------------- data loads */

async function loadStatus() {
  try {
    const data = await api("/api/status");
    renderStatus(data);
  } catch (err) {
    state.connectionDown = true;
    setConnection(false, err.message);
    showBanner(`Dashboard connection failed: ${err.message}`, "error", true);
  }
}

async function loadRuns() {
  try {
    const data = await api("/api/runs?limit=25");
    renderRuns(data.runs || []);
  } catch (err) {
    setConnection(false, err.message);
  }
}

async function tick() {
  await Promise.allSettled([loadStatus(), loadRuns()]);
  $("foot-time").textContent = new Date().toLocaleString();
}

/* ---------------------------------------------------------------- actions */

async function triggerRun(payload) {
  const target = payload.target || (state.config && state.config.target);
  if (target === "prod") {
    const proceed = window.confirm(
      "This build will write to the PROD catalog (dbt_prod). Continue?"
    );
    if (!proceed) return;
  }
  try {
    const data = await api("/api/run", {
      method: "POST",
      body: JSON.stringify(payload),
    });
    showBanner(`Run #${data.run_id} started.`, "info");
    await Promise.all([loadStatus(), loadRuns()]);
    openLog(data.run_id);
  } catch (err) {
    showBanner(err.message, "error", true);
  }
}

async function toggleScheduler() {
  const enabled = state.config && state.config.enabled;
  const path = enabled ? "/api/pause" : "/api/resume";
  try {
    const data = await api(path, { method: "POST", body: "{}" });
    renderStatus(data);
  } catch (err) {
    showBanner(err.message, "error", true);
  }
}

async function saveConfig(event) {
  event.preventDefault();
  const payload = {
    schedule_time: $("schedule_time").value,
    target: $("target-select").value,
    select: $("select").value,
    full_refresh: $("full_refresh").checked,
  };
  if (payload.target === "prod") {
    const proceed = window.confirm(
      "Target 'prod' writes to the dbt_prod catalog. Save this schedule?"
    );
    if (!proceed) return;
  }
  const button = event.target.querySelector("button[type=submit]");
  button.disabled = true;
  $("save-msg").textContent = "";
  try {
    const data = await api("/api/config", {
      method: "POST",
      body: JSON.stringify(payload),
    });
    state.formReady = false;
    renderStatus(data);
    $("save-msg").textContent = "Saved.";
    setTimeout(() => {
      $("save-msg").textContent = "";
    }, 5000);
  } catch (err) {
    showBanner(err.message, "error", true);
  } finally {
    button.disabled = false;
  }
}

async function recheckPreflight() {
  const button = $("btn-preflight");
  button.disabled = true;
  try {
    await api("/api/preflight", { method: "POST", body: "{}" });
    await loadStatus();
  } catch (err) {
    showBanner(err.message, "error", true);
  } finally {
    button.disabled = false;
  }
}

/* -------------------------------------------------------------------- log */

async function refreshLog() {
  if (!state.selectedRun) return;
  try {
    const data = await api(`/api/runs/${state.selectedRun}/log?tail=500`);
    const pre = $("log");
    const atBottom = pre.scrollTop + pre.clientHeight >= pre.scrollHeight - 60;
    pre.textContent = data.log || "(no output yet)";
    if (atBottom) {
      pre.scrollTop = pre.scrollHeight;
    }
    const running = data.run.status === "running";
    $("log-live").classList.toggle("hidden", !running);
    if (!running && state.logTimer) {
      clearInterval(state.logTimer);
      state.logTimer = null;
    }
  } catch (err) {
    $("log").textContent = err.message;
  }
}

async function openLog(runId) {
  state.selectedRun = runId;
  $("log-panel").classList.remove("hidden");
  $("log-run").textContent = `#${runId}`;
  $("log-live").classList.add("hidden");
  $("log-panel").scrollIntoView({ behavior: "smooth", block: "nearest" });
  await refreshLog();
  if (state.logTimer) {
    clearInterval(state.logTimer);
  }
  state.logTimer = setInterval(refreshLog, 2000);
}

function closeLog() {
  state.selectedRun = null;
  if (state.logTimer) {
    clearInterval(state.logTimer);
    state.logTimer = null;
  }
  $("log-panel").classList.add("hidden");
  $("log-live").classList.add("hidden");
  loadRuns();
}

/* ------------------------------------------------------------------ wire */

$("btn-run").addEventListener("click", () => triggerRun({}));

$("btn-smoke").addEventListener("click", () => {
  const ok = window.confirm(
    "Run a quick smoke test against the dev catalog?\n\nThis runs dbt build --select dim_date --target dev."
  );
  if (ok) {
    triggerRun({ target: "dev", select: "dim_date" });
  }
});

$("btn-toggle").addEventListener("click", toggleScheduler);
$("config-form").addEventListener("submit", saveConfig);
$("btn-preflight").addEventListener("click", recheckPreflight);
$("btn-log-close").addEventListener("click", closeLog);
$("btn-log-refresh").addEventListener("click", refreshLog);

document.addEventListener("keydown", (event) => {
  if (event.key === "Escape" && state.selectedRun) {
    closeLog();
  }
});

/* ----------------------------------------------------------------- start */

tick();
setInterval(tick, 5000);
setInterval(() => {
  $("foot-time").textContent = new Date().toLocaleString();
}, 1000);
