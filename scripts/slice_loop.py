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
  Opus 4.8; PM, UX, QA on Composer 2.5.
- Definition of Done (all required): full `scripts/verify.sh` suite green
  (exit 0, 0 failed, 0 skipped), the `VERIFY RESULT:` line recorded in the slice
  file's verification record, the slice Status set to Done, an auto-commit
  `slice-{nn}: <short description>` made, then pushed to the remote.

STOP CONDITIONS — do not guess your way past these:
- If the slice hits a halt-and-ask / undecided PRD §11 item, STOP and report the
  exact decision needed. Never pick a default silently.
- If verification cannot be made green, STOP and report the failure with file:line.

Work ONLY on Slice {nn}. When it is Done, committed, and pushed, end your turn."""


def run_slice(slice_id, slice_file, model, api_key):
    """Run one slice via a local Cursor SDK agent. Returns True if the run finished
    cleanly (status == 'finished'); raises on startup failure."""
    # Import lazily so --dry-run works without the SDK installed.
    from cursor_sdk import Agent, CursorAgentError, LocalAgentOptions, AgentOptions

    prompt = build_prompt(slice_id, slice_file)
    log(f"starting local coordinator agent for slice {slice_id:02d} (model={model})")

    try:
        with Agent.create(
            AgentOptions(
                api_key=api_key,
                model=model,
                local=LocalAgentOptions(cwd=REPO_ROOT),
            )
        ) as agent:
            run = agent.send(prompt)
            # Log identifiers immediately (SDK best practice) for later inspection.
            log(f"agent_id={getattr(agent, 'agent_id', '?')} run_id={getattr(run, 'id', '?')}")
            # Stream assistant text so progress is visible.
            for message in run.messages():
                if getattr(message, "type", None) == "assistant":
                    for block in getattr(message.message, "content", []):
                        if getattr(block, "type", None) == "text":
                            sys.stdout.write(block.text)
                            sys.stdout.flush()
            result = run.wait()
            print()
            status = getattr(result, "status", "unknown")
            log(f"run finished with status={status}")
            return status == "finished"
    except CursorAgentError as err:
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

        finished = run_slice(slice_id, slice_file, args.model, api_key)
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
