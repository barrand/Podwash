#!/usr/bin/env python3
"""Unit tests for observation-first fix lanes (Factory v3 — Mechanic hints)."""

from __future__ import annotations

import os
import sys
import tempfile
import unittest

_SCRIPTS = os.path.dirname(os.path.abspath(__file__))
if _SCRIPTS not in sys.path:
    sys.path.insert(0, _SCRIPTS)

from failure_packet import FailurePacket  # noqa: E402
from fix_lanes import (  # noqa: E402
    classify_fix_lane,
    extract_adr_citation_hint,
    format_attempt_note,
    git_delta,
    git_delta_with_fingerprints,
    is_adr_citation_failure,
    snapshot_path_fingerprints,
)
from slice_pipeline import (  # noqa: E402
    VerifyOutcome,
    resolve_tier2_continue,
    route_fix,
)


SLICE18_FAIL = (
    "PodWashTests/SegmentationSpikeTests/testBenchmarkArtifactExistsAndNonEmpty() — "
    "failed - benchmark-results.json is unparsable as SegmentationBenchmark. "
    "Regenerate via PodWashSlowTests/SegmentationBenchmarkTests "
    "(VERIFY_ALLOW_SKIPS=1 scripts/verify.sh -only-testing:PodWashSlowTests/"
    "SegmentationBenchmarkTests)."
)


SLICE18_ADR_FAIL = (
    "PodWashTests/SegmentationSpikeTests/testDecisionArtifactRecorded() — "
    "XCTAssertTrue failed - ADR-012 must cite committed precision 1.0 within ±0.001"
)


class ClassifyFixLaneTests(unittest.TestCase):
    def test_artifact_fixture_lane(self):
        lane = classify_fix_lane(blob=SLICE18_FAIL)
        self.assertIsNotNone(lane)
        assert lane is not None
        self.assertEqual(lane.lane_id, "artifact_fixture")
        self.assertIn("benchmark-results.json", lane.instruction)
        self.assertIn("Suggested recipe (optional", lane.instruction)

    def test_expectation_api_lane(self):
        msg = (
            "PodWashTests/PlaybackRateTests/testSupportedRatesMatchAVPlayer() — "
            "API violation - multiple calls made to -[XCTestExpectation fulfill]"
        )
        lane = classify_fix_lane(blob=msg)
        self.assertIsNotNone(lane)
        assert lane is not None
        self.assertEqual(lane.lane_id, "expectation_api")
        self.assertIn("invalidate", lane.instruction.lower())

    def test_expectation_escalate(self):
        msg = (
            "API violation - multiple calls made to -[XCTestExpectation fulfill]"
        )
        lane = classify_fix_lane(blob=msg, escalate_expectation=True)
        assert lane is not None
        self.assertIn("NSPredicate", lane.instruction)
        self.assertIn("ledger-escalate:predicate-wait", lane.hypothesis)

    def test_packaging_lane(self):
        msg = "PodWash.app is missing its bundle executable"
        lane = classify_fix_lane(blob=msg)
        assert lane is not None
        self.assertEqual(lane.lane_id, "packaging")
        self.assertIn("Suggested recipe (optional", lane.instruction)
        self.assertIn("packaging failure", lane.instruction)

    def test_build_lane(self):
        lane = classify_fix_lane(blob="something else", is_build=True)
        assert lane is not None
        self.assertEqual(lane.lane_id, "build")
        self.assertIn("Suggested recipe (optional", lane.instruction)

    def test_unknown_returns_none(self):
        lane = classify_fix_lane(
            blob="PodWashTests/Foo/testBar() — XCTAssertEqual failed: 1 != 2"
        )
        self.assertIsNone(lane)

    def test_packaging_beats_build(self):
        lane = classify_fix_lane(
            blob="missing its bundle executable",
            is_build=True,
        )
        assert lane is not None
        self.assertEqual(lane.lane_id, "packaging")

    def test_adr_citation_lane(self):
        lane = classify_fix_lane(blob=SLICE18_ADR_FAIL)
        self.assertIsNotNone(lane)
        assert lane is not None
        self.assertEqual(lane.lane_id, "adr_citation")
        self.assertEqual(lane.suggested_scope, "docs")
        self.assertIn("docs/adr", lane.instruction)

    def test_adr_citation_beats_generic_assertion(self):
        self.assertTrue(is_adr_citation_failure(SLICE18_ADR_FAIL))
        lane = classify_fix_lane(
            blob=(
                "PodWashTests/Foo/testBar() — XCTAssertEqual failed: 1 != 2"
            )
        )
        self.assertIsNone(lane)

    def test_adr_citation_hint(self):
        hint = extract_adr_citation_hint(SLICE18_ADR_FAIL)
        self.assertIn("docs/adr/012", hint)
        self.assertIn("Benchmark results", hint)


class GitDeltaAndFingerprintTests(unittest.TestCase):
    def test_git_delta_ignores_baseline(self):
        baseline = {"docs/adr/012.md", "PodWash/PodWash/ContentSegmenting.swift"}
        after = baseline | {
            "PodWash/PodWashTests/Fixtures/segmentation/benchmark-results.json"
        }
        delta = git_delta(baseline, after)
        self.assertEqual(
            delta,
            ["PodWash/PodWashTests/Fixtures/segmentation/benchmark-results.json"],
        )

    def test_fingerprint_delta_sees_edit_to_already_dirty_path(self):
        """Slice 19: Architect edited already-untracked ADR — must count as delta."""
        with tempfile.TemporaryDirectory() as tmp:
            rel = "docs/adr/013-segmentation-integration.md"
            path = os.path.join(tmp, rel)
            os.makedirs(os.path.dirname(path), exist_ok=True)
            with open(path, "w", encoding="utf-8") as fh:
                fh.write("# ADR-013\npending\n")
            baseline = {rel}
            fps = snapshot_path_fingerprints(tmp, baseline)
            # Ensure mtime can advance on coarse filesystems
            os.utime(path, None)
            with open(path, "a", encoding="utf-8") as fh:
                fh.write("\n## Benchmark results\nprecision: 1.000\n")
            after = {rel}
            delta = git_delta_with_fingerprints(
                baseline,
                after,
                repo_root=tmp,
                fingerprints_before=fps,
            )
            self.assertEqual(delta, [rel])
            # Plain set-difference still empty — regression guard
            self.assertEqual(git_delta(baseline, after), [])

    def test_format_attempt_note(self):
        note = format_attempt_note(
            attempt=1,
            role="Mechanic",
            agent="Morgan",
            files=[],
            handoff="optional note",
            summary="fixed fixture",
            status="finished",
        )
        self.assertIn("files=[]", note)
        self.assertIn("role=Mechanic", note)
        self.assertIn("note=optional note", note)
        self.assertIn("summary=fixed fixture", note)


class Tier2AndRouteIntegrationTests(unittest.TestCase):
    def test_resolve_tier2_artifact_routes_mechanic(self):
        with tempfile.TemporaryDirectory() as tmp:
            slice_path = os.path.join(
                tmp, "docs", "slices", "slice-18-segmentation-spike.md"
            )
            os.makedirs(os.path.dirname(slice_path), exist_ok=True)
            with open(slice_path, "w", encoding="utf-8") as fh:
                fh.write(
                    "Deliverables:\n"
                    "- `PodWash/PodWash/ContentSegmenting.swift`\n"
                    "- `PodWash/PodWashTests/SegmentationSpikeTests.swift`\n"
                )
            failures = [SLICE18_FAIL]
            packet = FailurePacket(
                raw_failures=failures,
                assertions=failures,
                failure_class="assertion",
                fix_scope="tests",
                test_ids=[
                    "PodWashTests/SegmentationSpikeTests/"
                    "testBenchmarkArtifactExistsAndNonEmpty()"
                ],
                signature="sig",
            )
            outcome = VerifyOutcome(
                result={
                    "exit": "65",
                    "failed": "3",
                    "total": "5",
                    "bundle": "b.xcresult",
                },
                green=False,
                failures=failures,
                packet=packet,
                tier=2,
            )
            role, prompt = resolve_tier2_continue(
                slice_file=slice_path,
                repo_root=tmp,
                outcome=outcome,
                run_i=1,
                max_runs=3,
            )
            self.assertEqual(role, "Mechanic")
            self.assertIn("benchmark-results.json", prompt)
            self.assertIn("Suggested recipe", prompt)
            self.assertNotIn("HANDOFF:", prompt)

    def test_route_fix_always_mechanic(self):
        packet = FailurePacket(
            raw_failures=[SLICE18_FAIL],
            assertions=[SLICE18_FAIL],
            failure_class="unknown",
        )
        self.assertEqual(
            route_fix([SLICE18_FAIL], [], packet=packet),
            "Mechanic",
        )

    def test_resolve_tier2_adr_citation_routes_mechanic(self):
        with tempfile.TemporaryDirectory() as tmp:
            slice_path = os.path.join(
                tmp, "docs", "slices", "slice-18-segmentation-spike.md"
            )
            adr_path = os.path.join(
                tmp, "docs", "adr", "012-content-segmentation-approach.md"
            )
            os.makedirs(os.path.dirname(slice_path), exist_ok=True)
            os.makedirs(os.path.dirname(adr_path), exist_ok=True)
            with open(slice_path, "w", encoding="utf-8") as fh:
                fh.write(
                    "Deliverables:\n"
                    "- `docs/adr/012-content-segmentation-approach.md`\n"
                    "- `PodWash/PodWashTests/SegmentationSpikeTests.swift`\n"
                )
            open(adr_path, "w", encoding="utf-8").write("# ADR-012\n")
            failures = [SLICE18_ADR_FAIL]
            packet = FailurePacket(
                raw_failures=failures,
                assertions=failures,
                failure_class="assertion",
                fix_scope="tests",
                test_ids=[
                    "PodWashTests/SegmentationSpikeTests/testDecisionArtifactRecorded()"
                ],
                signature="sig",
            )
            outcome = VerifyOutcome(
                result={
                    "exit": "65",
                    "failed": "1",
                    "total": "5",
                    "bundle": "b.xcresult",
                },
                green=False,
                failures=failures,
                packet=packet,
                tier=2,
            )
            role, prompt = resolve_tier2_continue(
                slice_file=slice_path,
                repo_root=tmp,
                outcome=outcome,
                run_i=1,
                max_runs=3,
            )
            self.assertEqual(role, "Mechanic")
            self.assertIn("ADR", prompt)
            self.assertIn("docs/adr", prompt)
            self.assertNotIn("HANDOFF:", prompt)

    def test_route_fix_adr_citation_still_mechanic(self):
        packet = FailurePacket(
            raw_failures=[SLICE18_ADR_FAIL],
            assertions=[SLICE18_ADR_FAIL],
            failure_class="assertion",
        )
        self.assertEqual(
            route_fix([SLICE18_ADR_FAIL], [], packet=packet),
            "Mechanic",
        )


if __name__ == "__main__":
    unittest.main()
