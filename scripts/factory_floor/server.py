#!/usr/bin/env python3
"""Forge Floor — localhost mission control (port 7420).

Lens + soft controls. Starts/attaches task-loop via controls.json.
"""

from __future__ import annotations

import json
import os
import re
import subprocess
import sys
import threading
import time
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from pathlib import Path
from typing import Any
from urllib.parse import parse_qs, urlparse

REPO_ROOT = Path(__file__).resolve().parents[2]
SCRIPTS = REPO_ROOT / "scripts"
sys.path.insert(0, str(SCRIPTS))

PORT = 7420
CONTROLS = REPO_ROOT / "build" / "factory" / "controls.json"
HOT = REPO_ROOT / "build" / "factory" / "factory-hot"
BATCH_GATE = REPO_ROOT / "build" / "factory" / "batch-gate.json"
STATION = REPO_ROOT / "build" / "factory" / "station.json"
EVENTS_DIR = REPO_ROOT / "build" / "test-results"

_runner_proc: subprocess.Popen | None = None
_runner_lock = threading.Lock()


def _default_controls() -> dict[str, Any]:
    return {
        "running": False,
        "paused": False,
        "ship_now": False,
        "skip_batch_gate": False,
        "cancel_task_id": None,
        "requeue_task_id": None,
        "priority_bumps": {},
        "batch_action": None,
        "batch_blocked": False,
        "batch_running": False,
        "mark_done_task_id": None,
        "updated_at": None,
    }


def read_controls() -> dict[str, Any]:
    if not CONTROLS.is_file():
        return _default_controls()
    try:
        data = json.loads(CONTROLS.read_text(encoding="utf-8"))
        base = _default_controls()
        base.update(data)
        return base
    except (OSError, json.JSONDecodeError):
        return _default_controls()


def write_controls(data: dict[str, Any]) -> None:
    CONTROLS.parent.mkdir(parents=True, exist_ok=True)
    data = dict(data)
    data["updated_at"] = time.time()
    CONTROLS.write_text(json.dumps(data, indent=2) + "\n", encoding="utf-8")


def parse_meta(path: Path) -> dict[str, str]:
    text = path.read_text(encoding="utf-8")
    meta: dict[str, str] = {}
    for m in re.finditer(
        r"^\|\s*\*\*([^*]+)\*\*\s*\|\s*([^|]*)\|", text, re.MULTILINE
    ):
        meta[m.group(1).strip()] = m.group(2).strip()
    return meta


def _read_json_file(path: Path) -> dict[str, Any]:
    if not path.is_file():
        return {}
    try:
        data = json.loads(path.read_text(encoding="utf-8"))
        return data if isinstance(data, dict) else {}
    except (OSError, json.JSONDecodeError):
        return {}


def _verify_running() -> bool:
    """Best-effort: xcodebuild test or verify.sh alive under this repo."""
    try:
        out = subprocess.check_output(["ps", "-ax", "-o", "command="], text=True)
    except (OSError, subprocess.CalledProcessError):
        return False
    root = str(REPO_ROOT)
    for line in out.splitlines():
        if "xcodebuild" in line and "test" in line and ("PodWash" in line or root in line):
            return True
        if "verify.sh" in line and root in line:
            return True
    return False


def _batch_snapshot(ctrl: dict[str, Any]) -> dict[str, Any]:
    """Derive batch gate UI state from stamp + live controls."""
    try:
        from task_loop import batch_needed, head_sha, read_batch_gate
    except ImportError:
        return {"state": "idle", "needed": False, "reason": "unavailable"}

    stamp = read_batch_gate(path=str(BATCH_GATE)) if BATCH_GATE.is_file() else {}
    # Prefer shared helpers when paths match defaults
    needed, reason = batch_needed(force=False)
    head = head_sha()
    last = str(stamp.get("sha") or "")
    running = bool(ctrl.get("batch_running")) or _verify_running()
    blocked = bool(ctrl.get("batch_blocked"))
    if blocked:
        state = "blocked"
    elif running and (needed or ctrl.get("batch_running") or ctrl.get("ship_now")):
        state = "running"
    elif running:
        # Surgical tier-2 also uses xcodebuild — treat as task verify, not batch
        state = "green" if last and last == head and not needed else "pending" if needed else "idle"
    elif needed:
        state = "pending"
    elif last:
        state = "green"
    else:
        state = "idle"
    return {
        "state": state,
        "needed": needed,
        "reason": reason,
        "last_green_sha": last,
        "head_sha": head,
        "verify_running": running,
        "batch_running": bool(ctrl.get("batch_running")),
    }


def board_snapshot() -> dict[str, Any]:
    tasks = []
    tasks_dir = REPO_ROOT / "docs" / "tasks"
    if tasks_dir.is_dir():
        for path in sorted(tasks_dir.glob("task-*.md")):
            if path.name.startswith("_"):
                continue
            meta = parse_meta(path)
            tasks.append(
                {
                    "id": meta.get("ID", path.name),
                    "title": meta.get("Title", path.stem),
                    "status": meta.get("Status", "?"),
                    "kind": meta.get("Kind", ""),
                    "priority": meta.get("Priority", ""),
                    "area": meta.get("Area", ""),
                    "path": str(path.relative_to(REPO_ROOT)),
                    "type": "task",
                }
            )
    slices = []
    slices_dir = REPO_ROOT / "docs" / "slices"
    if slices_dir.is_dir():
        for path in sorted(slices_dir.glob("slice-[0-9][0-9]-*.md")):
            if path.name.endswith("-ux.md"):
                continue
            meta = parse_meta(path)
            st = meta.get("Status", "")
            if re.search(r"Deferred|post-MVP", st, re.I):
                continue
            slices.append(
                {
                    "id": meta.get("ID", path.name),
                    "title": meta.get("Title", path.stem),
                    "status": st,
                    "kind": "slice",
                    "priority": "P3",
                    "area": "",
                    "path": str(path.relative_to(REPO_ROOT)),
                    "type": "slice",
                }
            )
    events: list[dict[str, Any]] = []
    if EVENTS_DIR.is_dir():
        files = sorted(EVENTS_DIR.glob("events-*.jsonl"), key=lambda p: p.stat().st_mtime)
        for ef in files[-5:]:
            try:
                for line in ef.read_text(encoding="utf-8").splitlines()[-20:]:
                    if line.strip():
                        events.append(json.loads(line))
            except (OSError, json.JSONDecodeError):
                pass
    ctrl = read_controls()
    station = _read_json_file(STATION)
    batch = _batch_snapshot(ctrl)
    # Prefer live station.batch overlay when present
    if isinstance(station.get("batch"), dict):
        merged = dict(batch)
        merged.update(station["batch"])
        batch = merged
    return {
        "tasks": tasks,
        "slices": slices,
        "controls": ctrl,
        "factory_hot": HOT.is_file(),
        "station": station,
        "batch": batch,
        "events": events[-40:],
        "ts": time.time(),
    }


def start_runner() -> str:
    global _runner_proc
    with _runner_lock:
        if _runner_proc is not None and _runner_proc.poll() is None:
            return "already running"
        env = os.environ.copy()
        env["PODWASH_FORGE_LOOP"] = "task_loop"
        _runner_proc = subprocess.Popen(
            [str(SCRIPTS / "task-loop.sh"), "--no-self-heal"],
            cwd=str(REPO_ROOT),
            env=env,
            stdout=subprocess.DEVNULL,
            stderr=subprocess.DEVNULL,
        )
        ctrl = read_controls()
        ctrl["running"] = True
        ctrl["paused"] = False
        write_controls(ctrl)
        return f"started pid={_runner_proc.pid}"


def stop_runner() -> str:
    global _runner_proc
    ctrl = read_controls()
    ctrl["running"] = False
    ctrl["paused"] = True
    write_controls(ctrl)
    with _runner_lock:
        if _runner_proc is not None and _runner_proc.poll() is None:
            _runner_proc.terminate()
            try:
                _runner_proc.wait(timeout=5)
            except subprocess.TimeoutExpired:
                _runner_proc.kill()
        _runner_proc = None
    return "stopped"


INDEX_HTML = r"""<!DOCTYPE html>
<html lang="en">
<head>
<meta charset="utf-8"/>
<title>Forge Floor</title>
<style>
:root {
  --bg: #1a1c1e;
  --panel: #24282c;
  --ink: #e8eaed;
  --muted: #9aa0a6;
  --accent: #e8a838;
  --ok: #5bb88a;
  --warn: #e07a5f;
  --line: #3a3f45;
  --font: "IBM Plex Sans", "Segoe UI", system-ui, sans-serif;
}
* { box-sizing: border-box; }
body {
  margin: 0; font-family: var(--font); background:
    radial-gradient(1200px 600px at 10% -10%, #2a3140 0%, transparent 55%),
    var(--bg);
  color: var(--ink); min-height: 100vh;
}
header {
  display: flex; align-items: center; gap: 1rem; padding: 1rem 1.25rem;
  border-bottom: 1px solid var(--line);
}
header h1 { margin: 0; font-size: 1.35rem; letter-spacing: 0.04em; }
header .brand { color: var(--accent); font-weight: 700; }
.hint { color: var(--muted); font-size: 0.85rem; }
.toolbar { display: flex; flex-wrap: wrap; gap: 0.5rem; margin-left: auto; }
button {
  background: var(--panel); color: var(--ink); border: 1px solid var(--line);
  border-radius: 6px; padding: 0.45rem 0.75rem; cursor: pointer; font: inherit;
}
button.primary { background: var(--accent); color: #1a1c1e; border-color: transparent; font-weight: 600; }
button.danger { border-color: var(--warn); color: var(--warn); }
button:hover { filter: brightness(1.08); }
main { display: grid; grid-template-columns: 1fr 320px; gap: 1rem; padding: 1rem; }
@media (max-width: 900px) { main { grid-template-columns: 1fr; } }
.columns { display: grid; grid-template-columns: repeat(5, minmax(140px, 1fr)); gap: 0.75rem; }
.col { background: var(--panel); border-radius: 10px; border: 1px solid var(--line); min-height: 280px; }
.col h2 { margin: 0; padding: 0.6rem 0.75rem; font-size: 0.8rem; text-transform: uppercase;
  letter-spacing: 0.06em; color: var(--muted); border-bottom: 1px solid var(--line); }
.card {
  margin: 0.5rem; padding: 0.65rem; border-radius: 8px; background: #2c3136;
  border: 1px solid var(--line); cursor: pointer;
}
.card .meta { font-size: 0.75rem; color: var(--muted); }
.card .prio { color: var(--accent); font-weight: 600; }
.side { display: flex; flex-direction: column; gap: 0.75rem; }
.station, .feed, .klaxon {
  background: var(--panel); border: 1px solid var(--line); border-radius: 10px; padding: 0.75rem;
}
.station h3, .feed h3, .klaxon h3 { margin: 0 0 0.5rem; font-size: 0.9rem; }
.station .beat { color: var(--ink); font-size: 0.95rem; font-weight: 600; }
.station .sub { color: var(--muted); font-size: 0.8rem; margin-top: 0.35rem; }
.station .batch-line {
  margin-top: 0.65rem; padding-top: 0.55rem; border-top: 1px solid var(--line);
  font-size: 0.8rem; color: var(--muted);
}
.station .batch-line strong { color: var(--accent); }
.station.running { border-color: var(--ok); }
.station.pending { border-color: var(--accent); }
.station.blocked { border-color: var(--warn); }
.card.active {
  border-color: var(--ok);
  box-shadow: 0 0 0 1px var(--ok);
}
.card .phase { font-size: 0.75rem; color: var(--ok); margin-top: 0.25rem; }
.klaxon.on { border-color: var(--warn); box-shadow: 0 0 0 1px var(--warn); }
.feed { max-height: 360px; overflow: auto; font-size: 0.8rem; }
.feed div { padding: 0.25rem 0; border-bottom: 1px solid var(--line); }
.status-pill { display: inline-block; padding: 0.15rem 0.5rem; border-radius: 999px;
  background: #333; font-size: 0.75rem; }
.status-pill.hot { background: #3a4a3a; color: var(--ok); }
.drawer {
  position: fixed; right: 0; top: 0; bottom: 0; width: min(420px, 100%);
  background: #1e2226; border-left: 1px solid var(--line); padding: 1rem;
  transform: translateX(100%); transition: transform 0.2s ease; z-index: 20;
}
.drawer.open { transform: translateX(0); }
.drawer pre { white-space: pre-wrap; font-size: 0.8rem; color: var(--muted); }
.idle { text-align: center; padding: 2rem; color: var(--muted); }
</style>
</head>
<body>
<header>
  <div>
    <h1><span class="brand">Forge Floor</span></h1>
    <div class="hint">Add work in Cursor with <code>forge-intake</code></div>
  </div>
  <span id="hot" class="status-pill">stopped</span>
  <div class="toolbar">
    <button class="primary" id="btnStart">Start factory</button>
    <button id="btnPause">Pause</button>
    <button id="btnResume">Resume</button>
    <button id="btnShip">Ship now</button>
    <button id="btnStop">Stop</button>
  </div>
</header>
<main>
  <section>
    <div id="idle" class="idle" hidden>Waiting for intake — queue a punch list with forge-intake</div>
    <div class="columns" id="board"></div>
  </section>
  <aside class="side">
    <div class="station" id="station">
      <h3>Stations</h3>
      <div class="beat" id="stationBeat">Shift quiet — no workers on the floor yet.</div>
      <div class="sub" id="stationSub"></div>
      <div class="batch-line" id="batchLine">Batch · —</div>
    </div>
    <div class="klaxon" id="klaxon">
      <h3>Klaxon</h3>
      <div id="klaxonBody">All clear.</div>
      <div class="toolbar" style="margin-top:0.5rem">
        <button id="btnRequeue">Requeue Halted</button>
        <button class="danger" id="btnHold">Hold-all batch</button>
        <button id="btnQuarantine">Quarantine</button>
      </div>
    </div>
    <div class="feed">
      <h3>Event feed</h3>
      <div id="feed"></div>
    </div>
  </aside>
</main>
<div class="drawer" id="drawer">
  <button id="btnClose">Close</button>
  <h2 id="drawerTitle"></h2>
  <pre id="drawerBody"></pre>
</div>
<script>
const cols = ["Queued","In Progress","Needs-human","Halted","Done"];
let snap = null;
let selected = null;

function colFor(item) {
  const s = (item.status||"");
  if (/Needs-human/i.test(s) || /needs-human/i.test(item.kind||"")) return "Needs-human";
  if (/Halted/i.test(s)) return "Halted";
  if (/In Progress/i.test(s)) return "In Progress";
  if (/^Done/i.test(s)) return "Done";
  if (/Queued|Ready|Draft/i.test(s)) return "Queued";
  return "Queued";
}

function batchLabel(b) {
  if (!b) return "Batch · —";
  const short = (s) => (s ? String(s).slice(0, 12) : "?");
  if (b.state === "running" || b.batch_running) {
    return `Batch · running tier-3 (${b.reason || "verify"})`;
  }
  if (b.state === "blocked") {
    return `Batch · blocked — open Klaxon`;
  }
  if (b.state === "pending" || b.needed) {
    return `Batch · needed — ${b.reason || "pending"}`;
  }
  if (b.state === "green" || b.last_green_sha) {
    return `Batch · green @ ${short(b.last_green_sha)} · ${b.reason === "not needed" ? "nothing to ship" : (b.reason || "ok")}`;
  }
  return `Batch · idle`;
}

function stationLabel(st, batch) {
  if (st && st.phase) {
    const tid = st.task_id != null ? `task-${String(st.task_id).padStart(3,"0")}` : "";
    const who = st.role || "loop";
    const phase = st.phase;
    const detail = st.detail || st.mission || "";
    return { beat: `${phase} · ${who}${tid ? " · " + tid : ""}`, sub: detail };
  }
  if (batch && (batch.state === "running" || batch.batch_running)) {
    return { beat: `FULL-VERIFY · loop`, sub: `tier-3 (${batch.reason || "verify"})` };
  }
  if (batch && batch.needed) {
    return { beat: `Batch pending`, sub: batch.reason || "full verify needed" };
  }
  return { beat: "Shift quiet — no workers on the floor yet.", sub: "" };
}

function render() {
  if (!snap) return;
  const hot = document.getElementById("hot");
  const running = !!(snap.controls && snap.controls.running) || snap.factory_hot;
  hot.textContent = running ? (snap.controls.paused ? "paused" : "hot") : "stopped";
  hot.className = "status-pill" + (running ? " hot" : "");

  const board = document.getElementById("board");
  board.innerHTML = "";
  const items = [...(snap.tasks||[]), ...(snap.slices||[])];
  const idle = document.getElementById("idle");
  const queuedAuto = items.filter(i => colFor(i)==="Queued" && i.type==="task" && !/needs-human/i.test(i.kind||""));
  const inProg = items.filter(i => colFor(i)==="In Progress" && i.type==="task");
  const batch = snap.batch || {};
  const st = snap.station || {};
  let idleMsg = "Waiting for intake — queue a punch list with forge-intake";
  if (running && queuedAuto.length===0 && inProg.length===0 && !(snap.controls&&snap.controls.batch_blocked)) {
    if (batch.state === "running" || batch.batch_running) {
      idleMsg = `Queue empty · full verify running (${batch.reason||"tier-3"})`;
    } else if (batch.needed) {
      idleMsg = `Queue empty · full verify pending — ${batch.reason||"needed"}`;
    } else if (batch.state === "green") {
      idleMsg = `Queue empty · full verify not needed (green @ ${(batch.last_green_sha||"").slice(0,12)})`;
    }
    idle.hidden = false;
    idle.textContent = idleMsg;
  } else {
    idle.hidden = true;
  }

  const activeTid = st.task_id != null ? String(st.task_id).padStart(3,"0") : null;
  for (const name of cols) {
    const col = document.createElement("div");
    col.className = "col";
    col.innerHTML = `<h2>${name}</h2>`;
    for (const item of items.filter(i => colFor(i)===name)) {
      const card = document.createElement("div");
      const isActive = item.type==="task" && activeTid && String(item.id).padStart(3,"0")===activeTid;
      card.className = "card" + (isActive ? " active" : "");
      let phaseHtml = "";
      if (isActive && st.phase) {
        phaseHtml = `<div class="phase">${st.phase}${st.detail ? " — " + st.detail : ""}</div>`;
      }
      card.innerHTML = `<div><span class="prio">${item.priority||""}</span> ${item.type} ${item.id}</div>
        <div>${item.title||""}</div>
        <div class="meta">${item.kind||""} · ${(item.area||"").slice(0,40)}</div>${phaseHtml}`;
      card.onclick = () => openDrawer(item);
      col.appendChild(card);
    }
    board.appendChild(col);
  }

  const k = document.getElementById("klaxon");
  const kb = document.getElementById("klaxonBody");
  const blocked = snap.controls && snap.controls.batch_blocked;
  const halted = items.filter(i => /Halted/i.test(i.status||""));
  if (blocked || halted.length) {
    k.classList.add("on");
    kb.textContent = blocked
      ? "Batch blocked — choose Quarantine or Hold-all."
      : `Halted: ${halted.map(h=>h.id).join(", ")}. Amend in Cursor if needed, then Requeue.`;
  } else {
    k.classList.remove("on");
    kb.textContent = "All clear.";
  }

  const feed = document.getElementById("feed");
  feed.innerHTML = "";
  for (const ev of (snap.events||[]).slice().reverse()) {
    const d = document.createElement("div");
    d.textContent = `${ev.phase||""} ${ev.role||""} ${ev.event||""} ${(ev.detail&&ev.detail.mission)||ev.mission||""}`;
    feed.appendChild(d);
  }

  const stationEl = document.getElementById("station");
  stationEl.className = "station" + (batch.state === "running" || batch.batch_running ? " running"
    : batch.state === "blocked" ? " blocked"
    : batch.needed ? " pending" : "");
  const labels = stationLabel(st, batch);
  document.getElementById("stationBeat").textContent = labels.beat;
  document.getElementById("stationSub").textContent = labels.sub || "";
  document.getElementById("batchLine").textContent = batchLabel(batch);
}

function openDrawer(item) {
  selected = item;
  document.getElementById("drawer").classList.add("open");
  document.getElementById("drawerTitle").textContent = `${item.type} ${item.id} — ${item.title}`;
  document.getElementById("drawerBody").textContent = JSON.stringify(item, null, 2);
}

async function post(path, body) {
  await fetch(path, { method:"POST", headers:{"Content-Type":"application/json"}, body: JSON.stringify(body||{}) });
  await refresh();
}

async function refresh() {
  const r = await fetch("/api/board");
  snap = await r.json();
  render();
}

document.getElementById("btnClose").onclick = () => document.getElementById("drawer").classList.remove("open");
document.getElementById("btnStart").onclick = () => post("/api/control", {action:"start"});
document.getElementById("btnStop").onclick = () => post("/api/control", {action:"stop"});
document.getElementById("btnPause").onclick = () => post("/api/control", {action:"pause"});
document.getElementById("btnResume").onclick = () => post("/api/control", {action:"resume"});
document.getElementById("btnShip").onclick = () => post("/api/control", {action:"ship_now"});
document.getElementById("btnHold").onclick = () => {
  if (confirm("Hold entire batch (no push)?")) post("/api/control", {action:"batch_hold"});
};
document.getElementById("btnQuarantine").onclick = () => {
  if (confirm("Quarantine offenders and retry ship?")) post("/api/control", {action:"batch_quarantine"});
};
document.getElementById("btnRequeue").onclick = () => {
  const halted = (snap.tasks||[]).find(t => /Halted/i.test(t.status||""));
  if (!halted) return alert("No Halted task");
  const id = parseInt(String(halted.id).replace(/\D/g,""), 10);
  post("/api/control", {action:"requeue", task_id: id});
};

const es = new EventSource("/api/events");
es.onmessage = (e) => { try { snap = JSON.parse(e.data); render(); } catch(_){} };
refresh();
setInterval(refresh, 5000);
</script>
</body>
</html>
"""


class Handler(BaseHTTPRequestHandler):
    def log_message(self, fmt: str, *args: Any) -> None:
        sys.stderr.write("[forge-floor] " + (fmt % args) + "\n")

    def _json(self, code: int, obj: Any) -> None:
        raw = json.dumps(obj).encode("utf-8")
        self.send_response(code)
        self.send_header("Content-Type", "application/json")
        self.send_header("Content-Length", str(len(raw)))
        self.end_headers()
        self.wfile.write(raw)

    def _html(self, html: str) -> None:
        raw = html.encode("utf-8")
        self.send_response(200)
        self.send_header("Content-Type", "text/html; charset=utf-8")
        self.send_header("Content-Length", str(len(raw)))
        self.end_headers()
        self.wfile.write(raw)

    def do_GET(self) -> None:  # noqa: N802
        path = urlparse(self.path).path
        if path in ("/", "/index.html"):
            self._html(INDEX_HTML)
            return
        if path == "/api/board":
            self._json(200, board_snapshot())
            return
        if path == "/api/events":
            self.send_response(200)
            self.send_header("Content-Type", "text/event-stream")
            self.send_header("Cache-Control", "no-cache")
            self.send_header("Connection", "keep-alive")
            self.end_headers()
            try:
                while True:
                    payload = json.dumps(board_snapshot())
                    self.wfile.write(f"data: {payload}\n\n".encode("utf-8"))
                    self.wfile.flush()
                    time.sleep(2)
            except (BrokenPipeError, ConnectionResetError):
                return
        self.send_error(404)

    def do_POST(self) -> None:  # noqa: N802
        path = urlparse(self.path).path
        length = int(self.headers.get("Content-Length", "0") or 0)
        body = self.rfile.read(length) if length else b"{}"
        try:
            data = json.loads(body.decode("utf-8") or "{}")
        except json.JSONDecodeError:
            data = {}
        if path != "/api/control":
            self.send_error(404)
            return
        action = data.get("action")
        ctrl = read_controls()
        msg = "ok"
        if action == "start":
            msg = start_runner()
        elif action == "stop":
            msg = stop_runner()
        elif action == "pause":
            ctrl["paused"] = True
            write_controls(ctrl)
        elif action == "resume":
            ctrl["paused"] = False
            write_controls(ctrl)
        elif action == "ship_now":
            ctrl["ship_now"] = True
            write_controls(ctrl)
        elif action == "requeue":
            ctrl["requeue_task_id"] = data.get("task_id")
            write_controls(ctrl)
        elif action == "cancel":
            ctrl["cancel_task_id"] = data.get("task_id")
            write_controls(ctrl)
        elif action == "mark_done":
            ctrl["mark_done_task_id"] = data.get("task_id")
            write_controls(ctrl)
        elif action == "batch_hold":
            ctrl["batch_action"] = "hold_all"
            ctrl["batch_blocked"] = True
            write_controls(ctrl)
        elif action == "batch_quarantine":
            ctrl["batch_action"] = "quarantine"
            write_controls(ctrl)
        elif action == "bump":
            bumps = ctrl.get("priority_bumps") or {}
            bumps[str(data.get("task_id"))] = data.get("priority", "P0")
            ctrl["priority_bumps"] = bumps
            write_controls(ctrl)
        else:
            self._json(400, {"error": f"unknown action {action}"})
            return
        self._json(200, {"ok": True, "message": msg, "controls": read_controls()})


def main() -> int:
    try:
        server = ThreadingHTTPServer(("127.0.0.1", PORT), Handler)
    except OSError as exc:
        print(f"forge-floor: port {PORT} busy — {exc}", file=sys.stderr)
        return 1
    print(f"Forge Floor → http://127.0.0.1:{PORT}", flush=True)
    try:
        server.serve_forever()
    except KeyboardInterrupt:
        print("\nbye", flush=True)
    return 0


if __name__ == "__main__":
    sys.exit(main())
