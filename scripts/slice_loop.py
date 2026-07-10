#!/usr/bin/env python3
"""PodWash slice loop — Phase 2 of the slice runner.

Runs eligible slices to Done, one after another, on the LOCAL machine (so
`scripts/verify.sh` has real Xcode + the iOS Simulator). It is a thin driver
around:

  1. `scripts/next-slice.sh --json`  — the dependency-aware "what's next?" brain.
  2. Orchestrator modes:
       - coordinator (legacy): one SDK coordinator for authoring; loop owns verify
         + bounded Engineer|QA fix workers (Phase 1).
       - pipeline: Python gate FSM + one visible SDK worker per gate (Phase 2+).

Verification honesty: the loop only advances when `next-slice.sh` confirms the
slice's status actually flipped to Done (with a green VERIFY RESULT). It never
trusts the agent's self-report, so a half-finished slice cannot advance the queue.

Stop conditions (never guessed around):
  - halt : the next slice is a halt-and-ask gate → a human must decide first.
  - wait : every remaining slice is blocked on an unfinished dependency.
  - done : the queue is complete.
  - a slice failed to reach Done (agent error or verify red) → stop, no spin.
  - thrash: fix/verify budget exhausted → exit 5 with explanation.
  - infra: bridge/DNS/sim death with no code change → exit 6 (retry-safe).

Usage:
  scripts/slice-loop.sh                 # run the queue until it stops (pipeline mode)
  scripts/slice-loop.sh --dry-run       # show what WOULD run; spawns no agents
  scripts/slice-loop.sh --max 3         # run at most 3 slices this session
  scripts/slice-loop.sh --model auto    # let the server pick the coordinator model
  scripts/slice-loop.sh --orchestrator coordinator  # legacy attended authoring LLM
  scripts/slice-loop.sh --orchestrator pipeline     # default — Python gate FSM
  scripts/slice-loop.sh --stream-timeout 0   # disable bridge stream idle cap (default)

Auth (non-dry-run): export CURSOR_API_KEY=cursor_...

Bridge timeouts: the Cursor SDK defaults to a 600s stream read timeout. Quiet
Engineer/verify stretches exceed that and surface as
`Bridge request timed out: ReadTimeout` even while work continues. This driver
disables that cap by default and retries retryable bridge errors.
"""

from __future__ import annotations

import argparse
import json
import os
import subprocess
import sys
import time

from slice_loop_progress import (
    DEFAULT_MAX_RED_VERIFIES,
    RunProgress,
    ThrashHalt,
    extract_slice_accomplishment,
    extract_slice_mission,
    read_slice_meta,
    read_verify_from_slice,
    slice_done_banner,
    slice_start_banner,
    verify_is_green,
)
from slice_pipeline import (
    DEFAULT_MAX_FIX_ATTEMPTS,
    FixBudget,
    InfraHalt,
    record_green_verify,
    run_pipeline_slice,
    run_post_coordinator_verify,
    should_loop_own_verify,
)

REPO_ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
NEXT_SLICE = os.path.join(REPO_ROOT, "scripts", "next-slice.sh")

# Exit codes (align with SDK skill's guidance).
EXIT_OK = 0            # queue done, or --max reached cleanly
EXIT_STARTUP = 1       # agent never started (auth/config/network)
EXIT_RUN_FAILED = 2    # agent ran but slice did not reach Done (or no progress)
EXIT_WAIT = 3          # blocked on an unfinished dependency
EXIT_HALT = 4          # halt-and-ask gate needs a user decision
EXIT_THRASH = 5        # red-verify / fix retry budget exhausted (anti-thrash)
EXIT_INFRA = 6         # bridge/DNS/sim death — retry-safe, attempt not burned

# SDK default stream timeout is 600s — too short for quiet verify/Engineer turns.
DEFAULT_STREAM_TIMEOUT = 0.0   # 0 / None => disable (httpx timeout=None)
DEFAULT_UNARY_TIMEOUT = 120.0
DEFAULT_BRIDGE_RETRIES = 3
DEFAULT_RETRY_BACKOFF_SECS = 5.0


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


def slice_status(slice_file: str, repo_root: str) -> str:
    """Return the Status cell value from a slice markdown table (or '')."""
    path = slice_file if os.path.isabs(slice_file) else os.path.join(repo_root, slice_file)
    try:
        with open(path, encoding="utf-8") as fh:
            for line in fh:
                if "| **Status** |" in line or "| **Status**|" in line:
                    parts = [p.strip() for p in line.strip().strip("|").split("|")]
                    if len(parts) >= 2:
                        return parts[1]
    except OSError:
        pass
    return ""


def build_prompt(slice_id, slice_file):
    """The coordinator kickoff prompt for one slice, run unattended.

    Phase 1c handoff: coordinator authors gates only — must NOT run verify.sh
    or grind fixes. The outer loop owns verification + fix workers.
    """
    nn = f"{slice_id:02d}"
    status = slice_status(slice_file, REPO_ROOT)
    resume_block = ""
    if status and status.lower() not in ("draft", "ready", ""):
        # In Progress / Verify / anything mid-flight — audit disk, don't restart gates.
        resume_block = f"""
**RESUME (status is `{status}` — do NOT restart from scratch):**
1. Immediately run `git status` and skim the slice file (Plan review record,
   VERIFY RESULT, Role artifacts, AC checkboxes) plus any `docs/slices/slice-{nn}-ux.md`
   / ADR already on disk.
2. Emit a short status note listing what is **already done** vs **remaining**, then
   continue from the first incomplete **authoring** gate only.
3. **Skip completed gates** — do not re-spawn PM/UX/Architect/QA-author if their
   artifacts already exist and match the slice deliverables. Re-run a plan review
   only when the Plan review record is still `(pending)` *and* no prior review
   outcome is recorded; if tests/ADR/UX already landed, prefer recording the review
   outcome (or a one-line "cleared on resume — artifacts present") over a full
   re-review.
4. Prefer jumping to Engineer for remaining implement work when tests already exist.
   Never rewrite green tests or wipe working app code to "start clean."
5. **Do NOT run verify.sh / xcodebuild test.** The outer slice-loop owns verify
   and will spawn visible Engineer/QA fix workers on red.
"""

    return f"""You are the PodWash Multitask COORDINATOR, running unattended via the slice loop.

First, load the process and gates by reading:
- .cursor/rules/podwash-coordinator.mdc
- docs/multitask-workflow.md
- {slice_file}
{resume_block}
Then run Slice {nn} **authoring gates only** per that slice file:
- Enforce: PM story, Architect/UX design (if the slice adds modules or UI),
  plan reviews, QA test spec, Engineer implementation.
- You are the **orchestrator only**. **Spawn subagents for all authoring work** — delegate
  by name: `podwash-pm`, `podwash-ux`, `podwash-qa`, `podwash-architect`, `podwash-engineer`
  (models pinned in `.cursor/agents/`). If using Task `model`: PM/UX/QA → `composer-2.5`;
  Architect/Engineer → `grok-4.5` or subagent names. Never `composer-2.5-fast` or
  `grok-4.5-fast-xhigh`.

**MUST NOT edit yourself (spawn the subagent instead):**
- `PodWash/PodWash/**` → `podwash-engineer`
- `PodWash/PodWashTests/**` or `PodWash/PodWashUITests/**` → `podwash-qa`
- `docs/adr/**` → `podwash-architect`
Do not fix failing tests or simulator crashes by editing Swift/tests directly — spawn
Engineer or QA. You may edit `docs/slices/slice-{nn}-*.md` for status, verification
record, and plan-review lines only.

**HANDOFF CONTRACT (mandatory — Phase 1c):**
- **Do NOT run** `scripts/verify.sh` or `xcodebuild … test`. The outer loop owns
  verification as the source of truth.
- **Do NOT grind fixes** after implement. When implement artifacts exist (or status
  is Verify), **end your turn**. The loop will run verify and spawn visible
  Engineer/QA fix workers with a bounded retry budget.
- **Never** spawn UX/PM/Architect to fix test failures (UX is spec-only).

**Anti-cheat (mandatory):**
- Never commit app (`PodWash/PodWash/**`) and tests
  (`PodWash/{{PodWashTests,PodWashUITests,PodWashSlowTests}}/**`) in the same
  commit. Prefer `slice-{nn}: test spec` then `slice-{nn}: implement`. The outer
  loop may own final commits after green verify.

- When authoring is complete (implement on disk), set Status to **Verify** if you
  touch status, then **end your turn** so the loop can verify.

STOP CONDITIONS — do not guess your way past these:
- If the slice hits a halt-and-ask / undecided PRD §11 item, STOP and report the
  exact decision needed. Never pick a default silently.

Work ONLY on Slice {nn}. When authoring gates are done, end your turn."""


def resolve_stream_timeout(secs: float | None) -> float | None:
    """Map CLI/env seconds to an httpx timeout value.

    ``0`` or ``None`` disables the stream idle cap (required for long quiet
    verify/Engineer stretches). Positive values are seconds.
    """
    if secs is None or secs <= 0:
        return None
    return float(secs)


def should_retry_bridge_error(err: BaseException, attempt: int, max_retries: int) -> bool:
    """True when a bridge error is retryable and attempts remain.

    Retries CursorAgentError when ``is_retryable`` is set, and also the
    cursor-sdk dash-prefixed callback-token argv parse failure (see
    ``cursor_bridge``).
    """
    if attempt >= max_retries:
        return False
    try:
        from cursor_bridge import is_dash_prefixed_token_argv_error
    except ImportError:
        is_dash_prefixed_token_argv_error = lambda _e: False  # noqa: E731
    if is_dash_prefixed_token_argv_error(err):
        return True
    return bool(getattr(err, "is_retryable", False))


def retry_sleep_secs(err: BaseException, attempt: int, default: float = DEFAULT_RETRY_BACKOFF_SECS) -> float:
    """Honor ``retry_after`` when present; otherwise exponential backoff."""
    raw = getattr(err, "retry_after", None)
    if raw is not None:
        try:
            return max(0.0, float(raw))
        except (TypeError, ValueError):
            pass
    return default * (2 ** max(0, attempt - 1))


def run_slice_coordinator(
    slice_id,
    slice_file,
    model,
    api_key,
    verbose=False,
    heartbeat_secs=90,
    stream_timeout=DEFAULT_STREAM_TIMEOUT,
    unary_timeout=DEFAULT_UNARY_TIMEOUT,
    bridge_retries=DEFAULT_BRIDGE_RETRIES,
    max_red_verifies=DEFAULT_MAX_RED_VERIFIES,
    max_fix_attempts=DEFAULT_MAX_FIX_ATTEMPTS,
    spawn_fix_workers=True,
    record_on_green=True,
):
    """Legacy coordinator path + loop-owned verify/fix (Phase 1).

    Returns (finished: bool, elapsed_secs: int, last_verify: dict|None).
    Raises SystemExit on unrecoverable bridge/agent failure or thrash halt.
    """
    from cursor_sdk import (
        AgentOptions,
        CursorAgentError,
        LocalAgentOptions,
    )
    from cursor_sdk.errors import CursorSDKError

    from cursor_bridge import launch_bridge as launch_cursor_bridge
    from sdk_models import format_sdk_model, sdk_model_from_id

    title, _rel = read_slice_meta(slice_file, REPO_ROOT)
    mission = extract_slice_mission(slice_file, REPO_ROOT)
    print(slice_start_banner(slice_id, title, slice_file, mission=mission), flush=True)

    prompt = build_prompt(slice_id, slice_file)
    stream_to = resolve_stream_timeout(stream_timeout)
    sdk_model = sdk_model_from_id(model)
    # Budget persists across bridge retries (Phase 1b).
    fix_budget = FixBudget(max_attempts=max_fix_attempts)

    log(f"coordinator run (model={format_sdk_model(sdk_model)})")
    log(
        "bridge timeouts: "
        f"stream={'disabled' if stream_to is None else f'{stream_to:.0f}s'} "
        f"unary={unary_timeout:.0f}s retries={bridge_retries}"
    )
    log(
        f"anti-thrash: loop-owned verify; halt after {max_fix_attempts} fix "
        f"attempts (legacy shell red budget={max_red_verifies})"
    )
    log("progress lines: [slice NN][Role Name] action — use --verbose for full agent text")
    log("handoff: coordinator must NOT run verify.sh — loop owns verify + fix workers")

    progress = RunProgress(
        slice_id,
        title,
        slice_file,
        log,
        verbose=verbose,
        heartbeat_secs=heartbeat_secs,
        repo_root=REPO_ROOT,
        max_red_verifies=max_red_verifies,
    )
    t0 = time.time()
    attempt = 0
    last_verify = None

    while True:
        attempt += 1
        try:
            with launch_cursor_bridge(workspace=REPO_ROOT) as bridge_client:
                client = bridge_client.with_options(
                    stream_timeout=stream_to,
                    unary_timeout=unary_timeout,
                )
                with client.create_agent(
                    AgentOptions(
                        api_key=api_key,
                        model=sdk_model,
                        local=LocalAgentOptions(cwd=REPO_ROOT),
                    )
                ) as agent:
                    run = agent.send(prompt)
                    log(
                        f"agent_id={getattr(agent, 'agent_id', '?')} "
                        f"run_id={getattr(run, 'id', '?')} attempt={attempt}"
                    )
                    progress.start()
                    try:
                        for message in run.messages():
                            progress.handle(message)
                        result = run.wait()
                    except ThrashHalt as thrash:
                        progress.stop()
                        log(f"THRASH HALT: {thrash.reason}")
                        raise SystemExit(EXIT_THRASH) from thrash
                    progress.stop()
                    if verbose:
                        print()
                    status = getattr(result, "status", "unknown")
                    log(f"coordinator finished: status={status}")

                # Phase 1: loop owns verify (+ fix workers) AFTER coordinator agent
                # is disposed — sequential only; never parallel with authoring verify.
                if should_loop_own_verify(slice_file, REPO_ROOT):
                    def progress_factory(role: str, agent_name: str | None = None):
                        return RunProgress(
                            slice_id,
                            title,
                            slice_file,
                            log,
                            verbose=verbose,
                            heartbeat_secs=heartbeat_secs,
                            repo_root=REPO_ROOT,
                            max_red_verifies=max_red_verifies,
                            forced_role=role,
                            agent_name=agent_name,
                            fix_worker=role in ("Engineer", "QA"),
                        )

                    try:
                        outcome = run_post_coordinator_verify(
                            client,
                            slice_file=slice_file,
                            repo_root=REPO_ROOT,
                            api_key=api_key,
                            budget=fix_budget,
                            log=log,
                            progress_factory=progress_factory,
                            spawn_workers=spawn_fix_workers,
                        )
                    except ThrashHalt as thrash:
                        log(f"THRASH HALT: {thrash.reason}")
                        raise SystemExit(EXIT_THRASH) from thrash
                    last_verify = outcome.result
                    if outcome.green and outcome.result and record_on_green:
                        record_green_verify(slice_file, REPO_ROOT, outcome.result)
                        log("recorded VERIFY RESULT + Status Done (loop-owned)")
                else:
                    last_verify = progress.last_verify
                    log(
                        "skip loop-owned verify — implement not ready; "
                        "coordinator may still be mid-authoring"
                    )

                elapsed = int(time.time() - t0)
                log(f"slice attempt done: elapsed={elapsed}s")
                return status == "finished", elapsed, last_verify, {}
        except SystemExit:
            raise
        except (CursorAgentError, CursorSDKError) as err:
            progress.stop()
            retryable = should_retry_bridge_error(err, attempt, bridge_retries)
            log(
                f"BRIDGE FAILURE: {err} "
                f"(retryable={getattr(err, 'is_retryable', '?')} "
                f"attempt={attempt}/{bridge_retries})"
            )
            if not retryable:
                raise SystemExit(EXIT_STARTUP)
            sleep_for = retry_sleep_secs(err, attempt)
            log(f"retrying slice {slice_id:02d} in {sleep_for:.0f}s (fix budget preserved)")
            time.sleep(sleep_for)
            # Fresh RunProgress labels; FixBudget intentionally NOT reset.
            progress = RunProgress(
                slice_id,
                title,
                slice_file,
                log,
                verbose=verbose,
                heartbeat_secs=heartbeat_secs,
                repo_root=REPO_ROOT,
                max_red_verifies=max_red_verifies,
            )


def run_slice(
    slice_id,
    slice_file,
    model,
    api_key,
    verbose=False,
    heartbeat_secs=90,
    stream_timeout=DEFAULT_STREAM_TIMEOUT,
    unary_timeout=DEFAULT_UNARY_TIMEOUT,
    bridge_retries=DEFAULT_BRIDGE_RETRIES,
    max_red_verifies=DEFAULT_MAX_RED_VERIFIES,
    max_fix_attempts=DEFAULT_MAX_FIX_ATTEMPTS,
    orchestrator="pipeline",
    do_commit=True,
    do_push=True,
    coordinator_name=None,
    session_voice=None,
):
    """Run one slice via the selected orchestrator.

    Returns ``(finished, elapsed, last_verify, meta)``.
    """
    if orchestrator == "pipeline":
        if verbose:
            log("orchestrator=pipeline (gate FSM)")
        try:
            return run_pipeline_slice(
                slice_id,
                slice_file,
                api_key=api_key,
                repo_root=REPO_ROOT,
                log=log,
                verbose=verbose,
                heartbeat_secs=heartbeat_secs,
                stream_timeout=stream_timeout,
                unary_timeout=unary_timeout,
                max_fix_attempts=max_fix_attempts,
                do_commit=do_commit,
                do_push=do_push,
                progress_cls=RunProgress,
                coordinator_name=coordinator_name,
                session_voice=session_voice,
            )
        except InfraHalt as infra:
            log(f"INFRA HALT (exit={EXIT_INFRA}): {infra.reason}")
            raise SystemExit(EXIT_INFRA) from infra
        except ThrashHalt as thrash:
            log(f"THRASH HALT: {thrash.reason}")
            raise SystemExit(EXIT_THRASH) from thrash

    return run_slice_coordinator(
        slice_id,
        slice_file,
        model,
        api_key,
        verbose=verbose,
        heartbeat_secs=heartbeat_secs,
        stream_timeout=stream_timeout,
        unary_timeout=unary_timeout,
        bridge_retries=bridge_retries,
        max_red_verifies=max_red_verifies,
        max_fix_attempts=max_fix_attempts,
    )


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
                        help="coordinator model (default composer-2.5; never composer-2.5-fast)")
    parser.add_argument("--dry-run", action="store_true",
                        help="show the next decision and exit without spawning any agent")
    parser.add_argument("--verbose", action="store_true",
                        help="also stream the coordinator's full assistant text (noisy)")
    parser.add_argument("--heartbeat", type=int, default=90, metavar="SECS",
                        help="idle heartbeat interval in seconds (0 to disable; default 90)")
    parser.add_argument(
        "--stream-timeout",
        type=float,
        default=DEFAULT_STREAM_TIMEOUT,
        metavar="SECS",
        help="bridge stream idle timeout in seconds (0=disable, default 0; SDK default is 600)",
    )
    parser.add_argument(
        "--unary-timeout",
        type=float,
        default=DEFAULT_UNARY_TIMEOUT,
        metavar="SECS",
        help=f"bridge unary RPC timeout in seconds (default {DEFAULT_UNARY_TIMEOUT:.0f})",
    )
    parser.add_argument(
        "--bridge-retries",
        type=int,
        default=DEFAULT_BRIDGE_RETRIES,
        metavar="N",
        help=f"retry attempts on retryable bridge errors (default {DEFAULT_BRIDGE_RETRIES})",
    )
    parser.add_argument(
        "--max-red-verifies",
        type=int,
        default=DEFAULT_MAX_RED_VERIFIES,
        metavar="N",
        help=(
            "legacy: halt coordinator shell thrash after N red verify/xcodebuild "
            f"outcomes (default {DEFAULT_MAX_RED_VERIFIES})"
        ),
    )
    parser.add_argument(
        "--max-fix-attempts",
        type=int,
        default=DEFAULT_MAX_FIX_ATTEMPTS,
        metavar="N",
        help=(
            "loop-owned Engineer|QA fix budget after red verify "
            f"(default {DEFAULT_MAX_FIX_ATTEMPTS})"
        ),
    )
    parser.add_argument(
        "--orchestrator",
        choices=("coordinator", "pipeline"),
        default="pipeline",
        help=(
            "pipeline = Python gate FSM + one SDK worker per gate (default, unattended); "
            "coordinator = legacy authoring LLM + loop-owned verify (attended)"
        ),
    )
    parser.add_argument(
        "--no-commit",
        action="store_true",
        help="pipeline mode: skip split commits + push after green verify",
    )
    parser.add_argument(
        "--no-push",
        action="store_true",
        help="pipeline mode: commit but do not push",
    )
    args = parser.parse_args()
    if args.dry_run:
        decision = query_next()
        log(f"dry-run: next action -> {describe(decision)}")
        log(f"dry-run: orchestrator={args.orchestrator}")
        return EXIT_OK

    api_key = os.environ.get("CURSOR_API_KEY")
    if not api_key:
        log("CURSOR_API_KEY is not set. Export it before running (see the SDK docs).")
        return EXIT_STARTUP

    from factory_narrator import (
        NameAssigner,
        StoryVoice,
        format_coordinator_report,
    )

    session_voice = StoryVoice()
    session_names = NameAssigner()
    coordinator = session_names.assign("Coordinator", slot="session")

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

        finished, elapsed, last_verify, run_meta = run_slice(
            slice_id,
            slice_file,
            args.model,
            api_key,
            verbose=args.verbose,
            heartbeat_secs=args.heartbeat,
            stream_timeout=args.stream_timeout,
            unary_timeout=args.unary_timeout,
            bridge_retries=args.bridge_retries,
            max_red_verifies=args.max_red_verifies,
            max_fix_attempts=args.max_fix_attempts,
            orchestrator=args.orchestrator,
            do_commit=not args.no_commit,
            do_push=not args.no_push,
            coordinator_name=coordinator,
            session_voice=session_voice,
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
        title, _rel = read_slice_meta(slice_file, REPO_ROOT)
        verify = read_verify_from_slice(slice_file, REPO_ROOT) or last_verify
        green = verify_is_green(verify)
        mission = extract_slice_mission(slice_file, REPO_ROOT)
        accomplishment = (
            extract_slice_accomplishment(slice_file, REPO_ROOT) if green else None
        )
        meta = run_meta or {}
        print(
            slice_done_banner(
                slice_id,
                title,
                verify,
                elapsed,
                session=(ran, args.max),
                accomplishment=accomplishment,
            ),
            flush=True,
        )
        report = format_coordinator_report(
            coordinator_name=coordinator,
            slice_id=slice_id,
            title=title,
            elapsed_secs=elapsed,
            green=green,
            mission=mission,
            accomplishment=accomplishment,
            cast_names=meta.get("cast_names"),
            murphy_visits=int(meta.get("murphy_visits") or 0),
            verify=verify,
            session=(ran, args.max),
            voice=session_voice,
        )
        print(report, flush=True)

    log(f"reached --max {args.max} slices for this session. Re-run to continue.")
    return EXIT_OK


if __name__ == "__main__":
    sys.exit(main())
