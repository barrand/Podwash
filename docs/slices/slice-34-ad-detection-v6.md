# Slice 34 — Ad detection heuristic-cue-v6

| Field | Value |
|-------|-------|
| **ID** | 34 |
| **Title** | Ad detection heuristic-cue-v6 (sentence score + brand carry) |
| **Status** | Implemented |
| **Priority** | P1 |
| **Crux** | On synthetic midroll fixtures covering end-bleed, late-start, question-hook miss, and single-sentence underwriting, `HeuristicContentSegmenter` (`heuristic-cue-v6`) matches hand-golden ranges at IoU ≥ **0.5** with end error ≤ **2.0 s** and **0** overlap into host-resume spans; existing spike / three-sponsor / opening floors stay green. |

## PRD / spec references

- PRD §4 — Differentiator 2 (superfluous / tangential span detection)
- `docs/adr/012-content-segmentation-approach.md` — approach amendment to `heuristic-cue-v6`
- `docs/adr/013-segmentation-integration.md` — `IntervalSource.unrelatedContent` mapping unchanged
- `docs/adr/000-foundations.md` — TimedWord schema / verify

## Goal

Replace brittle span-grow ad detection with sentence-scored hysteresis + brand-name carry so midroll boundaries stop skipping show content and missing ad bodies — measured on fixtures and offline corpus metrics, not show-specific strings.

## Deliverables

- `PodWash/PodWash/HeuristicContentSegmenter.swift` — `heuristic-cue-v6`
- `PodWash/PodWash/IntervalCache.swift` — fingerprint `segmenter:heuristic-cue-v6`
- ADR-012 amendment (v6)
- `scripts/build_segmenter_cli.sh` + `Tools/SegmenterCLI/` — eval runs shipped Swift
- `scripts/ad_eval_*` — pinned corpus, `base.en`, time-weighted metrics, diff-labeling
- Fixtures: `midroll_closer_resume_*`, `question_hook_continuity_*`, `missed_opener_recovery_*`, `single_sentence_read_*`
- Regenerated `segmentation-benchmark-results.json` (`approach: heuristic-cue-v6`)

## Depends on

- Slice 18 / 19 (Done) — segmenter protocol + pipeline wiring

**Parallelizable:** No vs other `HeuristicContentSegmenter` / interval-cache fingerprint edits

## Out-of-scope

- Embedding / CoreML topic-shift segmenter (follow-up if corpus plateaus)
- Show-specific lexicon (TAL titles, act markers)
- Seek-bar / transcript paint wiring (already follows intervals)
- CarPlay

## Fixture strategy (pinned — QA test spec)

| Asset | Path | Role |
|-------|------|------|
| Midroll end-bleed | `Fixtures/segmentation/midroll_closer_resume_{transcript,golden}.json` | AC1 — closer + host resume at **19.0 s** |
| Question hook | `Fixtures/segmentation/question_hook_continuity_{transcript,golden}.json` | AC2 — hook must not truncate ad body |
| Late opener | `Fixtures/segmentation/missed_opener_recovery_{transcript,golden}.json` | AC3 — recover from `"This message comes from"` |
| Single sentence | `Fixtures/segmentation/single_sentence_read_{transcript,golden}.json` | AC4 — ≥ **5.0 s** underwriting read |
| Opening floor | `Fixtures/segmentation/opening_no_sponsor_anchor_transcript.json` | AC5 — **0** segments in `[0, 180)` |
| Three sponsors | `Fixtures/segmentation/three_sponsor_{transcript,golden}.json` | AC6 — **3** clusters, IoU ≥ **0.5**, FP **0** |
| Spike benchmark | `Fixtures/segmentation/segmentation-benchmark-results.json` | AC7 — P ≥ **0.700**, R ≥ **0.500**, `approach == heuristic-cue-v6` |
| Provenance | `Fixtures/segmentation/*_provenance.md` | Hand-scripted labels — **never** from segmenter output |

**Metric contract (AC1–AC4, AC6):** one predicted segment per fixture (except three-sponsor). Match golden with temporal IoU **≥ 0.5**; boundary error **≤ 2.0 s** where AC pins end/start tolerance.

## Acceptance criteria

- [ ] 1. Unit: `midroll_closer_resume` — exactly 1 segment; end within **±2.0 s** of golden; **no** coverage after host resume start (**19.0 s**).
- [ ] 2. Unit: `question_hook_continuity` — exactly 1 segment; IoU ≥ **0.5** vs golden spanning opener through CTA URL.
- [ ] 3. Unit: `missed_opener_recovery` — segment start within **±2.0 s** of `"This message comes from"`; IoU ≥ **0.5**.
- [ ] 4. Unit: `single_sentence_read` — IoU ≥ **0.5** on ≥ **5.0 s** underwriting read.
- [ ] 5. Unit: opening fixture still yields **0** segments overlapping **`[0, 180)`**.
- [ ] 6. Unit: three-sponsor fixture — exactly **3** segments; IoU ≥ **0.5** each; FP **0**.
- [ ] 7. Fast spike benchmark artifact recomputes precision ≥ **0.700**, recall ≥ **0.500**; `approach == heuristic-cue-v6`.
- [ ] 8. Interval cache fingerprint material includes `segmenter:heuristic-cue-v6`.
- [ ] 9. Full suite green via `scripts/verify.sh` (ship gate).

## Verification mapping

| AC# | Test file | Test method | Notes |
|-----|-----------|-------------|-------|
| 1 | `PodWashTests/SegmentationSpikeTests` | `testMidrollClosesBeforeHostResume` | Exactly 1 segment; IoU ≥ **0.5**; end ±2.0 s; no bleed past **19.0 s** |
| 2 | `PodWashTests/SegmentationSpikeTests` | `testQuestionHookContinuityKeepsAdBody` | Exactly 1 segment; IoU ≥ **0.5** opener→CTA |
| 3 | `PodWashTests/SegmentationSpikeTests` | `testMissedOpenerRecoveryStartsAtMessageComesFrom` | Start ±2.0 s of `"This message comes from"`; IoU ≥ **0.5** |
| 4 | `PodWashTests/SegmentationSpikeTests` | `testSingleSentenceUnderwritingReadDetected` | IoU ≥ **0.5** on ≥ **5.0 s** read |
| 5 | `PodWashTests/SegmentationSpikeTests` | `testOpeningWithoutSponsorAnchorProducesNoEarlySegment` | **0** segments overlapping `[0, 180)` |
| 6 | `PodWashTests/SegmentationSpikeTests` | `testThreeSponsorClustersMatchGoldenIoU` | **3** segments; IoU ≥ **0.5** each; FP **0** |
| 7 | `PodWashTests/SegmentationSpikeTests` | `testPrecisionRecallAgainstGolden`, `testDecisionArtifactRecorded`, `testBenchmarkArtifactExistsAndNonEmpty` | `approach == heuristic-cue-v6`; P ≥ **0.700**, R ≥ **0.500** |
| 8 | `PodWashTests/IntervalCacheTests` | `testSegmenterFingerprintIncludesHeuristicCueV6` | v5 cache miss after `segmenter:heuristic-cue-v6` bump |
| — | `PodWashTests/SegmentationSpikeTests` | `testSlice34FixtureGoldenIntegrity` | Structural: goldens + provenance independent of segmenter |
| 9 | — | — | Unfiltered `scripts/verify.sh` |

## Verification commands

```bash
scripts/verify.sh -only-testing:PodWashTests/SegmentationSpikeTests
scripts/verify.sh -only-testing:PodWashTests/IntervalCacheTests
scripts/verify.sh
```

## Verification record (QA fills at Verify)

```
VERIFY RESULT: exit=0 total=16 passed=16 failed=0 skipped=0 filtered=1 bundle=build/test-results/verify-20260716-145910.xcresult tier=3 class=tests elapsed_s=27
```

Surgical ACs 1–8 green. Ship-gate Done still requires unfiltered `scripts/verify.sh` (tier-3 filtered=0).

Corpus evidence: `PodWash/PodWashTests/Fixtures/segmentation/ad-eval-metrics-v6-evidence.json` + `tmp/ad-eval/FINDINGS.md` (TAL 891 provisional diff-label baseline).

## Plan review record

```
ADR review: waived for local-dev implementation of accepted plan (coordinator session); ADR-012 amended in-tree
Test spec (2026-07-16): QA authored — AC1–AC8 mapped in SegmentationSpikeTests + IntervalCacheTests; four hand-goldens + provenance (`*_provenance.md`); benchmark pins `heuristic-cue-v6`; structural `testSlice34FixtureGoldenIntegrity` guards fixture anchors
Test spec review: (pending Architect readonly)
```

## Standing dogfood

- TAL **891** — Capital One end (~8:52), Whole Foods start (~30:54), strawberry.me body (~31:56)

## Role artifacts

| Role | Artifact |
|------|----------|
| Architect | ADR-012 v6 amendment |
| QA | Fixture goldens + SegmentationSpikeTests |
| Engineer | HeuristicContentSegmenter v6 + cache fingerprint + CLI |
