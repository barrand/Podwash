# Slice 07 — Analyze-episode pipeline

| Field | Value |
|-------|-------|
| **ID** | 07 |
| **Title** | Analyze-episode pipeline |
| **Status** | Draft |
| **Crux** | ASR → matcher → `IntervalBuilder` wired into one pipeline: a fixture episode produces a persisted interval list matching golden JSON, and a second run reuses the cache without re-transcribing. |

## PRD / spec references

- PRD §6 — Analyze once → interval list (pipeline, caching)
- `docs/adr/000-foundations.md` §4 — `TimedWord` flows ASR → matcher

## Goal

Produce and persist the interval list for an episode; prove cache reuse. (Playback of those intervals is Slice 08; progress UI is Slice 09.)

## Deliverables

- `AnalysisPipeline`: audio file → ASR (Slice 05 stack) → `WordMatcher`/`IntervalBuilder` (Slice 02) → interval list
- On-disk interval cache keyed by episode identity (simple JSON store; durable DB integration in Slice 11)
- Bundled-transcript fallback path for fast tests (inject transcript, skip ASR)
- Golden `e2e_intervals.json` — provenance: hand-applied spec rules to the fixture's human-verified transcript (documented)
- `AnalysisPipelineTests` (fast, injected transcript); full ASR-inclusive run in `PodWashSlowTests`

## Depends on

- Slices 02, 05

**Parallelizable:** With Slice 08 only after coordination — both touch pipeline/player seams; prefer sequential 07 → 08.

## Out-of-scope

- Playback application of intervals (Slice 08)
- Progress UI and toggles (Slice 09)
- Downloads of real episodes (Slice 10)
- Unrelated-content segmentation (Slices 18–19)

## Acceptance criteria

- [ ] 1. Integration test (injected transcript): fixture episode → persisted interval list equals golden `e2e_intervals.json` within ±0.0005 s.
- [ ] 2. Unit test: second analysis call for the same episode returns cached intervals; ASR spy records **0** transcription calls.
- [ ] 3. Unit test: cache invalidates when the word list changes (different category selection → re-analysis, spy records 1 call).
- [ ] 4. Slow test (`PodWashSlowTests`): full ASR-inclusive pipeline on the bundled clip produces intervals covering every golden profanity timestamp (±200 ms).
- [ ] 5. Full fast suite green via `scripts/verify.sh`, skipped = 0.

## Verification mapping

| AC# | Test file | Test method | Notes |
|-----|-----------|-------------|-------|
| 1 | `PodWash/PodWashTests/AnalysisPipelineTests.swift` | `testPipelineProducesGoldenIntervals` | TBD |
| 2 | `PodWash/PodWashTests/AnalysisPipelineTests.swift` | `testSecondRunUsesCache` | TBD |
| 3 | `PodWash/PodWashTests/AnalysisPipelineTests.swift` | `testWordListChangeInvalidatesCache` | TBD |
| 4 | `PodWashSlowTests/FullPipelineSlowTests.swift` | `testFullASRPipelineCoversGoldenTimestamps` | Nightly |
| 5 | — | — | Command-level |

## Verification commands

```bash
scripts/verify.sh -only-testing:PodWashTests/AnalysisPipelineTests   # inner loop
scripts/verify.sh                                                    # Done gate
```

## Verification record (QA fills at Verify)

```
VERIFY RESULT: (pending)
```

## Done gate

- [ ] Every AC mapped to a test; all rows filled
- [ ] **Full suite green:** unfiltered `scripts/verify.sh` exit 0, failed 0, skipped 0
- [ ] Verification record pasted above
- [ ] Auto-commit on green: `slice-07: <short description>`

## Role artifacts

| Role | Gate | Artifact path |
|------|------|---------------|
| Architect | Required | `docs/adr/005-analysis-pipeline.md` (TBD) |
| UX | Waived | — |
