# Task 020 — Transcript affordance missing when intervals already cached

| Field | Value |
|-------|-------|
| **ID** | 020 |
| **Title** | Transcript affordance missing when intervals already cached |
| **Status** | In Progress |
| **Kind** | fix |
| **Priority** | P1 |
| **Area** | `PodWash/PodWash/AnalysisPipeline.swift`, `PodWash/PodWash/TranscriptCache.swift`, `PodWash/PodWash/AppShellModel.swift`, `PodWash/PodWash/EpisodeListView.swift`, `PodWash/PodWash/AppShellView.swift`, `PodWash/PodWashTests/AnalysisPipelineTests.swift`, `PodWash/PodWashUITests/TranscriptUITests.swift` |
| **Crux** | When an episode has cached analysis intervals (complete green/yellow timeline) but no `TranscriptCache` file, the next cleaning-on `analyze` / play prepare path persists a transcript so `episode.viewTranscript` and `playback.viewTranscript` become available. |

## Outcome

**Observed (device, 2026-07-15):** TAL episode **981 The Test Case**; latest build; **Clean Profanity** on; super seek bar shows **green + yellow** (analysis complete, ads detected); **no** transcript control on the episode row (`episode.viewTranscript`) or full player (`playback.viewTranscript`).

**Expected:** After Slice 26, a completed analysis that leaves intervals on disk also leaves a readable transcript (or the next analyze backfills it). Affordance appears so the user can verify ASR words and timestamps.

**Likely cause (intake):** ADR-022 / `AnalysisPipeline` — interval **cache hit skips transcript write**. Episodes analyzed before Slice 26 (or any path that stored intervals without a transcript) stay forever without a transcript file until a cold miss.

**Framing:** If a test seeds interval cache only (no transcript), runs `analyze` with cleaning, then asserts `TranscriptCache.exists` and UI affordances appear, we never need to guess where the button went.

## Acceptance criteria

- [ ] 1. Unit test (`AnalysisPipeline`): seed `IntervalCache` with ≥ **1** interval for episode `"fixture-transcript-backfill"`, leave `TranscriptCache` empty; call `analyze` (injected transcript of **5** words allowed for speed) → after return, `TranscriptCache.load` is non-nil with word count **5**; second call does not require inventing a weaker cache-hit contract for episodes that already have a transcript.
- [ ] 2. Unit test (same setup, **no** injected transcript / ASR spy returning **5** words): interval cache hit + missing transcript still results in transcript store (spy `transcribe` count **≥ 1** on that call) — documents that “hit but no transcript” is not a silent no-op for transcript.
- [ ] 3. UI test (fixture: intervals on disk, transcript file absent, cleaning on, local audio): open show → row 0 has **no** `episode.viewTranscript` initially **or** after first play/prepare within **10.0** s `episode.viewTranscript` **or** `playback.viewTranscript` becomes hittable (pick one stable entry in the test; document which). Assert existence within timeout — not visual review.

## Surgical test scope

| AC# | Test id | New? |
|-----|---------|------|
| 1 | `PodWashTests/AnalysisPipelineTests/testIntervalCacheHitWithMissingTranscriptPersistsTranscript()` | yes |
| 2 | `PodWashTests/AnalysisPipelineTests/testIntervalCacheHitWithMissingTranscriptInvokesASRForBackfill()` | yes |
| 3 | `PodWashUITests/TranscriptUITests/testTranscriptAffordanceAppearsAfterBackfillWhenIntervalsCached()` | yes |

## Authorized test changes

- (none — bug fix; do not weaken Slice 26 cache-hit stability asserts for the happy path where transcript already exists)

## Depends on

- None

## Out of scope

- Highlighting profanity words in transcript text (Slice 26 OOS)
- Upgrading Whisper model / ASR recall (task-019 / possible follow-up slice)
- Painting mute markers on the super seek bar (slice-27)
- Changing ADR-022 cache key or listened/skipped-ad classification rules

## Human checklist

- (none — automatable)

## Verification record

> Loop writes `VERIFY RESULT:` here. For tasks, `tier=2` and `filtered=1` are valid for Done.

```
VERIFY RESULT: exit=0 total=15 passed=15 failed=0 skipped=0 filtered=1 bundle=build/test-results/verify-20260715-115732.xcresult tier=2 class=tests
```
