#!/usr/bin/env python3
"""PodWash slice loop — Phase 2 of the slice runner.

Runs eligible slices to Done, one after another, on the LOCAL machine (so
`scripts/verify.sh` has real Xcode + the iOS Simulator). It is a thin driver
around two trusted pieces:

  1. `scripts/next-slice.sh --json`  — the dependency-aware "what's next?" brain.
  2. A local Cursor SDK agent        — runs the coordinator for one slice.

Verification honesty: the loop only advances when `next-slice.sh` confirms the
slice's status actually flipped to Done (with a green VERIFY RESULT). It never
trusts the agent's self-report, so a half-finished slice cannot advance the queue.

Stop conditions (never guessed around):
  - halt : the next slice is a halt-and-ask gate → a human must decide first.
  - wait : every remaining slice is blocked on an unfinished dependency.
  - done : the queue is complete.
  - a slice failed to reach Done (agent error or verify red) → stop, no spin.

Usage:
  scripts/slice-loop.sh                 # run the queue until it stops
  scripts/slice-loop.sh --dry-run       # show what WOULD run; spawns no agents
  scripts/slice-loop.sh --max 3         # run at most 3 slices this session
  scripts/slice-loop.sh --model auto    # let the server pick the coordinator model

Auth (non-dry-run): export CURSOR_API_KEY=cursor_...
"""

import argparse
import json
import os
import subprocess
import sys
import threading
import time

REPO_ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
NEXT_SLICE = os.path.join(REPO_ROOT, "scripts", "next-slice.sh")

# Exit codes (align with SDK skill's guidance).
EXIT_OK = 0            # queue done, or --max reached cleanly
EXIT_STARTUP = 1       # agent never started (auth/config/network)
EXIT_RUN_FAILED = 2    # agent ran but slice did not reach Done (or no progress)
EXIT_WAIT = 3          # blocked on an unfinished dependency
EXIT_HALT = 4          # halt-and-ask gate needs a user decision


def log(msg):
    print(f"[slice-loop] {msg}", flush=True)


def _short_path(path, max_len=56):
    if not path:
        return ""
    path = str(path)
    if len(path) <= max_len:
        return path
    return "…" + path[-(max_len - 1) :]


def _summarize_tool(name, args):
    """One-line label for a tool invocation (kept short for terminal progress)."""
    if args is None:
        args = {}
    if isinstance(args, str):
        try:
            args = json.loads(args)
        except json.JSONDecodeError:
            return f"{name}: {args[:60]}"
    if not isinstance(args, dict):
        return name

    if name == "Shell":
        cmd = (args.get("command") or args.get("description") or "").strip()
        line = cmd.split("\n", 1)[0].strip()
        return f"Shell: {line[:72]}" if line else "Shell"
    if name in ("Read", "Write", "StrReplace", "Delete"):
        return f"{name}: {_short_path(args.get('path', ''))}"
    if name == "Task":
        desc = (args.get("description") or args.get("prompt") or "subagent")[:72]
        return f"subagent: {desc}"
    if name == "Grep":
        pat = str(args.get("pattern", ""))[:40]
        return f"Grep: {pat}" if pat else "Grep"
    if name == "Glob":
        return f"Glob: {args.get('glob_pattern', '')[:40]}"
    return name


class RunProgress:
    """Concise terminal progress without dumping the full agent transcript."""

    def __init__(self, verbose=False, heartbeat_secs=90):
        self.verbose = verbose
        self.heartbeat_secs = heartbeat_secs
        self.last_activity = time.time()
        self.last_label = "coordinator starting"
        self._seen_starts = set()
        self._stop = threading.Event()
        self._thread = None

    def start(self):
        if self.heartbeat_secs > 0:
            self._thread = threading.Thread(target=self._heartbeat, daemon=True)
            self._thread.start()

    def stop(self):
        self._stop.set()

    def _heartbeat(self):
        while not self._stop.wait(self.heartbeat_secs):
            idle = int(time.time() - self.last_activity)
            log(f"still running ({idle}s idle — last: {self.last_label})")

    def note(self, label):
        self.last_activity = time.time()
        self.last_label = label

    def handle(self, message):
        if isinstance(message, dict):
            mtype = message.get("type")
            if mtype == "tool_call":
                self._tool(
                    message.get("callId") or message.get("call_id", ""),
                    message.get("name", "tool"),
                    message.get("status", ""),
                    message.get("args"),
                )
            elif mtype == "task":
                self._task(message.get("status", ""), message.get("text", ""))
            elif mtype == "status":
                self._status(message.get("message") or message.get("status", ""))
            elif mtype == "assistant" and self.verbose:
                self._assistant_dict(message)
            return

        mtype = getattr(message, "type", None)
        if mtype == "tool_call":
            self._tool(
                getattr(message, "call_id", ""),
                getattr(message, "name", "tool"),
                getattr(message, "status", ""),
                getattr(message, "args", None),
            )
        elif mtype == "task":
            self._task(getattr(message, "status", ""), getattr(message, "text", ""))
        elif mtype == "status":
            self._status(getattr(message, "message", "") or getattr(message, "status", ""))
        elif mtype == "assistant" and self.verbose:
            self._assistant_typed(message)

    def _tool(self, call_id, name, status, args):
        label = _summarize_tool(name, args)
        if status == "running" and call_id not in self._seen_starts:
            self._seen_starts.add(call_id)
            log(f"→ {label}")
            self.note(label)
        elif status in ("completed", "error"):
            mark = "✓" if status == "completed" else "✗"
            log(f"{mark} {label}")
            self.note(f"{mark} {label}")

    def _task(self, status, text):
        text = (text or "").strip()
        if not text:
            return
        line = text.split("\n", 1)[0][:72]
        log(f"task [{status}]: {line}" if status else f"task: {line}")
        self.note(line)

    def _status(self, text):
        text = (text or "").strip()
        if not text:
            return
        log(f"status: {text[:100]}")
        self.note(text[:72])

    def _assistant_typed(self, message):
        for block in getattr(getattr(message, "message", None), "content", []):
            if getattr(block, "type", None) == "text":
                text = getattr(block, "text", "")
                if text:
                    sys.stdout.write(text)
                    sys.stdout.flush()
                    self.note("assistant text")

    def _assistant_dict(self, message):
        msg = message.get("message") or {}
        for block in msg.get("content") or []:
            if isinstance(block, dict) and block.get("type") == "text":
                text = block.get("text", "")
                if text:
                    sys.stdout.write(text)
                    sys.stdout.flush()
                    self.note("assistant text")


def query_next():
    """Return the decision dict from `next-slice.sh --json`."""
    proc = subprocess.run(
        [NEXT_SLICE, "--json"],
        cwd=REPO_ROOT,
        capture_output=True,
        text=True,
    )
    if proc.returncode != 0:
        raise RuntimeError(
            f"next-slice.sh failed (exit {proc.returncode}): {proc.stderr.strip()}"
        )
    out = proc.stdout.strip()
    try:
        return json.loads(out)
    except json.JSONDecodeError as exc:
        raise RuntimeError(f"could not parse next-slice.sh output: {out!r}") from exc


def build_prompt(slice_id, slice_file):
    """The coordinator kickoff prompt for one slice, run unattended."""
    nn = f"{slice_id:02d}"
    return f"""You are the PodWash Multitask COORDINATOR, running unattended via the slice loop.

First, load the process and gates by reading:
- .cursor/rules/podwash-coordinator.mdc
- docs/multitask-workflow.md
- {slice_file}

Then run Slice {nn} to completion per that slice file:
- Enforce every gate: PM story, Architect/UX design (if the slice adds modules or UI),
  QA test spec, Engineer implementation, QA verification.
- Spawn role subagents as needed. Model assignment: Architect and Engineer on
  Grok 4.5; PM, UX, QA on Composer 2.5.
- Definition of Done (all required): full `scripts/verify.sh` suite green
  (exit 0, 0 failed, 0 skipped), the `VERIFY RESULT:` line recorded in the slice
  file's verification record, the slice Status set to Done, an auto-commit
  `slice-{nn}: <short description>` made, then pushed to the remote.

STOP CONDITIONS — do not guess your way past these:
- If the slice hits a halt-and-ask / undecided PRD §11 item, STOP and report the
  exact decision needed. Never pick a default silently.
- If verification cannot be made green, STOP and report the failure with file:line.

Work ONLY on Slice {nn}. When it is Done, committed, and pushed, end your turn."""


def run_slice(slice_id, slice_file, model, api_key, verbose=False, heartbeat_secs=90):
    """Run one slice via a local Cursor SDK agent. Returns True if the run finished
    cleanly (status == 'finished'); raises on startup failure."""
    # Import lazily so --dry-run works without the SDK installed.
    from cursor_sdk import Agent, CursorAgentError, LocalAgentOptions, AgentOptions

    prompt = build_prompt(slice_id, slice_file)
    log(f"--- slice {slice_id:02d} coordinator run (model={model}) ---")
    log(f"slice file: {slice_file}")
    log("progress: tool/subagent lines below; heartbeat every 90s if idle (use --verbose for full agent text)")

    progress = RunProgress(verbose=verbose, heartbeat_secs=heartbeat_secs)
    t0 = time.time()

    try:
        with Agent.create(
            AgentOptions(
                api_key=api_key,
                model=model,
                local=LocalAgentOptions(cwd=REPO_ROOT),
            )
        ) as agent:
            run = agent.send(prompt)
            log(f"agent_id={getattr(agent, 'agent_id', '?')} run_id={getattr(run, 'id', '?')}")
            progress.start()
            for message in run.messages():
                progress.handle(message)
            result = run.wait()
            progress.stop()
            if verbose:
                print()
            elapsed = int(time.time() - t0)
            status = getattr(result, "status", "unknown")
            log(f"run finished: status={status} elapsed={elapsed}s")
            return status == "finished"
    except CursorAgentError as err:
        progress.stop()
        log(
            f"STARTUP FAILURE: {err} (retryable={getattr(err, 'is_retryable', '?')})"
        )
        raise SystemExit(EXIT_STARTUP)


def describe(decision):
    action = decision.get("action")
    if action == "start":
        return f"start slice {decision['id']:02d} ({decision['file']})"
    if action == "halt":
        return f"HALT at slice {decision['id']:02d} — {decision.get('reason', '')}"
    if action == "wait":
        return f"WAIT — slice {decision['id']:02d} blocked by {decision.get('blocked_by')}"
    if action == "done":
        return "DONE — queue complete"
    return f"unknown action: {decision}"


def main():
    parser = argparse.ArgumentParser(description="Run PodWash slices to Done, sequentially, locally.")
    parser.add_argument("--max", type=int, default=6,
                        help="max slices to run this session (default 6; safety cap)")
    parser.add_argument("--model", default="composer-2.5",
                        help="coordinator model (default composer-2.5; 'auto' lets the server pick)")
    parser.add_argument("--dry-run", action="store_true",
                        help="show the next decision and exit without spawning any agent")
    parser.add_argument("--verbose", action="store_true",
                        help="also stream the coordinator's full assistant text (noisy)")
    parser.add_argument("--heartbeat", type=int, default=90, metavar="SECS",
                        help="idle heartbeat interval in seconds (0 to disable; default 90)")
    args = parser.parse_args()

    if args.dry_run:
        decision = query_next()
        log(f"dry-run: next action -> {describe(decision)}")
        return EXIT_OK

    api_key = os.environ.get("CURSOR_API_KEY")
    if not api_key:
        log("CURSOR_API_KEY is not set. Export it before running (see the SDK docs).")
        return EXIT_STARTUP

    ran = 0
    last_started = None
    while ran < args.max:
        decision = query_next()
        action = decision.get("action")

        if action == "done":
            log("queue complete — no eligible slices remaining.")
            return EXIT_OK
        if action == "wait":
            log(describe(decision))
            log("Finish the blocking slice(s), then re-run the loop.")
            return EXIT_WAIT
        if action == "halt":
            log(describe(decision))
            log("Resolve the decision with the user (record in PRD/ADR), then re-run.")
            return EXIT_HALT
        if action != "start":
            log(f"unexpected decision, stopping: {decision}")
            return EXIT_RUN_FAILED

        slice_id = decision["id"]
        slice_file = decision["file"]

        # No-progress guard: if we already ran this exact slice and it's being
        # offered again, it never reached Done — stop rather than spin.
        if last_started == slice_id:
            log(f"slice {slice_id:02d} did not reach Done after its run — stopping to avoid a loop.")
            return EXIT_RUN_FAILED
        last_started = slice_id

        finished = run_slice(
            slice_id, slice_file, args.model, api_key,
            verbose=args.verbose, heartbeat_secs=args.heartbeat,
        )
        if not finished:
            log(f"slice {slice_id:02d} run did not finish cleanly — stopping.")
            return EXIT_RUN_FAILED

        # Authoritative progress check: only advance if next-slice.sh confirms
        # this slice is no longer the 'start' target (i.e. it flipped to Done).
        after = query_next()
        if after.get("action") == "start" and after.get("id") == slice_id:
            log(f"slice {slice_id:02d} still not Done per next-slice.sh (verify not green / status not flipped) — stopping.")
            return EXIT_RUN_FAILED

        ran += 1
        log(f"slice {slice_id:02d} complete. ({ran}/{args.max} this session)")

    log(f"reached --max {args.max} slices for this session. Re-run to continue.")
    return EXIT_OK


if __name__ == "__main__":
    sys.exit(main())
