# Task 031 — Completed analysis must surface recognized ad spans

| Field | Value |
|-------|-------|
| **ID** | 031 |
| **Title** | Completed analysis must surface recognized ad spans in player and transcript |
| **Status** | Implemented |
| **Kind** | fix |
| **Priority** | P1 |
| **Area** | `PodWash/PodWash/AnalysisPipeline.swift`, `PodWash/PodWash/PlaybackCoordinator.swift`, `PodWash/PodWash/AppShellModel.swift`, `PodWash/PodWash/IntervalCache.swift`, `PodWash/PodWash/MiniPlayerBar.swift`, `PodWash/PodWash/TranscriptViewModel.swift`, `PodWash/PodWashTests/ProductionAnalysisWiringTests.swift` |
| **Crux** | When completed analysis recognizes an `.unrelatedContent` ad span, that exact span reaches the now-playing mini-player seek bar and transcript view model; neither surface may silently show an all-green/no-highlight result. |

## Outcome

**Observed (device, 2026-07-24):** After downloading and waiting for analysis of This American Life **890: Maximal Americanness**, opening the mini player showed only green seek-bar coverage (with red profanity markers) and the transcript contained no yellow ad highlights. The terminal state gave no evidence that ad recognition had run or that its result reached either UI surface.

**Expected:** When ad recognition produces an unrelated-content/ad span and ad skipping is enabled, the completed analysis result is retained and projected consistently: the mini-player seek bar contains a yellow band overlapping that span, and transcript words overlapping it are marked `skippedAd`. A genuine zero-ad result may remain all green, but a recognized positive ad result must not be lost between analysis completion and presentation.

**Framing:** If a production-shaped downloaded-episode fixture returns one known ad span and a test can assert that both the terminal mini-player snapshot and transcript view model expose it, we never need to manually infer whether recognition ran from an all-green player.

## Acceptance criteria

- [ ] 1. Production wiring test: with channel cleaning and Skip ads enabled, analyze a downloaded local fixture through the production `AppShellModel` / `PlaybackCoordinator` path using a deterministic analyzer result containing one `.unrelatedContent` `.skip` interval. After terminal completion, `cachedIntervals` retains that interval and the terminal `playbackAnalysisSnapshot.adRanges` contains its time range (within the project’s existing interval tolerance).
- [ ] 2. Same completed session: the mini-player seek-bar model exposes at least one yellow ad band overlapping the deterministic ad interval; an unrelated green-only/profanity-only projection is not accepted for the positive-ad fixture.
- [ ] 3. Same completed session: `presentTranscriptForNowPlaying()` creates a `TranscriptViewModel` whose words overlapping the deterministic ad interval have `skippedAd == true`, while a word outside the interval does not. The transcript must receive the same applied ad set used by player chrome.
- [ ] 4. Cache/reopen coverage: construct a fresh shell/presentation path for the undeleted fixture after completion and assert the persisted positive ad interval still yields the same transcript `skippedAd` words and yellow-band overlap, without re-running the analyzer.

## Surgical test scope

| AC# | Test id | New? |
|-----|---------|------|
| 1 | `PodWashTests/ProductionAnalysisWiringTests/testCompletedPositiveAdAnalysisRetainsIntervalForPlayerChrome()` | yes |
| 2 | `PodWashTests/ProductionAnalysisWiringTests/testCompletedPositiveAdAnalysisShowsYellowMiniPlayerBand()` | yes |
| 3 | `PodWashTests/ProductionAnalysisWiringTests/testCompletedPositiveAdAnalysisHighlightsTranscriptWords()` | yes |
| 4 | `PodWashTests/ProductionAnalysisWiringTests/testCachedPositiveAdAnalysisSurvivesFreshShellPresentation()` | yes |

## Authorized test changes

- (none — bug fix; preserve current synthetic `SuperSeekBarAdBandTests` and `TranscriptViewModelTests` coverage.)

## Depends on

- None

## Out of scope

- Ad-recognition precision/recall or deciding whether This American Life 890 contains a real ad; this ticket protects recognized positive results from being dropped after analysis.
- Changing yellow/red/green semantics, seek-bar geometry, or the user’s Skip ads settings.
- Analysis-result retention generally; Task 030 owns the broader cache lifecycle and is related but not a dependency.
- A device-only assertion that any arbitrary downloaded episode must contain an ad.

## Human checklist

- (none — automatable)

## Verification record

> Loop writes `VERIFY RESULT:` here. For tasks, `tier=2` and `filtered=1` are valid for Done.

```
VERIFY RESULT: exit=0 total=22 passed=22 failed=0 skipped=0 filtered=1 bundle=build/test-results/verify-20260725-001224.xcresult tier=2 class=tests
```
