#!/usr/bin/env python3
"""Data-driven fix playbooks for loop-owned red verifies."""

from __future__ import annotations

from dataclasses import dataclass


@dataclass(frozen=True)
class PlaybookLever:
    role: str  # Engineer | QA | halt
    instruction: str
    suggested_files: tuple[str, ...] = ()
    forbid: tuple[str, ...] = ()


@dataclass(frozen=True)
class FailurePlaybook:
    failure_class: str
    summary: str
    levers: tuple[PlaybookLever, ...]


# Starter + full matrix (P1 snippets are levers[0]; P2 uses full list).
PLAYBOOKS: dict[str, FailurePlaybook] = {
    "crash": FailurePlaybook(
        failure_class="crash",
        summary="Simulator/app crash — fix from IPS/stack; never edit tests.",
        levers=(
            PlaybookLever(
                role="Engineer",
                instruction=(
                    "Parse IPS/stack; fix the crash in app code. Do not edit tests."
                ),
                forbid=("edit tests", "weaken XCTAssert"),
            ),
            PlaybookLever(
                role="Engineer",
                instruction=(
                    "Same crash signature after attempt 1 — narrow repro, add nil "
                    "guards / lifecycle fixes. Still no test edits."
                ),
                forbid=("edit tests", "weaken XCTAssert"),
            ),
        ),
    ),
    "ui_race": FailurePlaybook(
        failure_class="ui_race",
        summary=(
            "UITest missed a transient (e.g. progress) while post-success UI is "
            "already visible — lengthen observable window in app."
        ),
        levers=(
            PlaybookLever(
                role="Engineer",
                instruction=(
                    "Lengthen the observable analyzing window (hold analyzing state "
                    "/ defer completion) so UITests can see the transient control. "
                    "Do not weaken or delete the progress assertion."
                ),
                suggested_files=(
                    "PodWash/PodWash/EpisodeListView.swift",
                    "PodWash/PodWash/AnalysisUIViewModel.swift",
                    "PodWash/PodWash/InstantEpisodeAnalyzer.swift",
                    "PodWash/PodWash/AnalysisUIState.swift",
                ),
                forbid=(
                    "weaken XCTAssert",
                    "delete progress assertion",
                    "edit goldens",
                ),
            ),
            PlaybookLever(
                role="Engineer",
                instruction=(
                    "Same ui_race after attempt 1 — try a different app lever: "
                    "defer InstantEpisodeAnalyzer completion, hold AnalysisUIState "
                    ".analyzing for ≥ UITest observable window (2s+), or ensure "
                    "analysisProgress is published on the main actor before finish. "
                    "Do not weaken or delete the progress assertion."
                ),
                suggested_files=(
                    "PodWash/PodWash/EpisodeListView.swift",
                    "PodWash/PodWash/AnalysisUIViewModel.swift",
                    "PodWash/PodWash/InstantEpisodeAnalyzer.swift",
                    "PodWash/PodWash/AnalysisUIState.swift",
                ),
                forbid=(
                    "weaken XCTAssert",
                    "delete progress assertion",
                    "edit goldens",
                    "edit UITests",
                ),
            ),
            PlaybookLever(
                role="halt",
                instruction=(
                    "Same ui_race after two Engineer attempts. Do NOT soften the "
                    "UITest unless AC explicitly requires observing the transient AND "
                    "diagnose fix_scope=tests. Otherwise halt for PM/UX AC clarity."
                ),
                forbid=("weaken XCTAssert", "remove wait for progress"),
            ),
        ),
    ),
    "missing_identifier": FailurePlaybook(
        failure_class="missing_identifier",
        summary="Query id absent from hierarchy — wire accessibilityIdentifier.",
        levers=(
            PlaybookLever(
                role="Engineer",
                instruction=(
                    "Add/fix accessibilityIdentifier on the named control from the "
                    "failed query so it appears in the hierarchy."
                ),
                forbid=("weaken XCTAssert",),
            ),
            PlaybookLever(
                role="Engineer",
                instruction=(
                    "Identifier still missing — fix parent visibility / "
                    "isAccessibilityElement so the control is exposed."
                ),
                forbid=("weaken XCTAssert",),
            ),
        ),
    ),
    "wrong_state": FailurePlaybook(
        failure_class="wrong_state",
        summary="UI/state machine out of sync with store or events.",
        levers=(
            PlaybookLever(
                role="Engineer",
                instruction=(
                    "Fix state machine / ViewModel transition so UI matches the "
                    "event sequence under test."
                ),
            ),
            PlaybookLever(
                role="Engineer",
                instruction=(
                    "Still wrong state — sync UI from store after the triggering "
                    "event; check published bindings."
                ),
            ),
        ),
    ),
    "assertion": FailurePlaybook(
        failure_class="assertion",
        summary="Unit/UI assertion mismatch — scope from diagnose.",
        levers=(
            PlaybookLever(
                role="Engineer",
                instruction=(
                    "If assertion documents correct product behavior, fix the app. "
                    "If the expectation/fixture is wrong, that is a QA lever — "
                    "respect fix_scope from diagnose."
                ),
            ),
            PlaybookLever(
                role="QA",
                instruction=(
                    "Same signature after Engineer — fix wrong expectation/fixture "
                    "only if the product behavior is correct. Do not weaken AC."
                ),
                forbid=("weaken XCTAssert without AC change",),
            ),
        ),
    ),
    "build_error": FailurePlaybook(
        failure_class="build_error",
        summary="Compile/link/tooling failure — fix the failing target.",
        levers=(
            PlaybookLever(
                role="Engineer",
                instruction="Fix compile/link error in the app target.",
                forbid=("edit tests unless error is in test target",),
            ),
            PlaybookLever(
                role="QA",
                instruction=(
                    "Build error is in a test target — fix the test/fixture compile "
                    "issue only."
                ),
            ),
        ),
    ),
    "flake": FailurePlaybook(
        failure_class="flake",
        summary="Likely flake — cold re-verify once before burning fix budget.",
        levers=(
            PlaybookLever(
                role="Engineer",
                instruction=(
                    "Reclassified from flake after cold retry — make a minimal "
                    "deterministic fix; do not weaken waits casually."
                ),
            ),
        ),
    ),
    "unknown": FailurePlaybook(
        failure_class="unknown",
        summary="Unclassified — diagnose then minimal Engineer change.",
        levers=(
            PlaybookLever(
                role="Engineer",
                instruction=(
                    "Still unknown after diagnose — minimal change guided only by "
                    "the FailurePacket. Do not weaken tests."
                ),
                forbid=("weaken XCTAssert", "broad refactors"),
            ),
            PlaybookLever(
                role="halt",
                instruction=(
                    "Still unknown after a fix attempt — halt with stuck card for "
                    "a human."
                ),
            ),
        ),
    ),
}


def get_playbook(failure_class: str) -> FailurePlaybook:
    return PLAYBOOKS.get(failure_class) or PLAYBOOKS["unknown"]


def select_lever(
    failure_class: str,
    *,
    lever_index: int = 0,
    fix_scope: str = "app",
    allow_uitest_wait_fix: bool = False,
) -> PlaybookLever:
    """Pick lever by index; apply assertion/ui_race special cases."""
    pb = get_playbook(failure_class)
    idx = max(0, min(lever_index, len(pb.levers) - 1))
    lever = pb.levers[idx]

    if failure_class == "assertion":
        if fix_scope == "tests":
            # Prefer QA on first lever when diagnose says tests
            if lever_index == 0:
                return PlaybookLever(
                    role="QA",
                    instruction=(
                        "Diagnose says tests scope — fix wrong expectation/fixture. "
                        "Do not change product AC silently."
                    ),
                    forbid=lever.forbid,
                    suggested_files=lever.suggested_files,
                )
            return PlaybookLever(
                role="Engineer",
                instruction=(
                    "Same assertion after QA — product behavior may be wrong; fix app."
                ),
                forbid=lever.forbid,
            )
        if lever_index >= 1:
            return pb.levers[min(1, len(pb.levers) - 1)]

    if failure_class == "ui_race" and lever_index >= 1:
        # Lever 1 = second Engineer attempt; halt only at lever_index >= 2
        # (or when playbook lever role is already halt).
        if lever_index >= 2 or lever.role == "halt":
            if allow_uitest_wait_fix and fix_scope == "tests":
                return PlaybookLever(
                    role="QA",
                    instruction=(
                        "AC requires observing the transient and diagnose says tests — "
                        "improve wait/expectation without removing the AC or progress "
                        "assertion."
                    ),
                    forbid=(
                        "delete progress assertion",
                        "weaken XCTAssert beyond wait timing",
                    ),
                )
            return PlaybookLever(
                role="halt",
                instruction=(
                    "Same ui_race after two Engineer attempts — needs PM/UX AC clarity. "
                    "Do not soften the UITest."
                ),
                forbid=("weaken XCTAssert", "remove wait for progress"),
            )
        # lever_index == 1 → return the second Engineer lever as-is
        return lever

    if failure_class == "build_error" and fix_scope == "tests":
        return get_playbook("build_error").levers[
            min(1, len(get_playbook("build_error").levers) - 1)
        ]

    return lever


def starter_lever_text(failure_class: str) -> str:
    """Short P1 bridge line for stuck cards before full matrix wiring."""
    lever = select_lever(failure_class, lever_index=0)
    return f"{lever.instruction} ({lever.role})"
