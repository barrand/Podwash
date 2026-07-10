# Slice 18 — Unrelated-content segmentation spike (Differentiator 2)

| Field | Value |
|-------|-------|
| **ID** | 18 |
| **Title** | Segmentation spike |
| **Status** | Ready |
| **Crux** | An on-device, transcript-based segmenter labels superfluous/tangential spans in a hand-golden fixture with **precision ≥ 0.7** and **recall ≥ 0.5** (temporal IoU ≥ 0.5 matching), with **execution evidence** (committed benchmark JSON produced by the spike harness) — proving Differentiator 2 is feasible before Slice 19 integration. |

## Product decisions (user, 2026-07-10 — MVP track)

| Decision | Choice |
|----------|--------|
| Differentiator 2 timing | **MVP** — segmentation spike runs before integration (Slice 19) |
| Feature default | **Off by default** (per PRD §4); user opts in per channel/settings |

## PRD / spec references

- PRD §4 — Unrelated-content handling (off by default; content-curation framing)
- PRD §6 — Analyze once → interval list (segmentation consumes `[TimedWord]` from the Slice 07 stack)
- PRD §8 — Legal posture (playback-time controls; attorney review before launch)
- `docs/adr/000-foundations.md` §4 — `TimedWord` transcript schema (spike input)
- `docs/adr/005-analysis-pipeline.md` — transcript injection seam (pattern for fast tests)

## Goal

Pick an on-device segmentation approach with benchmarked precision/recall on a hand-labeled transcript fixture and record the recommendation for Slice 19.

## Deliverables

- **Fixture transcript** `PodWash/PodWashTests/Fixtures/segmentation/spike_transcript.json` — committed `[TimedWord]` array (≥ 60 s span, synthetic scripted content with clearly separable on-topic vs tangential/ad-like passages)
- **Hand-labeled golden** `PodWash/PodWashTests/Fixtures/segmentation/golden_segments.json` — positive-class segment ranges `[{ "start": Double, "end": Double }]` only (superfluous/tangential spans); provenance in `PodWash/PodWashTests/Fixtures/segmentation/segmentation-provenance.md` (labels created by a person from the scripted transcript, **never** by the candidate segmenter)
- **Benchmark JSON artifact** `PodWash/PodWashTests/Fixtures/segmentation/benchmark-results.json` — written by the spike harness (slow test when live inference is heavy; fast test path when heuristic-only): `approach`, `precision`, `recall`, `segmentCount`, `segments` (`[{start, end}]`), and timing fields (`durationSeconds`, `inferenceSeconds`) as applicable
- **App-target segmentation module** `PodWash/PodWash/ContentSegmenting.swift` (protocol + result types) and one concrete implementation chosen by the spike (e.g. `HeuristicContentSegmenter.swift` or `EmbeddingContentSegmenter.swift`) — public surface consumes `[TimedWord]` and returns segment time ranges; Slice 19 imports this API
- `SegmentationSpikeTests` (fast — validates committed artifact + recomputed metrics vs golden; no live heavy inference on the Done gate)
- Heavy benchmark regeneration in `PodWashSlowTests` when the chosen approach needs models or CPU time beyond the fast suite budget (same committed-artifact pattern as Slice 05)
- Recommendation ADR `docs/adr/012-content-segmentation-approach.md` with benchmark numbers and rejected alternatives

## Depends on

- Slice 07 (`TimedWord` schema, transcript-injection pattern)

**Parallelizable:** Yes — independent R&D after Slice 07; may run in parallel with Slices 22–23 once deps are met (serialize if touching shared app modules).

## Out-of-scope

- Product integration — pipeline, cache, playback, settings toggles (Slice 19)
- Skip-override UI and feature default wiring (Slice 19)
- Server-side segmentation or interval lists from a backend
- Live ASR on full episodes (Slice 07 owns transcription; this spike takes transcript JSON as input)
- Merging segment intervals with profanity intervals (Slice 19)
- Perceptual listening QA or subjective "sounds like an ad" review
- Improving detection beyond the pinned thresholds (future iteration slices)

## Fixture strategy (pinned — Architect / QA)

| Asset | Path | Role |
|-------|------|------|
| Input transcript | `Fixtures/segmentation/spike_transcript.json` | `[TimedWord]` per ADR-000 §4 |
| Golden positives | `Fixtures/segmentation/golden_segments.json` | ≥ **2** disjoint positive segments; total golden positive duration ≥ **15 s** |
| Benchmark artifact | `Fixtures/segmentation/benchmark-results.json` | Execution evidence; fast tests load from bundle |
| Provenance | `Fixtures/segmentation/segmentation-provenance.md` | Documents who labeled what and why segments are positive |

**Metric contract (AC1):** treat each golden range as one positive instance. A predicted segment is a **true positive** iff temporal IoU with some unmatched golden positive is **≥ 0.5** (greedy one-to-one assignment by highest IoU). **Precision** = TP / (TP + FP); **recall** = TP / (TP + FN). Fast test **recomputes** precision/recall from `benchmark.segments` vs the golden file (does not trust embedded stat fields alone).

## Acceptance criteria

Automatable only. **XCTSkip is not allowed on core ACs** — mapped tests fail if prerequisites are missing.

- [ ] 1. Fast test: from the **committed `benchmark-results.json`**, recomputed precision **≥ 0.700** and recall **≥ 0.500** against `golden_segments.json` using IoU **≥ 0.5** matching. Assert `benchmark.approach` is non-empty and `benchmark.segments` has **≥ 1** entry. (Live regeneration of the artifact runs in `PodWashSlowTests` when the chosen approach is heavy.)
- [ ] 2. **Execution evidence:** fast test **FAILS** (does not skip) if `benchmark-results.json` is missing, unparsable, or has `segmentCount == 0`. Failure message points at the slow regeneration test path when applicable.
- [ ] 3. Golden integrity: fast test asserts `golden_segments.json` contains **≥ 2** segments, each with `end > start` and duration **≥ 5.0 s**, and total labeled positive duration **≥ 15.0 s**.
- [ ] 4. Decision artifact: `docs/adr/012-content-segmentation-approach.md` exists and cites the committed benchmark precision/recall (±0.001) and names the chosen `approach` string matching the artifact.
- [ ] 5. When `PodWashSlowTests` is used for regeneration: target is a member of the `PodWash` scheme test action with `skipped="YES"` (present for nightly CI; excluded from default fast `verify.sh` so AC6 stays `skipped=0`).
- [ ] 6. Full fast suite green via `scripts/verify.sh` with **skipped = 0**.

**Threshold policy:** if AC1 cannot be met after good-faith spike work, **halt-and-ask** the user — do not lower precision/recall thresholds silently.

## Verification mapping

| AC# | Test file | Test method | Notes |
|-----|-----------|-------------|-------|
| 1 | `PodWash/PodWashTests/SegmentationSpikeTests.swift` | `testPrecisionRecallAgainstGolden` | Recomputes IoU-based P/R from `benchmark.segments` vs golden; asserts `approach` + segment count |
| 2 | `PodWash/PodWashTests/SegmentationSpikeTests.swift` | `testBenchmarkArtifactExistsAndNonEmpty` | Fails (never skips) on missing/unparsable/`segmentCount==0` |
| 3 | `PodWash/PodWashTests/SegmentationSpikeTests.swift` | `testGoldenFixtureIntegrity` | Structural asserts on golden segment count and durations |
| 4 | `PodWash/PodWashTests/SegmentationSpikeTests.swift` | `testDecisionArtifactRecorded` | Structural: ADR-012 exists; numbers match artifact within ±0.001 |
| 5 | `PodWash/PodWashTests/SegmentationSpikeTests.swift` | `testSlowTestTargetInSchemeIfPresent` | No-op pass when no slow target; else asserts `PodWashSlowTests` TestableReference with `skipped="YES"` |
| 6 | — | — | Command-level: unfiltered `scripts/verify.sh` exit 0, skipped 0 |
| — (live) | `PodWash/PodWashSlowTests/SegmentationBenchmarkTests.swift` | `testSegmentationBenchmarkAndRegenerateArtifact` | Nightly only (NOT a Done gate) when heavy; regenerates `benchmark-results.json` |

## Verification commands

```bash
# Fast inner loop:
scripts/verify.sh -only-testing:PodWashTests/SegmentationSpikeTests

# Slow benchmark (nightly CI or manual; NOT the Done gate) — only when Architect routes regeneration here:
PODWASH_SCHEME=PodWashSlowTests VERIFY_ALLOW_SKIPS=1 scripts/verify.sh

# Done gate — FULL fast suite, zero failures, zero skips:
scripts/verify.sh
```

## Verification record (QA fills at Verify)

```
VERIFY RESULT: (pending)
```

## Plan review record (coordinator fills before downstream roles)

```
ADR review (2026-07-10): (pending) QA cleared — pipeline worker finished PM cleared — pipeline worker finished
Test spec review (2026-07-10): Architect cleared — pipeline worker finished
```

## Done gate

- [ ] Every AC mapped to a test; all rows in the mapping table filled
- [ ] **Full suite green:** unfiltered `scripts/verify.sh` exit 0, failed 0, skipped 0
- [ ] Verification record pasted above (exit code + counts + .xcresult path)
- [ ] Auto-commit on green: `slice-18: <short description>` (push only when the user asks)

## Design notes (Architect)

- **Chosen approach:** `heuristic-cue-v1` (`HeuristicContentSegmenter`) — deterministic cue lexicon + light topic-drift over `[TimedWord]`; see [ADR-012](../adr/012-content-segmentation-approach.md).
- **Public surface:** `ContentSegmenting` / `ContentSegment` / `SegmentationBenchmark` in `ContentSegmenting.swift`; Slice 19 maps segments → `CensorInterval` (no action on spike output).
- **Verification:** committed `benchmark-results.json` + IoU ≥ 0.5 P/R recompute (fast); regeneration in `PodWashSlowTests/SegmentationBenchmarkTests` (not Done gate). Benchmark numeric rows in ADR-012 filled at implement for AC4.
- **Cross-cutting:** no changes to `TimedWord`, `PlaybackEngine`, or profanity `IntervalBuilder` in this slice.

## Role artifacts

| Role | Gate | Artifact path |
|------|------|---------------|
| Architect | Required | `docs/adr/012-content-segmentation-approach.md` |
| UX | Waived | — (no user-facing segmentation UI in spike) |
