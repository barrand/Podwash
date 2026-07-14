# Task 011 — Analysis timeline in mini and full player

| Field | Value |
|-------|-------|
| **ID** | 011 |
| **Title** | Analysis timeline in mini and full player |
| **Status** | Queued |
| **Kind** | tweak |
| **Priority** | P2 |
| **Area** | `PodWash/PodWash/MiniPlayerBar.swift`, `PodWash/PodWash/PlaybackControlsView.swift`, `PodWash/PodWash/AppShellModel.swift`, `PodWash/PodWash/AnalysisTimelineView.swift`, `PodWash/PodWashUITests/LibraryUITests.swift`, `PodWash/PodWashUITests/PlaybackControlsUITests.swift` (or new player-timeline tests) |
| **Crux** | When the now-playing episode has a **completed** analysis snapshot (12-segment green/blue/grey/yellow contract from Slice 20), both `miniPlayerAnalysisTimeline` and `playbackAnalysisTimeline` are visible with matching `accessibilityValue` counts — not absent on device after play. |

## Outcome

**User expectation:** Skipper-style **super seek bar** — the colored 12-segment analysis timeline (green = ready, blue = processing, grey = pending, yellow = ad/unrelated when complete) — clearly visible in the **mini player** and **expanded full player**.

**What shipped (Slice 20, Done):** Timeline on **episode rows only** (`analysisTimeline` in `EpisodeListView`). Slice 20 UX + ADR-018 explicitly **deferred** mini-player and full-player chrome.

**Current gap:**
- `MiniPlayerBar` has optional `AnalysisTimelineView` (`miniPlayerAnalysisTimeline`) but only when `AppShellModel.playbackAnalysisSnapshot` is non-nil — **8 pt** tall, easy to miss, and **no UI tests** assert it.
- `PlaybackControlsView` (full player sheet) has **no** timeline at all — only elapsed time + transport (Slice 03).
- On device, streaming play (`!isLocalFile`) skips analysis in `playEpisode`, so snapshot stays nil and the mini bar never appears even with channel cleaning on.
- After analysis completes, episode **rows** retire the timeline (badge only); player chrome never picks up the terminal colored bar for ongoing playback.

**Desired:** Prominent colored timeline in mini + full player whenever the now-playing episode has analysis data (terminal snapshot from play-time analysis **or** rebuilt from cached intervals). Same color contract as Slice 20 / ADR-018. Bar tall enough to read on device (mini **≥ 12 pt**, full player **≥ 20 pt** segment strip height).

**Test gap:** `AnalysisTimelineUITests` covers episode rows only. `LibraryUITests` never queries `miniPlayerAnalysisTimeline`. No `playbackAnalysisTimeline` identifier exists.

## Acceptance criteria

- [ ] 1. UI test (`-UITestFixtureLibrary` + injected analysis timeline / local audio fixture seam): play episode with cleaning on → within **5 s**, `miniPlayerAnalysisTimeline` exists and `accessibilityValue` matches `^ready:\d+,processing:\d+,pending:\d+$` with segment sum **12** (terminal complete state e.g. `ready:12,processing:0,pending:0` when fixture pins full analysis).
- [ ] 2. UI test (same fixture): tap `miniPlayer` to expand → within **5 s**, `playbackAnalysisTimeline` exists with the **same** `accessibilityValue` as `miniPlayerAnalysisTimeline`.
- [ ] 3. Unit test: `AnalysisTimelineView` (or layout helper) full-player host uses segment strip height **≥ 20** pt; mini-player host **≥ 12** pt (assert configured frame/min height constant — not pixel snapshot).

## Surgical test scope

| AC# | Test id | New? |
|-----|---------|------|
| 1 | `PodWashUITests/LibraryUITests/testMiniPlayerShowsAnalysisTimelineWhenAnalysisComplete()` | yes |
| 2 | `PodWashUITests/LibraryUITests/testFullPlayerShowsMatchingAnalysisTimeline()` | yes |
| 3 | `PodWashTests/AnalysisTimelineViewLayoutTests/testPlayerChromeTimelineMinimumHeights()` | yes |

## Authorized test changes

- New tests above only; may extend Library launch args for a play-time analysis fixture (parallel to `-UITestFixtureAnalysisTimeline` row behavior).
- Do not weaken existing Slice 03 transport asserts (`playback.playPause`, seek buttons).

## Depends on

- Slice 20 (Done) — `AnalysisTimelineModel` color contract
- Slice 24 (Done) — production play + analysis wiring

## Halt reason

**Superseded by [Slice 25](../slices/slice-25-progressive-playback-super-seek-bar.md)** (2026-07-13 intake). Player-chrome timeline visibility, full-player bar, and interactive seek/playhead are in scope there. Do not reopen this task unless Slice 25 explicitly defers mini-player timeline to a follow-up.

## Out of scope

- Interactive scrub / drag seek on the colored bar (playback position playhead) — follow-up if desired
- CarPlay / lock-screen timeline
- Changing Slice 20 episode-row timeline behavior
- Re-running ASR on every play when intervals are already cached (reuse cache → snapshot)

## Human checklist

- [ ] iPhone: subscribed show, channel cleaning **on**, episode **downloaded**, play episode.
- [ ] Mini player: clearly see multi-color segment strip below title row.
- [ ] Tap mini player → full sheet: same strip visible above transport controls, taller than mini.

## Verification record

> Loop writes `VERIFY RESULT:` here. For tasks, `tier=2` and `filtered=1` are valid for Done.

```
VERIFY RESULT: (pending)
```
