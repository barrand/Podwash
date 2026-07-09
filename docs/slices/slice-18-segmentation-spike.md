# Slice 18 — Unrelated-content segmentation spike (Differentiator 2)

| Field | Value |
|-------|-------|
| **ID** | 18 |
| **Title** | Segmentation spike |
| **Status** | Draft — **post-MVP track** (see placement note) |
| **Crux** | An on-device approach can label "superfluous/tangential" segments (which may include ads) in a fixture transcript with measurable precision/recall against a hand-labeled golden — proving Differentiator 2 is feasible before building product around it. |

## Placement note (planned, not abandoned)

Differentiator 2 (PRD §4) is core to the product vision but is deliberately scheduled **after the MVP path (Slices 01–14)**: it needs the full analyze/playback pipeline, its own detection R&D, and PRD §11's open attorney question about skip framing. Labeling it post-MVP here keeps it planned with real slice files rather than unowned. If the user wants it at MVP, this slice moves earlier — that is a user call.

## PRD / spec references

- PRD §4 — Unrelated-content handling (off by default; content-curation framing)
- PRD §8 — Legal posture (playback-time controls; attorney review before launch)

## Goal

Data-driven feasibility answer: what mechanism (heuristics, on-device LLM, embedding similarity, chapter/ad markers) segments unrelated content acceptably on-device?

## Deliverables

- Hand-labeled golden: fixture transcript(s) with human-annotated segment ranges (provenance documented — labels created by a person, never by the candidate models)
- Spike harness scoring candidate approaches: precision/recall vs golden, runtime, memory
- Benchmark JSON artifact (same execution-evidence pattern as Slice 05: test fails if missing/empty)
- Recommendation ADR
- `SegmentationSpikeTests` (fast, small fixture); heavy runs in `PodWashSlowTests`

## Depends on

- Slice 07 (transcript availability); MVP slices unaffected

**Parallelizable:** Yes — independent R&D after Slice 07.

## Out-of-scope

- Product integration (Slice 19)
- Server-side segmentation

## Acceptance criteria

- [ ] 1. Spike test: recommended approach achieves ≥ 0.7 precision and ≥ 0.5 recall against the hand-labeled golden on the fixture set (thresholds revisit with user if unmet — halt-and-ask, don't lower silently).
- [ ] 2. Execution evidence: benchmark JSON exists with nonzero segment count; test FAILS (not skips) if absent.
- [ ] 3. Recommendation ADR committed with the numbers.
- [ ] 4. Full fast suite green via `scripts/verify.sh`.

## Verification mapping

| AC# | Test file | Test method | Notes |
|-----|-----------|-------------|-------|
| 1 | `PodWash/PodWashTests/SegmentationSpikeTests.swift` | `testPrecisionRecallAgainstGolden` | TBD |
| 2 | `PodWash/PodWashTests/SegmentationSpikeTests.swift` | `testBenchmarkArtifactNonEmpty` | Fails, never skips |
| 3 | — | — | Artifact: ADR |
| 4 | — | — | Command-level |

## Verification commands

```bash
scripts/verify.sh -only-testing:PodWashTests/SegmentationSpikeTests
scripts/verify.sh    # Done gate
```

## Verification record (QA fills at Verify)

```
VERIFY RESULT: (pending)
```

## Done gate

- [ ] Every AC mapped to a test; all rows filled
- [ ] **Full suite green:** unfiltered `scripts/verify.sh` exit 0, failed 0, skipped 0
- [ ] Verification record pasted above
- [ ] Auto-commit on green: `slice-18: <short description>`

## Role artifacts

| Role | Gate | Artifact path |
|------|------|---------------|
| Architect | Required | segmentation-approach ADR (TBD) |
| UX | Waived | — |
