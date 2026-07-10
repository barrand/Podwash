#!/usr/bin/env python3
"""Unit tests for observation-first fix lanes + worker handoffs."""

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
    filter_paths_for_role,
    format_attempt_note,
    git_delta,
    is_adr_citation_failure,
    parse_handoff_line,
    resolve_handoff_flip,
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
        self.assertEqual(lane.role, "QA")
        self.assertIn("benchmark-results.json", lane.instruction)

    def test_expectation_api_lane(self):
        msg = (
            "PodWashTests/PlaybackRateTests/testSupportedRatesMatchAVPlayer() — "
            "API violation - multiple calls made to -[XCTestExpectation fulfill]"
        )
        lane = classify_fix_lane(blob=msg)
        self.assertIsNotNone(lane)
        assert lane is not None
        self.assertEqual(lane.lane_id, "expectation_api")
        self.assertEqual(lane.role, "QA")
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
        self.assertEqual(lane.role, "Engineer")

    def test_build_lane(self):
        lane = classify_fix_lane(blob="something else", is_build=True)
        assert lane is not None
        self.assertEqual(lane.lane_id, "build")
        self.assertEqual(lane.role, "Engineer")

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
        self.assertEqual(lane.role, "Architect")
        self.assertEqual(lane.fix_scope, "docs")
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


class GitDeltaAndScopeTests(unittest.TestCase):
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

    def test_filter_paths_engineer(self):
        paths = [
            "PodWash/PodWash/Foo.swift",
            "PodWash/PodWashTests/FooTests.swift",
            "docs/adr/012.md",
        ]
        self.assertEqual(
            filter_paths_for_role(paths, "Engineer"),
            ["PodWash/PodWash/Foo.swift"],
        )

    def test_filter_paths_qa(self):
        paths = [
            "PodWash/PodWash/Foo.swift",
            "PodWash/PodWashTests/Fixtures/segmentation/benchmark-results.json",
            "PodWash/PodWashSlowTests/Seg.swift",
        ]
        self.assertEqual(
            filter_paths_for_role(paths, "QA"),
            [
                "PodWash/PodWashTests/Fixtures/segmentation/benchmark-results.json",
                "PodWash/PodWashSlowTests/Seg.swift",
            ],
        )

    def test_filter_paths_architect(self):
        paths = [
            "docs/adr/012-content-segmentation-approach.md",
            "PodWash/PodWash/Foo.swift",
            "PodWash/PodWashTests/SegmentationSpikeTests.swift",
        ]
        self.assertEqual(
            filter_paths_for_role(paths, "Architect"),
            ["docs/adr/012-content-segmentation-approach.md"],
        )


class HandoffParseTests(unittest.TestCase):
    def test_parse_handoff_line(self):
        text = (
            "SUMMARY: no app edit needed\n"
            "HANDOFF: scope=out_of_scope; route=QA; applied=no\n"
        )
        h = parse_handoff_line(text)
        self.assertIsNotNone(h)
        assert h is not None
        self.assertEqual(h.scope, "out_of_scope")
        self.assertEqual(h.route, "QA")
        self.assertEqual(h.applied, "no")

    def test_flip_when_empty_delta(self):
        h = parse_handoff_line(
            "HANDOFF: scope=out_of_scope; route=QA; applied=no"
        )
        flip, msg = resolve_handoff_flip("Engineer", h, [])
        self.assertEqual(flip, "QA")
        self.assertIn("HANDOFF FLIP", msg)

    def test_flip_out_of_scope_to_architect(self):
        h = parse_handoff_line(
            "HANDOFF: scope=out_of_scope; route=Architect; applied=no"
        )
        flip, msg = resolve_handoff_flip("Engineer", h, [])
        self.assertEqual(flip, "Architect")
        self.assertIn("out_of_scope → Architect", msg)

    def test_explicit_route_architect(self):
        h = parse_handoff_line(
            "HANDOFF: scope=ok; route=Architect; applied=no"
        )
        flip, msg = resolve_handoff_flip("Engineer", h, [])
        self.assertEqual(flip, "Architect")
        self.assertIn("route=Architect", msg)

    def test_ignore_when_in_scope_edits(self):
        h = parse_handoff_line(
            "HANDOFF: scope=out_of_scope; route=QA; applied=yes"
        )
        flip, msg = resolve_handoff_flip(
            "Engineer", h, ["PodWash/PodWash/Foo.swift"]
        )
        self.assertIsNone(flip)
        self.assertIn("HANDOFF IGNORED", msg)

    def test_format_attempt_note(self):
        note = format_attempt_note(
            attempt=1,
            role="Engineer",
            agent="Edison",
            files=[],
            handoff="out_of_scope→QA",
            summary="route to QA for fixture",
            status="finished",
        )
        self.assertIn("files=[]", note)
        self.assertIn("handoff=out_of_scope→QA", note)
        self.assertIn("summary=route to QA", note)


class Tier2AndRouteIntegrationTests(unittest.TestCase):
    def test_resolve_tier2_artifact_routes_qa(self):
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
            self.assertEqual(role, "QA")
            self.assertIn("Artifact/fixture lane", prompt)
            self.assertIn("HANDOFF:", prompt)

    def test_route_fix_uses_lane(self):
        packet = FailurePacket(
            raw_failures=[SLICE18_FAIL],
            assertions=[SLICE18_FAIL],
            failure_class="unknown",
        )
        self.assertEqual(
            route_fix([SLICE18_FAIL], [], packet=packet),
            "QA",
        )

    def test_resolve_tier2_adr_citation_routes_architect(self):
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
            self.assertEqual(role, "Architect")
            self.assertIn("ADR citation lane", prompt)
            self.assertIn("HANDOFF:", prompt)
            self.assertIn("Architect", prompt)

    def test_route_fix_adr_citation(self):
        packet = FailurePacket(
            raw_failures=[SLICE18_ADR_FAIL],
            assertions=[SLICE18_ADR_FAIL],
            failure_class="assertion",
        )
        self.assertEqual(
            route_fix([SLICE18_ADR_FAIL], [], packet=packet),
            "Architect",
        )


class NoEditThrashHelperTests(unittest.TestCase):
    def test_explicit_noop_counts_toward_thrash(self):
        h = parse_handoff_line(
            "HANDOFF: scope=out_of_scope; route=QA; applied=no"
        )
        self.assertTrue(
            h is not None
            and (h.scope == "out_of_scope" or h.applied == "no")
        )

    def test_missing_handoff_is_not_explicit_noop(self):
        self.assertIsNone(parse_handoff_line("SUMMARY: tried something"))


if __name__ == "__main__":
    unittest.main()
