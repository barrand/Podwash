#!/usr/bin/env python3
"""Factory v3 — unified Mechanic fix cycle (tier-2 gate + full-suite).

One worker, progress-based stopping, no role routing. See
docs/plans/factory-v3-mechanic.md.
"""

from __future__ import annotations

import time
from typing import Any, Callable, Literal, Optional

from failure_packet import (
    FailurePacket,
    build_failure_packet,
    extract_artifact_regeneration_hint,
    extract_slice_swift_paths,
    format_stuck_card,
    is_flake_signal,
    persist_stuck_card,
    slice_id_from_path,
)
from factory_events import EventLog, parse_summary_line
from factory_narrator import (
    CastLog,
    NameAssigner,
    narrate_chapter_open,
    narrate_crash,
    narrate_exoneration,
    narrate_failure_detail,
    narrate_flake_confirmed,
    narrate_hard_cap_halt,
    narrate_role_report,
    narrate_thrash_halt,
    narrate_worker_done,
)
from factory_progress import (
    DEFAULT_MAX_MECHANIC_SPAWNS,
    ProgressTracker,
    hard_cap_console_line,
    hard_cap_halt_message,
    hard_cap_stuck_line,
    is_harness_delta,
    make_failure_signature,
    needs_adr_diff_review,
    needs_test_diff_review,
    thrash_halt_message,
)
from fix_lanes import (
    classify_fix_lane,
    extract_adr_citation_hint,
    format_attempt_note,
    git_delta_with_fingerprints,
    snapshot_path_fingerprints,
    suggested_files_for_lane,
)
from hypothesis_ledger import (
    append_ledger,
    format_ledger_for_prompt,
    load_ledger,
    make_entry,
)
from session_bundle import write_session_bundle
from sim_hygiene import (
    CrashWatchdog,
    classify_infra_failure,
    default_ips_roots,
    should_stress_run,
    stress_run_count,
)
from slice_loop_progress import (
    ThrashHalt,
    _read_slice_text,
    latest_xcresult_path,
)

LogFn = Callable[[str], None]
VerifyTier = Literal[2, 3]


def _mechanic_signature(outcome: Any, *, stress_flake: bool = False) -> str:
    from slice_pipeline import is_build_lane, outcome_failure_class

    packet = getattr(outcome, "packet", None)
    test_ids: list[str] = []
    if packet is not None:
        test_ids = list(packet.test_ids or [])
    failures = list(getattr(outcome, "failures", None) or [])
    if not test_ids and failures:
        test_ids = list(failures)
    cls = outcome_failure_class(outcome) if outcome is not None else "unknown"
    if is_build_lane(outcome):
        cls = "build"
    return make_failure_signature(
        test_ids=test_ids,
        failures=failures,
        failure_class=cls,
        stress_flake=stress_flake,
    )


def build_mechanic_prompt(
    slice_file: str,
    failures: list[str],
    crashes: list[str],
    bundle: str | None,
    attempt: int,
    max_attempts: int,
    *,
    packet: FailurePacket | None = None,
    stuck_card: str = "",
    lane_instruction: str = "",
    lane_hypothesis: str = "",
    attempt_notes: list[str] | None = None,
    suggested_files: list[str] | None = None,
    ledger_block: str = "",
    primary_failure: str = "",
    stress_flake_recipe: bool = False,
) -> str:
    """Prompt for the single Mechanic worker (app + tests + ADRs)."""
    from slice_pipeline import load_persona

    persona = load_persona("Engineer")  # Engineer-class model; expanded scope below
    fail_lines = "\n".join(f"- {f}" for f in (failures or ["(unknown failure)"]))
    crash_lines = "\n".join(f"- {c}" for c in crashes) if crashes else "(none)"
    bundle_line = bundle or "(none — check build/test-results/)"
    card_block = stuck_card.strip() or "(no stuck card)"
    instruction = lane_instruction or (
        "(no lane hint — diagnose from FailurePacket; fix whatever is broken)"
    )
    if stress_flake_recipe:
        instruction = (
            "STRESS FLAKE recipe: the test flipped green then failed a stress "
            "re-run. Make this test deterministic — hermetic waits, re-resolved "
            "queries, no coordinate taps. Do not weaken AC thresholds."
        )
    files = suggested_files or (packet.suggested_files if packet else [])
    files_block = ", ".join(files) if files else "(none suggested)"
    history = ""
    if attempt_notes:
        history = "Attempt history:\n" + "\n".join(f"- {n}" for n in attempt_notes)
    ledger = ledger_block or "(empty — log only; do not halt on repeats)"
    hyp = lane_hypothesis or (packet.hypothesis if packet else "") or "(none)"
    primary = primary_failure or "(see failing tests)"
    assertions_block = ""
    if packet and packet.assertions:
        assertions_block = "Failing assertions:\n" + "\n".join(
            f"- {a}" for a in packet.assertions[:8]
        )
    packet_block = ""
    if packet:
        packet_block = f"""
FailurePacket:
- class hint: {packet.failure_class}
- signature: {packet.signature}
- test_ids: {packet.test_ids}
- assertions: {packet.assertions}
- failed_queries: {packet.failed_queries}
- hypothesis: {packet.hypothesis or "(none)"}
- hierarchy_excerpt:
{packet.hierarchy_excerpt[:2500]}
"""
    return f"""{persona}

You are the **Mechanic** for PodWash (fix cycle {attempt}/{max_attempts}).
You own the entire fix in one session — app, tests, fixtures, and ADRs as needed.
Slice file: {slice_file}

**Edit scope:** You MAY edit:
- PodWash/PodWash/** (app)
- PodWash/{{PodWashTests,PodWashUITests,PodWashSlowTests}}/** + fixtures
- docs/adr/** when the failure is an ADR citation / benchmark table gap

Do NOT run scripts/verify.sh or `xcodebuild … test` — the outer loop owns verification.
Do NOT weaken assertions, thresholds, or goldens. Do NOT XCTSkip a core AC.
Do NOT delete tests to go green.

Optional lane hint (you may ignore if wrong):
{instruction}

Primary failure: {primary}
Hypothesis hint: {hyp}

Stuck card:
{card_block}

Failing tests:
{fail_lines}

Crashes:
{crash_lines}

Bundle: {bundle_line}
Suggested files (hints): {files_block}
{assertions_block}
{packet_block}
{history}

Hypothesis ledger (audit log only — never treat as a halt):
{ledger}

End with a single line:
SUMMARY: <what you changed and why>
"""


def parse_review_verdict(text: str) -> bool:
    """True if readonly review cleared (blocker/clear). Default clear if empty."""
    low = (text or "").lower()
    if "blocker" in low and "clear" not in low.split("blocker", 1)[-1][:40]:
        # Explicit blocker without nearby clear
        if re_search_blocker(low):
            return False
    if "verdict: blocker" in low or "status: blocker" in low:
        return False
    if "verdict: clear" in low or "status: clear" in low or "cleared" in low:
        return True
    if "blocker" in low:
        return False
    return True


def re_search_blocker(low: str) -> bool:
    import re

    return bool(re.search(r"\bblocker\b", low))


def run_diff_review(
    client: Any,
    *,
    kind: Literal["test", "adr"],
    paths: list[str],
    slice_file: str,
    api_key: str,
    repo_root: str,
    log: LogFn | None = None,
    progress_factory: Callable[..., Any] | None = None,
) -> bool:
    """Readonly QA (tests) or Architect (ADR) review. Returns True if cleared."""
    from slice_pipeline import run_worker

    _log = log or (lambda m: None)
    role = "QA review" if kind == "test" else "Architect review"
    prompt = f"""Readonly {kind}-diff review for PodWash Mechanic fixes.
Slice: {slice_file}
Changed paths:
{chr(10).join(f'- {p}' for p in paths[:40])}

Report exactly one verdict line:
VERDICT: clear
or
VERDICT: blocker — <reason>

For test diffs: block if assertions/thresholds/goldens were weakened, XCTSkip
added on a core AC, or tests deleted to pass. Clear if changes are legitimate
harness/fixture fixes.
For ADR diffs: block if benchmark numbers look invented or AC mapping was
bent. Clear if numbers match committed fixtures.
Do not edit files. Do not run verify.
"""
    if client is None:
        _log(f"{kind}-diff review skipped (no client) — treating as clear")
        return True
    progress = progress_factory(role, role) if progress_factory else None
    _ok, _status = run_worker(
        client,
        role=role,
        prompt=prompt,
        api_key=api_key,
        repo_root=repo_root,
        log=_log,
        progress=progress,
    )
    text = ""
    if progress is not None and hasattr(progress, "assistant_text"):
        text = progress.assistant_text or ""
    cleared = parse_review_verdict(text)
    _log(f"{kind}-diff review: {'clear' if cleared else 'blocker'}")
    return cleared


def commit_mechanic_deltas(
    slice_id: int,
    repo_root: str,
    paths: list[str],
    *,
    log: LogFn | None = None,
) -> bool:
    """Split-commit Mechanic deltas: tests → app → adr/other. Never mixed."""
    from slice_pipeline import check_test_isolation, run_git

    from factory_progress import classify_fix_paths

    _log = log or (lambda m: None)
    nn = f"{slice_id:02d}"
    tests, apps, adrs, other = classify_fix_paths(paths)
    if not (tests or apps or adrs or other):
        return True

    def stage_and_commit(files: list[str], message: str) -> bool:
        if not files:
            return True
        _log(f"commit: staging {len(files)} path(s) for {message!r}")
        if run_git(repo_root, ["add", "--", *files], log=_log) != 0:
            return False
        if not check_test_isolation(repo_root, staged=True, log=_log):
            _log("check-test-isolation.sh --staged FAILED — aborting commit sequence")
            run_git(repo_root, ["reset", "HEAD"], log=_log)
            return False
        return run_git(repo_root, ["commit", "-m", message], log=_log) == 0

    for batch, message in (
        (tests, f"slice-{nn}: fix tests"),
        (apps, f"slice-{nn}: fix app"),
        (adrs + other, f"slice-{nn}: fix docs"),
    ):
        if not batch:
            continue
        if not stage_and_commit(batch, message):
            return False
    return True


def run_fix_cycle(
    client: Any,
    *,
    slice_file: str,
    repo_root: str,
    api_key: str,
    gate_tier: VerifyTier = 3,
    tracker: ProgressTracker | None = None,
    log: LogFn | None = None,
    progress_factory: Callable[..., Any] | None = None,
    verify_fn: Callable[..., Any] | None = None,
    event_log: EventLog | None = None,
    names: NameAssigner | None = None,
    cast: CastLog | None = None,
    max_infra_retries: int = 2,
    write_tier2_marker_on_green: bool = False,
) -> Any:
    """Unified Mechanic fix loop for tier-2 implement gate or full-suite verify.

    Raises ThrashHalt / InfraHalt. Returns green VerifyOutcome.
    """
    # Lazy imports avoid circular dependency at module load.
    from slice_pipeline import (
        InfraHalt,
        VerifyOutcome,
        _collect_ips_summaries,
        _log_stuck_card_path,
        _narrate_verify_failure,
        _report_verify_green,
        _tier2_curated_blob,
        _tier2_failure_blob,
        git_paths_changed,
        is_build_lane,
        is_factory_config_lane,
        is_tier2_infra_failure,
        run_verify,
        run_worker,
        test_ids_for_tier1,
        write_tier2_marker,
    )

    _log = log or (lambda m: None)
    _names = names or NameAssigner()
    _cast = cast if cast is not None else CastLog()
    _voice = _cast.voice
    _events = event_log
    _stuck_printed: set[str] = set()
    sid = slice_id_from_path(slice_file) or 0
    progress = tracker or ProgressTracker(max_spawns=DEFAULT_MAX_MECHANIC_SPAWNS)
    progress.start(time.time())

    _verify = verify_fn or (
        lambda **kw: run_verify(repo_root, log=_log, slice_file=slice_file, **kw)
    )

    def _do_verify(**kwargs: Any) -> VerifyOutcome:
        if "tier" not in kwargs:
            kwargs = {**kwargs, "tier": gate_tier}
        # Verify wall clock must not burn the Mechanic minute budget (slice 15).
        progress.pause_for_verify(time.time())
        try:
            try:
                return _verify(slice_file=slice_file, **kwargs)
            except TypeError:
                try:
                    return _verify(**kwargs)
                except TypeError:
                    return _verify()
        finally:
            progress.resume_after_verify(time.time())

    roots = []
    for r in default_ips_roots()[:2]:
        roots.append(r if os_path_join(repo_root, r) else r)
    watchdog = CrashWatchdog(roots=roots)
    watchdog.arm()

    phase = "TIER2-VERIFY" if gate_tier == 2 else "FULL-VERIFY"
    if _events:
        _events.record(
            phase,
            "loop",
            "verify_start",
            timeline=True,
            mission=f"tier {gate_tier}",
        )

    outcome = _do_verify(tier=gate_tier)
    if outcome.green:
        if gate_tier == 2 and write_tier2_marker_on_green:
            write_tier2_marker(repo_root, sid)
        if _events:
            _events.record(
                phase,
                "loop",
                "verify_end",
                detail={"tier": gate_tier, "exit": 0, "failed": 0},
            )
        _report_verify_green(
            client,
            "Quinn",
            outcome,
            role="QA",
            api_key=api_key,
            repo_root=repo_root,
            log=_log,
        )
        return outcome

    _narrate_verify_failure(
        "Quinn",
        outcome,
        repo_root=repo_root,
        log=_log,
        voice=_voice,
        cast=_cast,
    )
    fresh_ips = watchdog.new_crashes()
    if fresh_ips:
        narrate_crash(log=_log, voice=_voice)

    infra_retries = 0
    slice_text = ""
    try:
        slice_text = _read_slice_text(slice_file, repo_root)
    except OSError:
        slice_text = ""
    slice_files = extract_slice_swift_paths(slice_text)
    slice_id = slice_id_from_path(slice_file)
    ledger = load_ledger(repo_root, slice_id)
    stress_flake_mode = False

    while True:
        now = time.time()
        if progress.at_hard_cap(now) and progress.spawns_used > 0:
            _log(hard_cap_console_line(progress, now=now))
            _halt_exhausted(
                outcome,
                progress,
                slice_file=slice_file,
                repo_root=repo_root,
                slice_id=slice_id,
                log=_log,
                voice=_voice,
                cast=_cast,
                stuck_printed=_stuck_printed,
                reason="hard cap",
                halt_kind="hard_cap",
                now=now,
            )

        packet = outcome.packet or build_failure_packet(
            failures=outcome.failures,
            crashes=outcome.crashes,
            bundle=(outcome.result or {}).get("bundle"),
            exit_code=(outcome.result or {}).get("exit"),
            output=outcome.output,
            repo_root=repo_root,
            export_attachments=False,
        )
        if slice_files and not packet.suggested_files:
            packet = packet.with_updates(suggested_files=list(slice_files))

        if is_factory_config_lane(outcome):
            reason = (outcome.failures or ["factory_config: verify wiring"])[0]
            _log(
                "FACTORY CONFIG: refusing Mechanic — "
                + reason.replace("factory_config:", "").strip()[:160]
            )
            card = format_stuck_card(
                packet,
                slice_file=slice_file,
                attempt=progress.spawns_used,
                max_attempts=progress.max_spawns,
            )
            _log_stuck_card_path(
                card,
                repo_root=repo_root,
                slice_file=slice_file,
                log=_log,
                printed=_stuck_printed,
            )
            narrate_thrash_halt(log=_log, voice=_voice)
            raise ThrashHalt(reason)

        # Infra cold-retry (free)
        if (
            not is_build_lane(outcome)
            and is_tier2_infra_failure(outcome, log=_log)
            and not (packet.test_ids)
        ):
            if infra_retries < max_infra_retries:
                infra_retries += 1
                _log(
                    f"infra cold-retry {infra_retries}/{max_infra_retries} "
                    "(does not count as Mechanic spawn)"
                )
                outcome = _do_verify(tier=gate_tier)
                if outcome.green:
                    if gate_tier == 2 and write_tier2_marker_on_green:
                        write_tier2_marker(repo_root, sid)
                    return outcome
                continue
            from factory_narrator import narrate_infra_halt

            narrate_infra_halt(log=_log, voice=_voice)
            raise InfraHalt(
                f"infra failure after {infra_retries} cold retries: "
                f"{(outcome.failures or ['unknown'])[:2]}"
            )

        if not packet.actionable and not is_build_lane(outcome):
            card = format_stuck_card(
                packet,
                slice_file=slice_file,
                attempt=progress.spawns_used,
                max_attempts=progress.max_spawns,
            )
            _log_stuck_card_path(
                card,
                repo_root=repo_root,
                slice_file=slice_file,
                log=_log,
                printed=_stuck_printed,
            )
            narrate_thrash_halt(log=_log, voice=_voice)
            raise ThrashHalt(packet.halt_reason or "no actionable evidence")

        if (
            (is_flake_signal(packet) or packet.failure_class == "flake")
            and not progress.flake_cold_retried
            and not stress_flake_mode
        ):
            progress.flake_cold_retried = True
            _log("flake signal — cold re-verify (does not count as Mechanic spawn)")
            outcome = _do_verify(tier=gate_tier)
            if outcome.green:
                narrate_flake_confirmed(log=_log, voice=_voice)
                if gate_tier == 2 and write_tier2_marker_on_green:
                    write_tier2_marker(repo_root, sid)
                return outcome
            continue

        # Optional lane hint
        blob = _tier2_failure_blob(outcome)
        lane = classify_fix_lane(
            blob=blob,
            packet=packet,
            is_build=is_build_lane(outcome),
            escalate_expectation=progress.spawns_used >= 1,
        )
        lane_instruction = ""
        lane_hypothesis = packet.hypothesis or ""
        suggested = list(packet.suggested_files or slice_files)
        if lane is not None:
            _log(f"LANE HINT: {lane.lane_id} (optional — Mechanic may ignore)")
            if lane.lane_id == "artifact_fixture":
                hint = extract_artifact_regeneration_hint(blob)
                if hint:
                    _log(f"hint: {hint}")
            elif lane.lane_id == "adr_citation":
                _log(f"hint: {extract_adr_citation_hint(blob)}")
            lane_instruction = lane.instruction
            lane_hypothesis = lane.hypothesis
            suggested = suggested_files_for_lane(
                lane.lane_id, packet, slice_files
            ) or suggested

        ips = _collect_ips_summaries(repo_root)
        crashes = list(outcome.crashes or packet.crashes or [])
        for line in ips:
            if line not in crashes:
                crashes.append(line)

        attempt = progress.record_spawn()
        agent = _names.assign("Mechanic", slot=f"Mechanic-{attempt}")
        narrate_exoneration(
            cause=lane_hypothesis or lane_instruction or "Mechanic owns the fix",
            owner=agent,
            log=_log,
            voice=_voice,
        )
        narrate_chapter_open(
            slice_id=sid,
            gate_label="fix",
            role="Mechanic",
            name=agent,
            fix_attempt=attempt,
            fix_max=progress.max_spawns,
            log=_log,
            voice=_voice,
        )
        _cast.add("Mechanic", agent, f"fix-{attempt}")

        failed_ids = test_ids_for_tier1(packet, outcome.failures)
        pre_mechanic_build = is_build_lane(outcome)
        bundle = (outcome.result or {}).get("bundle") or latest_xcresult_path(
            repo_root
        )
        card = format_stuck_card(
            packet,
            slice_file=slice_file,
            attempt=attempt,
            max_attempts=progress.max_spawns,
            next_role="Mechanic",
            lever=lane_instruction[:120] if lane_instruction else "Mechanic",
            levers_tried=progress.levers_tried,
        )
        _log_stuck_card_path(
            card,
            repo_root=repo_root,
            slice_file=slice_file,
            log=_log,
            printed=_stuck_printed,
        )

        prompt = build_mechanic_prompt(
            slice_file,
            outcome.failures or packet.raw_failures,
            crashes,
            bundle,
            attempt,
            progress.max_spawns,
            packet=packet,
            stuck_card=card,
            lane_instruction=lane_instruction,
            lane_hypothesis=lane_hypothesis,
            attempt_notes=list(progress.attempt_notes),
            suggested_files=suggested,
            ledger_block=format_ledger_for_prompt(ledger),
            primary_failure=(outcome.failures or packet.raw_failures or ["(unknown)"])[
                0
            ],
            stress_flake_recipe=stress_flake_mode,
        )
        _log(
            f"Mechanic cycle {attempt}/{progress.max_spawns}: agent={agent} "
            f"failures={(outcome.failures or packet.raw_failures)[:3]}"
        )
        if client is None:
            raise ThrashHalt("no SDK client for Mechanic")
        if _events:
            _events.record(
                f"FIX-{attempt}",
                "Mechanic",
                "spawn",
                agent_name=agent,
                timeline=False,
                mission=(lane_instruction or "Mechanic fix")[:80],
            )

        worker_progress = (
            progress_factory("Mechanic", agent) if progress_factory else None
        )
        baseline = set(git_paths_changed(repo_root))
        baseline_fps = snapshot_path_fingerprints(repo_root, baseline)
        ok, status = run_worker(
            client,
            role="Mechanic",
            prompt=prompt,
            api_key=api_key,
            repo_root=repo_root,
            log=_log,
            progress=worker_progress,
        )
        after = set(git_paths_changed(repo_root))
        delta = git_delta_with_fingerprints(
            baseline,
            after,
            repo_root=repo_root,
            fingerprints_before=baseline_fps,
        )
        # Mechanic may touch anything in-scope — all delta counts
        in_scope = list(delta)
        if worker_progress is not None and hasattr(worker_progress, "_files_touched"):
            worker_progress._files_touched = list(in_scope)
        progress.merge_delta(in_scope)

        assistant = ""
        if worker_progress is not None and hasattr(worker_progress, "assistant_text"):
            assistant = worker_progress.assistant_text or ""
        summary = parse_summary_line(assistant) or ""
        if summary:
            narrate_worker_done(agent, summary, log=_log, voice=_voice)

        note = format_attempt_note(
            attempt=attempt,
            role="Mechanic",
            agent=agent,
            files=in_scope,
            summary=summary,
            hyp=lane_hypothesis,
            status=status,
        )
        progress.attempt_notes.append(note)
        progress.levers_tried.append(f"M{attempt}:{lane_hypothesis[:60]}")
        progress.last_hypothesis = lane_hypothesis
        if not ok:
            _log(f"Mechanic did not finish cleanly (status={status})")
            narrate_role_report(
                agent,
                f"didn't finish cleanly (status={status}) — verify still red.",
                log=_log,
                voice=_voice,
            )

        # Re-verify: tier-1 failed ids → optional stress → gate tier
        if failed_ids and not pre_mechanic_build:
            _log(f"tier-1 re-verify ({len(failed_ids)} failed tests)")
            outcome = _do_verify(tier=1, failed_tests=failed_ids)
        elif failed_ids and pre_mechanic_build:
            _log(
                "tier-1 skipped: build_error lane — no valid test ids "
                "(refusing bogus -only-testing:)"
            )
            outcome = _do_verify(tier=gate_tier)
        else:
            _log(f"tier-1 skipped (no test ids) — tier {gate_tier}")
            outcome = _do_verify(tier=gate_tier)

        stress_flake_mode = False
        if outcome.green and should_stress_run(failed_ids, just_fixed=True):
            n = stress_run_count(failed_ids, just_fixed=True)
            _log(f"stress-run policy: {n} consecutive tier-1 runs for UITest fix")
            for i in range(1, n):
                again = _do_verify(tier=1, failed_tests=failed_ids)
                if not again.green:
                    outcome = again
                    _log(f"stress-run {i + 1}/{n} red — stress_flake cycle")
                    stress_flake_mode = True
                    break
            else:
                _log(f"stress-run {n}/{n} green")

        if outcome.green:
            # Promote to gate tier if we only ran tier-1
            if gate_tier == 3:
                _log("tier-1 green — promoting to tier-3 full suite")
                outcome = _do_verify(tier=3)
            elif gate_tier == 2:
                outcome = _do_verify(tier=2)

        entry = make_entry(
            slice_id=slice_id,
            attempt=attempt,
            role="Mechanic",
            hypothesis=lane_hypothesis or "mechanic",
            signature=_mechanic_signature(outcome, stress_flake=stress_flake_mode)
            or _mechanic_signature(
                VerifyOutcome(
                    result=outcome.result,
                    green=False,
                    failures=outcome.failures or packet.raw_failures,
                    crashes=outcome.crashes,
                    packet=packet,
                )
            ),
            files_touched=in_scope,
            verify_tier=gate_tier if outcome.green else 1,
            outcome="green" if outcome.green else "red",
            primary_failure=(outcome.failures or ["(unknown)"])[0]
            if not outcome.green
            else "",
            instruction=lane_instruction[:200],
            agent_name=agent,
        )
        append_ledger(entry, repo_root=repo_root, slice_id=slice_id)
        ledger.append(entry)

        if outcome.green:
            cum = list(progress.cumulative_delta)
            review_blocked = False
            if needs_test_diff_review(cum):
                test_paths = [p for p in cum if needs_test_diff_review([p])]
                cleared = run_diff_review(
                    client,
                    kind="test",
                    paths=test_paths,
                    slice_file=slice_file,
                    api_key=api_key,
                    repo_root=repo_root,
                    log=_log,
                    progress_factory=progress_factory,
                )
                cont, line = progress.observe_review(cleared=cleared)
                _log(line)
                if progress.review_thrash():
                    narrate_thrash_halt(log=_log, voice=_voice)
                    raise ThrashHalt("test-diff review blocked twice — exit 5")
                if not cleared:
                    review_blocked = True
            if outcome.green and not review_blocked and needs_adr_diff_review(cum):
                adr_paths = [p for p in cum if needs_adr_diff_review([p])]
                cleared = run_diff_review(
                    client,
                    kind="adr",
                    paths=adr_paths,
                    slice_file=slice_file,
                    api_key=api_key,
                    repo_root=repo_root,
                    log=_log,
                    progress_factory=progress_factory,
                )
                cont, line = progress.observe_review(cleared=cleared)
                _log(line)
                if progress.review_thrash():
                    narrate_thrash_halt(log=_log, voice=_voice)
                    raise ThrashHalt("ADR-diff review blocked twice — exit 5")
                if not cleared:
                    review_blocked = True

            if review_blocked:
                outcome = VerifyOutcome(
                    green=False,
                    failures=["diff-review blocker — Mechanic must address"],
                    crashes=[],
                    result=outcome.result,
                    packet=packet,
                )
            else:
                if gate_tier == 2 and write_tier2_marker_on_green:
                    write_tier2_marker(repo_root, sid)
                _report_verify_green(
                    client,
                    agent,
                    outcome,
                    role="Mechanic",
                    api_key=api_key,
                    repo_root=repo_root,
                    log=_log,
                )
                return outcome

        # Progress / stress_flake observation — check thrash then hard-cap
        # *before* logging "continuing" so we never imply another cycle then halt.
        if stress_flake_mode:
            cont, line = progress.observe_stress_flake(
                had_harness_delta=is_harness_delta(in_scope)
            )
            sig = _mechanic_signature(outcome, stress_flake=True)
            progress.signature_history.append(sig)
            progress.last_signature = sig
            if not cont or progress.stress_flake_thrash():
                _log(line)
                narrate_thrash_halt(log=_log, voice=_voice)
                raise ThrashHalt(
                    thrash_halt_message(progress, last="stress-flake after green")
                )
            now_cap = time.time()
            if progress.at_hard_cap(now_cap):
                _log(hard_cap_console_line(progress, now=now_cap))
                _halt_exhausted(
                    outcome,
                    progress,
                    slice_file=slice_file,
                    repo_root=repo_root,
                    slice_id=slice_id,
                    log=_log,
                    voice=_voice,
                    cast=_cast,
                    stuck_printed=_stuck_printed,
                    reason="hard cap",
                    halt_kind="hard_cap",
                    now=now_cap,
                )
            _log(line)
        else:
            sig = _mechanic_signature(outcome)
            cont, line = progress.observe_signature(sig)
            if progress.thrash_halt():
                _log(line)
                narrate_thrash_halt(log=_log, voice=_voice)
                raise ThrashHalt(thrash_halt_message(progress))
            now_cap = time.time()
            if progress.at_hard_cap(now_cap):
                # Do not emit "PROGRESS: … continuing" right before a hard-cap halt.
                _log(hard_cap_console_line(progress, now=now_cap))
                _halt_exhausted(
                    outcome,
                    progress,
                    slice_file=slice_file,
                    repo_root=repo_root,
                    slice_id=slice_id,
                    log=_log,
                    voice=_voice,
                    cast=_cast,
                    stuck_printed=_stuck_printed,
                    reason="hard cap",
                    halt_kind="hard_cap",
                    now=now_cap,
                )
            _log(line)

        _narrate_verify_failure(
            agent,
            outcome,
            repo_root=repo_root,
            log=_log,
            voice=_voice,
            cast=_cast,
        )
        if outcome.packet is None:
            outcome.packet = build_failure_packet(
                failures=outcome.failures,
                crashes=outcome.crashes,
                bundle=(outcome.result or {}).get("bundle"),
                exit_code=(outcome.result or {}).get("exit"),
                output=outcome.output,
                repo_root=repo_root,
                export_attachments=False,
            )


def _halt_exhausted(
    outcome: Any,
    progress: ProgressTracker,
    *,
    slice_file: str,
    repo_root: str,
    slice_id: int | None,
    log: LogFn,
    voice: Any,
    cast: CastLog,
    stuck_printed: set[str],
    reason: str,
    halt_kind: str = "hard_cap",
    now: float | None = None,
) -> None:
    from slice_pipeline import _log_stuck_card_path

    now = time.time() if now is None else now
    packet = outcome.packet
    cap_line = ""
    if halt_kind == "hard_cap":
        cap_line = hard_cap_stuck_line(progress, now=now)
        msg = hard_cap_halt_message(progress, now=now, last=reason)
    else:
        msg = thrash_halt_message(progress, last=reason)
    card = format_stuck_card(
        packet or FailurePacket(raw_failures=outcome.failures),
        slice_file=slice_file,
        attempt=progress.spawns_used,
        max_attempts=progress.max_spawns,
        levers_tried=progress.levers_tried,
        cap_line=cap_line,
    )
    _log_stuck_card_path(
        card,
        repo_root=repo_root,
        slice_file=slice_file,
        log=log,
        printed=stuck_printed,
    )
    if halt_kind == "hard_cap":
        narrate_hard_cap_halt(log=log, voice=voice)
    else:
        narrate_thrash_halt(log=log, voice=voice)
    if outcome.packet:
        last_name = cast.entries[-1].name if cast.entries else "Quinn"
        narrate_failure_detail(
            last_name,
            outcome.packet,
            log=log,
            voice=voice,
        )
    resume_hint = (
        f"Resume warm: scripts/slice-loop.sh --max 1  "
        f"# see build/test-results/session-slice-{(slice_id or 0):02d}/"
        f"  # hard-cap timer resets on warm resume"
        if halt_kind == "hard_cap"
        else (
            f"Resume warm: scripts/slice-loop.sh --max 1  "
            f"# see build/test-results/session-slice-{(slice_id or 0):02d}/"
        )
    )
    log(resume_hint)
    bundle_dir = write_session_bundle(
        repo_root=repo_root,
        slice_id=slice_id,
        reason=msg,
        stuck_card=card,
        verify_result=outcome.result,
        failures=outcome.failures,
        crashes=outcome.crashes,
        phase="HALT",
        extra={
            "gate": "mechanic",
            "spawns": progress.spawns_used,
            "resume_hint": resume_hint,
            "halt_kind": halt_kind,
            "mechanic_elapsed_m": round(progress.mechanic_elapsed_minutes(now), 1),
            "verify_elapsed_m": round(progress.verify_elapsed_minutes(now), 1),
            "max_minutes": progress.max_minutes,
        },
    )
    log(f"session bundle written: {bundle_dir}")
    raise ThrashHalt(msg)


def os_path_join(repo_root: str, r: str) -> str:
    import os

    return r if os.path.isabs(r) else os.path.join(repo_root, r)
