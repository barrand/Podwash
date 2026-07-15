# Slice 25 — UX spec: Progressive playback + super seek bar

| Field | Value |
|-------|-------|
| **Slice** | 25 — Progressive playback + super seek bar |
| **Screen** | Expanded full player — `PlaybackControlsView` hosting `SuperSeekBarView` |
| **ADR** | [ADR-021](../adr/021-progressive-playback-super-seek-bar.md) (chunk contract, frontier clamp, identifier migration) |
| **Builds on** | [slice-03-ux.md](slice-03-ux.md) (transport + `playback.elapsed`), [slice-20-ux.md](slice-20-ux.md) (12-segment color contract + `accessibilityValue` format), [slice-23-ux.md](slice-23-ux.md) (library → mini-player → full-player sheet), [slice-21-ux.md](slice-21-ux.md) (`themePrimaryAccent` sentinel; transport ids unchanged) |
| **Slice story** | [slice-25-progressive-playback-super-seek-bar.md](slice-25-progressive-playback-super-seek-bar.md) |

## Scope note

**Full-player chrome only.** The super seek bar replaces the read-only `playbackAnalysisTimeline` strip in the expanded player sheet. The mini-player keeps the **read-only** `miniPlayerAnalysisTimeline` from task-011 (no interactive playhead, no tap-to-seek — out of scope). Episode-row `analysisTimeline` (Slice 20) is unchanged.

**No continuous slider scrub** — tap-to-seek and ±15 s buttons only (Slice 03 precedent; avoids flaky XCUITest drags).

## Layout

Vertical stack inside expanded `PlaybackControlsView`, top → bottom:

1. **Super seek bar** (`playback.superSeekBar`) — single interactive region combining:
   - **Segment strip** — 12 equal-width colored buckets (Slice 20 geometry: **120.0 s** → **10.0 s** per bucket) when segment colors are shown.
   - **Playhead** — vertical marker at `elapsed / duration` across the bar width (visible; no separate `accessibilityIdentifier`).
   - **Minimum height** — segment strip portion **≥ 20 pt** (inherits `AnalysisTimelineModel.fullPlayerTimelineHeight`); playhead may extend slightly above/below the strip.
2. **Time row** — horizontal pair:
   - **Elapsed** (`playback.elapsed`) — leading, monospaced `mm:ss`.
   - **Remaining** (`playback.remaining`) — trailing, monospaced `mm:ss` countdown to episode end.
3. **Transport row** — unchanged Slice 03: `playback.seekBack15` | `playback.playPause` | `playback.seekForward15`.
4. **Secondary row** — unchanged Slice 12: `speedButton`, `sleepTimerButton`, plus `themePrimaryAccent` sentinel (Slice 21).

**Z-order within super seek bar:** segment fills (bottom) → playhead marker (top). Grey/unprocessed tail is visible to the right of the green/blue frontier while analysis is in flight.

### Identifier migration

| Retired (full player) | Replacement |
|-----------------------|-------------|
| `playbackAnalysisTimeline` | `playback.superSeekBar` |

QA migrates `LibraryUITests.testFullPlayerShowsMatchingAnalysisTimeline` (and any other queries of `playbackAnalysisTimeline`) to `playback.superSeekBar` in the slice-25 test-spec commit. **`miniPlayerAnalysisTimeline` is unchanged** — mini/full parity ACs compare mini read-only strip to full super seek bar `accessibilityValue` when both show segment colors at terminal complete.

## Color contract

Reuse Slice 20 / ADR-018 semantics unchanged. `playback.superSeekBar` `accessibilityValue` uses `AnalysisTimelineModel.accessibilityValue(from:)` whenever segment colors are visible.

| Color | In-flight meaning | Complete meaning | AX bucket |
|-------|-------------------|------------------|-----------|
| **Green** | Bucket in `[0, processedEnd)` | Processed, non-ad bucket | `ready` |
| **Blue** | Bucket overlaps `[processingStart, processingEnd)` | — | `processing` |
| **Grey** | Not yet scanned | — | `pending` |
| **Yellow** | Hidden while `processedEnd < duration` | Bucket overlaps any `adRange` by **> 0 s** | `ready` |

**Precedence per bucket:** yellow (complete only) → blue → green → grey.

**Pinned progressive snapshots** (fixture + AC3–AC5):

| Phase | `processedEnd` | Processing window | `accessibilityValue` |
|-------|--------------|-------------------|----------------------|
| First chunk (AC3) | `30.0` | `[30.0, 40.0)` | `ready:3,processing:1,pending:8` |
| Mid freeze (AC5 setup) | `60.0` | `[60.0, 70.0)` | `ready:6,processing:1,pending:5` |
| Terminal (AC4) | `120.0` | idle | `ready:12,processing:0,pending:0` |

**Format** (machine-readable, no spaces):

```text
ready:<int>,processing:<int>,pending:<int>
```

Sums always equal **12** on the pinned **120.0 s** fixture.

## States

### Super seek bar display modes

| Mode | Segment colors | `playback.superSeekBar` `accessibilityValue` | Tap-to-seek frontier |
|------|----------------|-----------------------------------------------|----------------------|
| **Progressive in flight** (cleaning on, local cold play) | Green / blue / grey (yellow only at terminal) | `ready:N,processing:N,pending:N` | `processedEnd` from live snapshot |
| **Terminal / cache hit** (cleaning on) | Full bar including yellow ad buckets when applicable | Terminal e.g. `ready:12,processing:0,pending:0` | `duration` (no grey clamp) |
| **Cleaning off / no local file** | **Hidden** — playhead + time row only | **Omitted** (no count string; element still exists for tap-to-seek within `[0, duration]`) | `duration` |
| **Preparing, not yet playing** | First snapshot may already be visible | First-chunk counts when snapshot published | `processedEnd` when colors shown |

**No separate loading/error/empty** identifiers for the bar — if snapshot is momentarily nil before first chunk, Engineer seeds synchronously or hides colors until first snapshot (same discipline as Slice 20).

### Play / pause during progressive prepare

| Condition | `playback.playPause` icon | `accessibilityLabel` | `accessibilityValue` |
|-----------|---------------------------|----------------------|----------------------|
| `isPreparingPlayback && !isPlaying` | Waveform (analyzing) | `Analyzing` | `analyzing` |
| `isPlaying` (audio started after chunk 1) | Pause | `Pause` | `playing` |
| `!isPlaying && !isPreparingPlayback` | Play | `Play` | `paused` |
| Paused mid-playback while analysis continues | Play | `Play` | `paused` |

**Critical:** once `engine.isPlaying == true`, transport must **not** stay on the analyzing waveform even if `isPreparingPlayback` remains true (ADR-021 §4). AC3 asserts `playing` while the bar still shows first-chunk counts.

### Time labels

| Control | Visible format | `accessibilityValue` |
|---------|----------------|----------------------|
| `playback.elapsed` | `mm:ss` elapsed | Whole seconds, decimal string (e.g. `0`, `15`, `60`) — Slice 03 contract |
| `playback.remaining` | `mm:ss` remaining | Whole seconds, decimal string (e.g. `105`, `60`) |

**AC6 contract:** `Int(playback.elapsed value) + Int(playback.remaining value)` is **118–122** when episode duration is **120.0 s** (± **2 s** tick tolerance).

### Frontier clamp feedback

When the user requests a seek beyond `processedEnd` (tap-to-seek or ±15 s forward):

- **Behavior:** silent clamp to `processedEnd` via `SuperSeekBarModel.clampedSeek` — playhead and `playback.elapsed` jump to the frontier (AC5: tap at **90.0 s** with frontier **60.0 s** → elapsed Int **55–60**).
- **No** toast, banner, or haptic required for Done gate.
- **Visual:** playhead stops at the green/blue boundary; grey tail remains non-seekable.

### ±15 s buttons with active frontier

`playback.seekForward15` and `playback.seekBack15` use the same frontier clamp as tap-to-seek when segment colors are shown and `processedEnd < duration`. Seek back is never clamped below `0`. Not slice-AC-mapped; preserve Slice 03 backward behavior.

## Interaction: tap-to-seek

**Control:** `playback.superSeekBar` (full width of the bar, including playhead hit area).

**Gesture:** single **tap** (no drag / scrub).

**Mapping:**

```text
fraction = tapX / barWidth        // leading edge = 0.0, trailing edge = 1.0
requestedSeconds = fraction × episodeDuration
actualSeek = clamp(requestedSeconds, 0 … processedEnd)   // processedEnd = duration when no frontier
```

Engine calls `PlaybackEngine.seek(to: actualSeek)` (or shell equivalent) after clamp.

**AC5 test coordinate (pinned):** on the **120.0 s** fixture, tap at normalized offset **`dx = 0.75`** (=`90.0 / 120.0`), vertical center of the element:

```swift
let bar = app.descendants(matching: .any)["playback.superSeekBar"]
let coord = bar.coordinate(withNormalizedOffset: CGVector(dx: 0.75, dy: 0.5))
coord.tap()
```

Do **not** use `adjustable` slider APIs or drag gestures.

**Accessibility custom action (optional, not AC-mapped):** Engineer may add `Seek to position` for VoiceOver users; UI tests use the coordinate contract above.

**`accessibilityHint`:** `Tap to seek within analyzed audio. Seeks past unscanned audio move to the analyzed frontier.`

## Accessibility identifiers

| Control / region | `accessibilityIdentifier` | `accessibilityLabel` | `accessibilityValue` | `accessibilityHint` |
|------------------|---------------------------|----------------------|----------------------|---------------------|
| Super seek bar | `playback.superSeekBar` | `Playback position` | `ready:N,processing:N,pending:N` when segment colors shown; otherwise omitted | See Interaction |
| Elapsed time | `playback.elapsed` | `Elapsed time` | Whole seconds (decimal string) | — |
| Remaining time | `playback.remaining` | `Remaining time` | Whole seconds (decimal string) | — |
| Play/Pause | `playback.playPause` | `Play` / `Pause` / `Analyzing` | `playing` / `paused` / `analyzing` | Unchanged Slice 03 / 21 |
| Seek back 15 s | `playback.seekBack15` | `Seek back 15 seconds` | — | — |
| Seek forward 15 s | `playback.seekForward15` | `Seek forward 15 seconds` | — | — |
| Speed | `speedButton` | `Playback speed` | rate string | Unchanged |
| Sleep timer | `sleepTimerButton` | `Sleep timer` | `off` / armed state | Unchanged |
| Brand accent sentinel | `themePrimaryAccent` | `Brand primary accent` | `brandPrimary` | Unchanged Slice 21 |

**Retired globally in full player:** `playbackAnalysisTimeline` — must **not** appear after this slice.

**Unchanged mini-player:** `miniPlayer`, `miniPlayerPlayPause`, `miniPlayerAnalysisTimeline`.

**Unchanged shell navigation:** `libraryRoot`, `libraryCell_*`, `episodeList`, `episodeCell_*`, `tabLibrary`, etc. (Slice 23).

## Fixture modes

### `-UITestFixtureProgressivePlayback` (AC3–AC6)

| Concern | Value |
|---------|-------|
| Launch arg | `-UITestFixtureProgressivePlayback` |
| Persistence | In-memory store (same policy as `-UITestFixtureLibrary`) |
| Feed / library | Seeded library with **≥ 1** show and episodes; lands on **Library** tab |
| Audio | Bundled local file (**120.0 s** duration contract) |
| Cleaning | Channel + episode cleaning **on** for played episode |
| Analyzer | Progressive `SteppedEpisodeAnalyzer` (or equivalent) emitting **≥ 3** snapshots before terminal |
| Snapshot pacing | (1) `processedEnd=30`, processing `[30,40)`; (2) `processedEnd=60`, processing `[60,70)`; (3) terminal `processedEnd=120` |
| Partial intervals | After snapshot 1: ≥ 1 mute interval with `end ≤ 30.0` (AC1 / AC8 — unit scope) |
| Seek-freeze API | Fixture/test hook holds live snapshot at phase (2) for AC5 (`processedEnd=60`) until seek assertion completes |
| Network | **No** live network for play path |

**Typical launch:** `-UITestFixtureProgressivePlayback` **only** (do not combine with `-UITestFixtureAudio`, `-UITestFixtureFeed`, or other exclusive fixtures).

**Navigation to full player (all AC3–AC6 UI tests):**

1. Wait for `libraryRoot` (timeout **10 s**).
2. Tap `libraryCell_0` → wait for `episodeList`.
3. Ensure channel cleaning on if fixture does not default it (reuse Slice 09 toggle pattern when needed).
4. Tap `episodeCell_0` → wait for `miniPlayer` (**5 s**).
5. Tap `miniPlayer` (bar chrome, **not** `miniPlayerPlayPause`) → wait for `playback.playPause` (**5 s**).
6. If `playback.playPause` `accessibilityValue == "analyzing"`, tap once to start playback (AC3 allows up to **5 s** for `playing`).

### `-UITestFixtureLibraryAnalysisTimeline` (task-011 parity — migrated identifier)

Terminal complete analysis on player chrome. After slice 25, full-player query uses `playback.superSeekBar` with the same `accessibilityValue` as `miniPlayerAnalysisTimeline` (e.g. `ready:12,processing:0,pending:0`).

### Production (no fixture args)

Progressive start and super seek bar follow real analyzer pacing; slice ACs **do not** map production UI tests without fixtures.

## UI test scenarios

Mapped tests: `PodWashUITests/ProgressivePlaybackUITests.swift` (AC3–AC6). Use `app.descendants(matching: .any)["<identifier>"]` with pinned timeouts.

**Query helpers:** parse `playback.elapsed` / `playback.remaining` `accessibilityValue` as `Int` for numeric asserts; exact string match for `playback.superSeekBar` count values.

### `testPlaybackStartsWhileAnalysisInFlight` (AC#3)

1. Launch with `-UITestFixtureProgressivePlayback`; navigate to expanded full player (fixture navigation above).
2. If needed, tap `playback.playPause` to start playback.
3. Within **5.0 s**, assert `playback.playPause` `accessibilityValue == "playing"`.
4. **Concurrently** (same poll window), assert `playback.superSeekBar` `accessibilityValue == "ready:3,processing:1,pending:8"` exactly.
5. Assert value is **not** terminal `ready:12,processing:0,pending:0`.

### `testSeekBarReachesTerminalAnalysisState` (AC#4)

1. Launch with `-UITestFixtureProgressivePlayback`; navigate to expanded full player; start playback if needed.
2. Within **10.0 s** of first successful play start, assert `playback.superSeekBar` `accessibilityValue == "ready:12,processing:0,pending:0"`.
3. `playback.playPause` may still be `playing` (analysis complete does not imply paused).

### `testSeekClampsToProcessedFrontier` (AC#5)

1. Launch with `-UITestFixtureProgressivePlayback`; navigate to expanded full player; start playback.
2. Wait until `playback.superSeekBar` `accessibilityValue == "ready:6,processing:1,pending:5"` **or** invoke fixture freeze at `processedEnd = 60.0` (preferred — avoids race with terminal).
3. Fixture holds snapshot at `processedEnd = 60.0` for the seek step.
4. Tap-to-seek at **`dx = 0.75`** on `playback.superSeekBar` (requests **90.0 s** on **120.0 s** duration).
5. Within **2.0 s**, read `playback.elapsed` `accessibilityValue` as `Int` → assert **≥ 55** and **≤ 60**.

### `testElapsedAndRemainingSumToDuration` (AC#6)

1. Launch with `-UITestFixtureProgressivePlayback`; navigate to expanded full player; start playback.
2. Poll until `playback.elapsed` `accessibilityValue` as `Int` is **≥ 10** (timeout **15 s**).
3. Assert `playback.remaining` exists.
4. Let `elapsed = Int(playback.elapsed value)`, `remaining = Int(playback.remaining value)` → assert `elapsed + remaining` is **≥ 118** and **≤ 122**.

### UX smoke scenarios (not slice ACs; optional QA / Library migration)

#### `testFullPlayerSuperSeekBarMatchesMiniTimelineAtComplete` (migrates task-011 AC#2)

1. Launch `-UITestFixtureLibraryAnalysisTimeline`; play with cleaning on; wait for `miniPlayerAnalysisTimeline` terminal value.
2. Expand full player; assert `playback.superSeekBar` exists with the **same** `accessibilityValue` as `miniPlayerAnalysisTimeline`.
3. Assert `playbackAnalysisTimeline` does **not** exist.

#### `testCleaningOffHidesSegmentCounts` (optional)

1. Launch progressive or library fixture with cleaning off; play local audio.
2. Assert `playback.superSeekBar` exists; `accessibilityValue` does **not** contain `ready:`.
3. Assert `playback.elapsed` and `playback.remaining` exist.

## Verification mapping

| AC# | UX artifact | Test file / method |
|-----|-------------|-------------------|
| 1 | Progressive prepare gate (unit) | `ProgressivePlaybackTests.testPlaybackStartsAfterFirstChunkIntervalsApplied` |
| 2 | Shell starts play before terminal analyze (unit) | `ProgressivePlaybackTests.testAppShellStartsPlayBeforeFullAnalysisCompletes` |
| 3 | `testPlaybackStartsWhileAnalysisInFlight` | `ProgressivePlaybackUITests.testPlaybackStartsWhileAnalysisInFlight` |
| 4 | `testSeekBarReachesTerminalAnalysisState` | `ProgressivePlaybackUITests.testSeekBarReachesTerminalAnalysisState` |
| 5 | Tap-to-seek `dx=0.75` clamp contract | `ProgressivePlaybackUITests.testSeekClampsToProcessedFrontier` |
| 6 | `playback.remaining` + sum tolerance | `ProgressivePlaybackUITests.testElapsedAndRemainingSumToDuration` |
| 7 | Playhead normalization + clamp math (unit) | `SuperSeekBarModelTests.testPlayheadPositionAndFrontierClamp` |
| 8 | Partial mute RMS (unit) | `ProgressivePlaybackTests.testPartialScheduleMutesWithinFirstChunk` |
| 9 | — | Full `scripts/verify.sh` |
