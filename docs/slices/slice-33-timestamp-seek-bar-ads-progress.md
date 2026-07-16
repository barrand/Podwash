# Slice 33 — Timestamp seek-bar ads + analysis progress chrome

| Field | Value |
|-------|-------|
| **ID** | 33 |
| **Title** | Timestamp seek-bar ads + analysis progress chrome |
| **Status** | In Progress |
| **Priority** | P3 |
| **Crux** | While cleaning analysis is in flight, player chrome shows **only** an analyzing affordance + overall analysis progress (no 12-segment green/blue/grey/yellow); after analysis completes, `playback.superSeekBar` paints **timestamp-proportional** yellow bands from applied `.unrelatedContent` **skip** intervals (same set as transcript `skippedAd`) over green content — a **30.0 s** preroll yellows ≈ **30/duration** of bar width, not whole multi-minute buckets — while progressive early play after the first chunk remains. |

## PRD / spec references

- PRD §2 — seek/scrubbing chrome
- PRD §3 — clear UI for analysis in progress; cleaning is dynamic
- `docs/adr/000-foundations.md` — AX / offline verify
- `docs/adr/018-analysis-timeline.md` — **supersede** player yellow = whole-bucket overlap (Slice 20 row bar already retired by task-026)
- `docs/adr/021-progressive-playback-super-seek-bar.md` — keep early-play / first-chunk start; **retire** in-flight segment-color UI + frontier-colored seek UX for this product direction
- `docs/adr/023-super-seek-bar-mute-markers.md` — red mute overlays stay; yellow becomes overlay-style timestamp bands (mute pattern)
- `docs/adr/022-transcript-cache.md` — transcript `skippedAd` is the semantic reference for ad yellow

## Goal

Make the super seek bar match what users already trust: transcript ad yellow and real skip intervals. Kill the misleading in-flight 12-bucket paint; show simple analysis progress until done, then green + timestamp yellow (ads) + existing red mute markers.

## Intake decisions (locked)

| Decision | Choice |
|----------|--------|
| In-flight segment colors | **Remove** — no green/blue/grey/yellow 12-bucket (or other segment) paint while analyzing |
| In-flight chrome | Analyzing animation/affordance + **overall analysis progress** (`processedEnd / duration` or equivalent) only |
| Complete chrome | Green content track + **timestamp-proportional yellow** ad bands + existing **red** mute markers |
| Yellow source of truth | Applied `.unrelatedContent` **skip** intervals — **same set** as transcript `skippedAd` / engine skips (not coarse buckets, not a divergent paint list) |
| Progressive **playback** | **Keep (A)** — audio may start after first analysis chunk; progress UI until complete, then swap to timestamp yellow/green bar |
| Seek while in flight | Architect pins: either disable colored seek / clamp to duration normally, or keep a simple playhead without segment frontier UI — **must not** require 12-bucket grey territory |
| Mini player | Same complete paint contract when complete; in-flight may show progress or analyzing state (UX pins) — no separate false yellow |
| Segmenter / skip detection | **Out of scope** — intervals already correct on dogfood when transcript + skip agree |
| CarPlay / lock screen | Out of scope |

## Deliverables

- ADR — `docs/adr/030-timestamp-seek-bar-ads-progress.md` (supersedes ADR-018 **player** yellow-bucket rule; revises ADR-021 in-flight chrome; yellow overlay model parallel to ADR-023 mute markers; AX contract)
- UX spec `docs/slices/slice-33-ux.md` — in-flight progress UI, complete yellow/green layout, identifiers, fixture scenarios
- Retire publishing/consuming in-flight `segmentColors` (ready/processing/pending dance) on player chrome
- `SuperSeekBarModel` (+ view): timestamp-normalized **ad bands** from unrelated skips; paint yellow by fraction of duration
- Wire yellow bands from **applied/cached playback** unrelated skips (parity with `TranscriptViewModel` skip set)
- Analysis progress control: determinate progress from pipeline `processedEnd` / duration (or Architect-named equivalent)
- Migrate / authorize changes to Slice 20/25/27 tests that assert whole-bucket yellow or in-flight `ready:N,processing:N,pending:N` on the **player** bar

## Depends on

- Slice 25 (Done) — progressive playback + super seek bar
- Slice 27 (Done) — mute markers (overlay pattern to mirror for ads)
- Slice 30 (Done or Implemented) — mini hosts shared bar when complete paint applies

**Parallelizable:** No vs concurrent `SuperSeekBarView` / `AnalysisTimelineModel` / `PlaybackControlsView` edits (serialize with Slice 31 if both touch `AppShellModel`).

## Out-of-scope

- Changing `HeuristicContentSegmenter` / live ASR precision (task-025 class)
- Reopening task-019 / 022 wiring as “intervals wrong” — this slice assumes applied skips are the paint source
- CarPlay / lock-screen timeline
- Episode-row analysis timeline (already retired)
- Auto-play on session restore (Slice 31)
- Redesigning mute-marker red semantics

## Acceptance criteria

Automatable only. **XCTSkip is not allowed on core ACs.**

- [ ] 1. Unit (`SuperSeekBarModel` or successor): duration **3600.0 s**, single unrelated skip **`[0.0, 30.0)`** → yellow band normalized width **`30/3600 ± 0.002`** (start **0**, end **0.00833…**); **no** requirement that any 12-bucket index is wholly yellow.
- [ ] 2. Unit: same duration, skips **`[0.0, 30.0)`** and **`[1800.0, 1860.0)`** → exactly **2** yellow bands with those normalized ranges (± **0.002**); intervening content has **no** yellow coverage.
- [ ] 3. Unit (parity): given the same applied unrelated-skip interval list, every transcript word marked `skippedAd` by `TranscriptViewModel.make` overlaps a yellow band range, and no yellow band exists outside the union of those skips (same list passed to bar model).
- [ ] 4. Unit / UI seam (in-flight): while analysis incomplete (`processedEnd < duration`), player chrome exposes analysis progress AX (identifier pinned by UX, e.g. `playback.analysisProgress`) with value reflecting **`processedEnd/duration`** within **±0.02**, and **does not** expose in-flight `ready:N,processing:N,pending:N` segment paint on `playback.superSeekBar` (bar either absent, colorless playhead-only, or Architect-pinned non-segment state — UX/ADR choose one; tests assert **no** segment triple while incomplete).
- [ ] 5. Progressive playback retained: stepped fixture still allows play after first chunk (`processedEnd = 30.0` on **120.0 s** fixture) within existing Slice 25 start-gate tolerance (**0.5 s** / prior AC) — without requiring in-flight segment color AX.
- [ ] 6. UI test (complete fixture with preroll skip **`[0.0, 30.0)`**, duration **≥ 600.0 s**): after terminal analysis, `playback.superSeekBar` yellow coverage (AX key pinned by UX, e.g. `adBands:1` + normalized extents, or equivalent falsifiable grammar) matches the preroll span within **±1.0 s** wall-time (or ± **0.002** normalized); bar is **not** yellow for a contiguous opening longer than **60.0 s** when only a **30.0 s** skip exists.
- [ ] 7. UI test (complete + mute fixture): red mute markers still present (`muteMarkers:N` **≥ 1** or existing Slice 27 contract); yellow bands remain ads-only (profanity does not create yellow).
- [ ] 8. Full suite green via `scripts/verify.sh` (**exit 0, failed 0, skipped 0**).

## Verification mapping

| AC# | Test file | Test method | Notes |
|-----|-----------|-------------|-------|
| 1 | `PodWash/PodWashTests/SuperSeekBarAdBandTests.swift` | `testPrerollYellowWidthMatchesTimestampFraction` | 30/3600 |
| 2 | `PodWash/PodWashTests/SuperSeekBarAdBandTests.swift` | `testTwoAdBandsNoSpuriousCoverage` | mid-episode second skip |
| 3 | `PodWash/PodWashTests/SuperSeekBarAdBandTests.swift` | `testYellowBandsMatchTranscriptSkippedAdIntervals` | shared skip list |
| 4 | `PodWash/PodWashTests/AnalysisProgressChromeTests.swift` | `testInFlightShowsProgressWithoutSegmentColors` | no ready/processing/pending on player |
| 5 | `PodWash/PodWashTests/ProgressivePlaybackTests.swift` | `testPlaybackStartsAfterFirstChunkWithoutSegmentColorGate` | migrate/extend Slice 25 start gate |
| 6 | `PodWash/PodWashUITests/SuperSeekBarUITests.swift` | `testCompleteBarYellowMatchesPrerollSkipNotWholeBuckets` | fixture preroll 30 s |
| 7 | `PodWash/PodWashUITests/SuperSeekBarUITests.swift` | `testMuteMarkersRemainWithTimestampAdBands` | mute + ads |
| 8 | — | — | Unfiltered `scripts/verify.sh` |

**Expected authorized migrations (QA):** any player UITest/unit asserting in-flight `ready:N,processing:N,pending:N` on `playback.superSeekBar`; complete yellow = whole-bucket overlap asserts (`AnalysisTimelineModelTests` player-facing / SuperSeekBar fixtures); Slice 25 seek-clamp-to-grey ACs if frontier UI is retired — PM/Architect pin replacement (disable seek past playable, or clamp to duration) in ADR before QA freezes names.

## Verification commands

```bash
# Fast inner loop (NOT sufficient for Done):
scripts/verify.sh -only-testing:PodWashTests/SuperSeekBarAdBandTests
scripts/verify.sh -only-testing:PodWashTests/AnalysisProgressChromeTests
scripts/verify.sh -only-testing:PodWashUITests/SuperSeekBarUITests

# Done gate — FULL suite, zero failures, zero skips:
scripts/verify.sh
```

## Verification record (QA fills at Verify)

```
VERIFY RESULT: exit=0 total=7 passed=7 failed=0 skipped=0 filtered=1 bundle=build/test-results/verify-20260716-121112.xcresult tier=2 class=tests
```

## Plan review record (coordinator fills before downstream roles)

```
ADR review (2026-07-16): (pending) QA cleared — pipeline worker finished PM cleared — pipeline worker finished
Test spec review (2026-07-16): Architect cleared — pipeline worker finished
```

## Done gate

- [ ] Every AC mapped to a test; all rows in the mapping table filled
- [ ] **Full suite green:** unfiltered `scripts/verify.sh` exit 0, failed 0, skipped 0
- [ ] Verification record pasted above
- [ ] Auto-commit on green: `slice-33: timestamp seek-bar ads + analysis progress`

## Tickets (optional)

| Ticket | Owner role | AC subset | Depends on |
|--------|------------|-----------|------------|
| — | — | — | — |

## Role artifacts

| Role | Required? | Artifact |
|------|-----------|----------|
| PM | **Required** | This story |
| Architect | **Required** | `docs/adr/030-timestamp-seek-bar-ads-progress.md` |
| UX | **Required** | `docs/slices/slice-33-ux.md` |
| QA | **Required** | Ad-band + progress chrome tests; migrate Slice 25/27 player AX |
| Engineer | **Required** | Progress chrome + timestamp yellow overlays; retire in-flight segment paint |

## Related (out of scope — do not depend)

- Done task-019 / task-022 (wiring); Implemented task-025 (segmenter) — this slice is the deferred **finer yellow paint** + in-flight chrome reset, not a segmenter reopen
- Slice 31 — session restore (orthogonal)
