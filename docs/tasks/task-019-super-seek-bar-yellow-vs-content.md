# Task 019 — Super seek bar yellow does not match skippable ads

| Field | Value |
|-------|-------|
| **ID** | 019 |
| **Title** | Super seek bar yellow regions do not match skippable ad content |
| **Status** | Done |
| **Done at** | 2026-07-15T17:35:25Z |
| **Kind** | fix |
| **Priority** | P1 |
| **Area** | `PodWash/PodWash/AnalysisTimelineModel.swift`, `PodWash/PodWash/AppShellModel.swift`, `PodWash/PodWash/AnalysisPipeline.swift`, `PodWash/PodWash/PlaybackCoordinator.swift`, `PodWash/PodWash/HeuristicContentSegmenter.swift`, `PodWash/PodWashTests/AnalysisTimelineModelTests.swift`, `PodWash/PodWashTests/ProductionAnalysisWiringTests.swift` |
| **Crux** | With channel cleaning on, Skip ads on, and analysis complete, yellow buckets on `playback.superSeekBar` come only from `.unrelatedContent` intervals that are also applied as skip on `PlaybackEngine` — a playable host-content stretch with no overlapping skip must not be painted as a yellow-dominant opening when the fixture has no early ads. |

## Outcome

**Observed (device, 2026-07-15):** This American Life **891 “The Test Case”** (~72:05), downloaded, **Clean channel** on, **Skip ads** on, analysis complete. Full-player super seek bar (`playback.superSeekBar`) shows a long **yellow** opening (~first 10+ minutes). At elapsed **2:07** (playhead still in that yellow band) audio is **real podcast content**. Manual jump into a **green** band also sounds like real content. Colored sections feel unrelated to what is heard. Yellow **should** mean skippable ad/unrelated spans.

**Expected:** When Skip ads is on, yellow on the completed bar aligns with applied `.unrelatedContent` **skip** intervals (Slice 20 / ADR-018 contract: yellow = bucket overlaps an `adRange`). Continuous host content with no skip in that time must read as **green** (modulo intentional 12-bucket coarseness — see Out of scope). Skip must fire when playback enters a true ad span.

**Framing:** If a fixture with **no** unrelated intervals in `[0, bucketWidth)` proves the first bucket is **green**, and a mid-episode-only ad paints yellow **only** on overlapping buckets while those same intervals are scheduled as skip, we never need to re-listen for “opening is yellow but I’m hearing the show.” TAL 891 remains a human checklist for detector false positives; do not bend paint tests to match a bad segmenter.

## Debug notes (intake)

| Observation | Proves | Does not prove |
|-------------|--------|----------------|
| Yellow opening + content at 2:07 | Either false-positive `adRanges`, paint≠schedule wiring, or coarse bucket covering a short early ad + long content | Exact detector spans without Console/cache dump |
| Green also “sounds like content” | Compatible with correct green; does not prove yellow is correct | — |
| Skip ads + channel cleaning on | Unrelated projection path should be enabled | That skip observers fired on this session |
| Slice 20 contract | Whole ~6 min bucket turns yellow if **any** ad overlaps | User-visible “first 10 min all ads” without checking interval list |

**Ranked hypotheses**

1. **H1 — Detector over-flags early TAL as unrelated** → yellow correct for bad intervals; skip may jump oddly or skip short pods while most of the yellow band is still playable content. Fix class: segmenter / golden (escalate to slice if wiring ACs are green).
2. **H2 — Paint uses a different interval set than applied skip** (`union` / `adRangeIntervals` vs projected playback intervals) → yellow without matching skip (or skip without yellow). Fix class: `AppShellModel.publishTerminalPlaybackAnalysisSnapshot` / pipeline projection.
3. **H3 — Coarse buckets only** → short early ad paints 1–2 buckets yellow while 2:07 is still content inside that bucket. Product may still want finer UI later; **not** this ticket’s Done gate unless fixture proves no early ad yet first bucket is yellow.

## Acceptance criteria

- [ ] 1. Unit (`AnalysisTimelineModel`): episode duration **4325.0 s** (≈72:05), complete snapshot, **no** `adRanges` → all **12** segments **green** (0 yellow).
- [ ] 2. Unit (`AnalysisTimelineModel`): same duration, single `adRange` **[600.0, 660.0)** → yellow **only** on buckets that overlap that range (bucket width = `4325/12`); bucket **0** (`[0, width)`) is **green**; at least one yellow bucket exists.
- [ ] 3. Unit/integration (wiring): channel cleaning on + unrelated skip enabled + local-file analyze fixture with unrelated intervals **only** at **[600.0, 660.0)** → (a) applied `PlaybackEngine` schedule includes those `.unrelatedContent` **skip** intervals, and (b) `playbackAnalysisSnapshot` / `segmentColors` yellow set equals buckets overlapping that range (same as AC2) — not the opening buckets.
- [ ] 4. Human checklist (non-blocking for factory Done): re-dogfood TAL 891 after AC1–3 green; if opening still yellow while hearing content and Console/cache shows large early unrelated spans, **Halt** with note and open segmenter follow-up — do not weaken AC1–3.

## Surgical test scope

| AC# | Test id | New? |
|-----|---------|------|
| 1 | `PodWashTests/AnalysisTimelineModelTests/testCompletedTimelineAllGreenWhenNoAdRanges()` | yes (or extend existing complete-yellow suite) |
| 2 | `PodWashTests/AnalysisTimelineModelTests/testYellowOnlyOnBucketsOverlappingMidEpisodeAd()` | yes |
| 3 | `PodWashTests/ProductionAnalysisWiringTests/testSeekBarYellowMatchesAppliedUnrelatedSkipIntervals()` | yes |

## Authorized test changes

- (none) — bug fix; new tests only. Do not weaken Slice 20 yellow-overlap or segmentation goldens.

## Depends on

- None

## Out of scope

- Changing the **12-bucket** equal-width contract or “any overlap → whole bucket yellow” rule (file a **tweak** if product wants finer ad paint).
- Mini-player-only chrome (report was full player / `playback.superSeekBar`; screenshot shows Done + transport).
- Live Whisper / TAL detector precision as factory Done (human checklist + escalate).
- Profanity mute coloring (yellow is ads only — see task-015).
- CarPlay / lock-screen timeline.

## Human checklist

- [ ] iPhone: TAL 891 downloaded; Clean channel **on**; Skip ads **on**; analysis complete.
- [ ] Full player: note which buckets are yellow; play from 0 without scrubbing — confirm skips fire on true ads.
- [ ] At ~2:00, if still in a yellow band hearing host content, capture Console `preparePlayback` / unrelated counts or cached interval dump; attach to Halt if AC1–3 already green.

## Verification record

> Loop writes `VERIFY RESULT:` here. For tasks, `tier=2` and `filtered=1` are valid for Done.

```
VERIFY RESULT: exit=0 total=21 passed=21 failed=0 skipped=0 filtered=1 bundle=build/test-results/verify-20260715-113445.xcresult tier=2 class=tests
```
