# Slice 30 — UX spec: Mini-player super seek bar parity

| Field | Value |
|-------|-------|
| **Slice** | 30 — Mini-player super seek bar parity (shared chrome) |
| **Screen** | `MiniPlayerBar` hosting shared `SuperSeekBarView`; expanded `PlaybackControlsView` unchanged host |
| **ADR** | [ADR-026](../adr/026-mini-player-super-seek-parity.md) (shared host, expand vs seek, identifier migration) |
| **Builds on** | [slice-23-ux.md](slice-23-ux.md) (`miniPlayer`, `miniPlayerPlayPause`, sheet expand), [slice-25-ux.md](slice-25-ux.md) (super seek bar layout, tap-to-seek, frontier clamp), [slice-27-ux.md](slice-27-ux.md) (mute markers, `muteMarkers:` AX suffix, query helpers) |
| **Slice story** | [slice-30-mini-player-super-seek-parity.md](slice-30-mini-player-super-seek-parity.md) |

## Scope note

**Mini-player chrome only** — replace the read-only `miniPlayerAnalysisTimeline` strip with the **same** `SuperSeekBarView` type the full player uses (`playback.superSeekBar`). One paint + seek + mute-marker implementation; height and `accessibilityIdentifier` are the only host-specific parameters.

**In scope:** segment colors, red mute-marker overlays, playhead, tap-to-seek with frontier clamp, matching `accessibilityValue` grammar (including `muteMarkers:N` when complete).

**Out of scope:** episode-row `analysisTimeline`, CarPlay / lock-screen chrome, transcript highlighting, continuous slider scrub, changing mute/skip algorithm or ADR-018 yellow = ads rules.

**No continuous slider scrub** — tap-to-seek only (Slice 25 precedent; avoids flaky XCUITest drags).

## Layout

Vertical stack inside `MiniPlayerBar`, top → bottom (unchanged outer placement above tab bar per Slice 23):

1. **Title / transport row** — horizontal `HStack`:
   - **Expand target** (`miniPlayer`) — artwork placeholder + episode title + show title (leading block). **Does not** include the seek bar.
   - **Play / pause** (`miniPlayerPlayPause`) — trailing discrete button (unchanged Slice 23 contract).
2. **Super seek bar** (`miniPlayer.superSeekBar`) — shared `SuperSeekBarView` below the title row:
   - **Segment strip** — 12 equal-width buckets when colors shown (Slice 20 geometry).
   - **Mute marker overlays** — red bands/ticks (Slice 27 visual language), scaled to mini height.
   - **Playhead** — vertical capsule at `elapsed / duration` (no separate identifier).
   - **Bar height** — `AnalysisTimelineModel.miniPlayerTimelineHeight` (**12 pt** minimum; keep existing constant). Total interactive frame height **≥ 20 pt** (`barHeight + 8` playhead extension — same formula as full player).
   - **Horizontal inset** — `.padding(.horizontal, 16)`; `.padding(.bottom, 8)` below bar (matches retired timeline placement).

### Z-order within mini super seek bar

Segment fills (bottom) → mute marker overlays → playhead (top). Grey unprocessed tail visible right of green/blue frontier while analysis is in flight.

### Hit-target separation (critical)

| Region | `accessibilityIdentifier` | Action | Must **not** |
|--------|---------------------------|--------|--------------|
| Artwork + title block | `miniPlayer` | `onExpand` → present full-player sheet | Seek or toggle play |
| Play / pause button | `miniPlayerPlayPause` | Toggle playback | Expand |
| Super seek bar | `miniPlayer.superSeekBar` | Tap → frontier-clamped `onSeekTo` | Expand |

The seek bar is a **sibling below** the expand `Button`, not nested inside `miniPlayer`. Do not wrap title row + seek bar in one expand control.

### Identifier migration

| Retired (mini player chrome) | Replacement |
|------------------------------|-------------|
| `miniPlayerAnalysisTimeline` | `miniPlayer.superSeekBar` |

**Unchanged:** `miniPlayer`, `miniPlayerPlayPause`, `playback.superSeekBar`, episode-row `analysisTimeline`, full-player transport ids.

**Retired globally in mini chrome:** `miniPlayerAnalysisTimeline` must **not** appear after this slice.

## Color and marker contract

Reuse Slice 20 / 25 / 27 semantics unchanged. Mini and full hosts read the **same** snapshot + interval inputs from `AppShellModel`; for the same now-playing episode at the same analysis phase, parsed `ready` / `processing` / `pending` / `muteMarkers` **must match** across hosts.

| Visual | Spec |
|--------|------|
| Segment colors | Green / blue / grey / yellow (terminal ads) — same precedence as Slice 20 |
| Mute markers | `Color.red` opacity **0.85**; minimum **2 pt** tick width; optional border when ≥ **4 pt** (Slice 27) |
| Cleaning off / no colors | **Grey track** (`systemGray5`) + playhead + seek — bar **stays visible** (do not hide when `timelineColors == nil`) |

## States

### Mini super seek bar display modes

| Mode | Bar visible? | Segment colors | `miniPlayer.superSeekBar` `accessibilityValue` | Tap-to-seek frontier |
|------|--------------|----------------|------------------------------------------------|----------------------|
| **Progressive in flight** (cleaning on) | **Yes** | Green / blue / grey | `ready:N,processing:N,pending:N` — **no** `muteMarkers` key | `processedEnd` from live snapshot |
| **Terminal / cache hit** (cleaning on) | **Yes** | Full bar incl. yellow when ads | `ready:N,processing:N,pending:N,muteMarkers:M` | `duration` |
| **Cleaning off / no snapshot** | **Yes** | Grey track only | **Omitted** (element exists for tap-to-seek within `[0, duration]`) | `duration` |
| **Mini player hidden** | No | — | — | — |

**Complete gate** for mute markers and `muteMarkers:` AX (identical to Slice 27 / ADR-026):

1. Segment colors visible (`timelineColors != nil`).
2. Raw `processedEnd >= duration` (complete analysis — not the seek-frontier fallback).
3. Cached profanity-mute intervals supplied from shell.

**Behavior change vs pre-slice-30 mini:** the bar is **always** hosted when `isMiniPlayerVisible` (including cleaning-off grey track). Retired: conditional `if let timelineColors` that omitted the strip entirely.

### Mini play / pause (unchanged)

| Condition | Icon | `accessibilityLabel` | `accessibilityValue` |
|-----------|------|----------------------|----------------------|
| `isPreparingPlayback && !isPlaying` | Waveform | `Analyzing` | `analyzing` |
| `isPlaying` | Pause | `Pause` | `playing` |
| Paused, not preparing | Play | `Play` | `paused` |

Once `engine.isPlaying == true`, transport must **not** stay on analyzing waveform even if `isPreparingPlayback` remains true (ADR-021).

### Frontier clamp feedback

When the user taps the mini seek bar (or uses full-player ±15 s after expand) beyond `processedEnd`:

- **Behavior:** silent clamp via `SuperSeekBarModel.clampedSeek` — playhead jumps to frontier.
- **No** toast, banner, or haptic.
- **Mini has no elapsed label** — UITest proves clamp by expanding and reading `playback.elapsed` (see AC#4 scenario).

## Interaction: expand vs seek vs play

| User action | Target | Result |
|-------------|--------|--------|
| Tap title / artwork row | `miniPlayer` | Full-player sheet within **5.0 s** (`playback.playPause` or `playback.superSeekBar` exists) |
| Tap play / pause | `miniPlayerPlayPause` | Toggle; does **not** expand |
| Single tap on seek bar | `miniPlayer.superSeekBar` | Seek to clamped seconds; does **not** expand |
| Swipe on seek bar | — | **No** continuous scrub (ignored or treated as tap at release — Engineer matches full player `DragGesture(minimumDistance: 0)` tap contract) |

## Interaction: tap-to-seek (mini)

**Control:** `miniPlayer.superSeekBar` (full width of bar, including playhead hit area).

**Gesture:** single **tap** at normalized X (no drag / scrub).

**Mapping** (same as Slice 25):

```text
fraction = tapX / barWidth
requestedSeconds = fraction × episodeDuration
actualSeek = clamp(requestedSeconds, 0 … processedEnd)
```

**AC#4 pinned coordinate** (120.0 s fixture, frontier **60.0 s**):

```swift
let bar = app.descendants(matching: .any)["miniPlayer.superSeekBar"]
let coord = bar.coordinate(withNormalizedOffset: CGVector(dx: 0.75, dy: 0.5))
coord.tap()
```

Requests **90.0 s**; clamped to **60.0 s** frontier. After tap, expand via `miniPlayer` and assert `playback.elapsed` `accessibilityValue` as `Int` is **≥ 55** and **≤ 65** (± **0.5 s** tolerance per slice AC — UX pins **55–65** inclusive on whole-second AX strings).

Do **not** use `adjustable` slider APIs or drag gestures.

## Accessibility contract

**Single element per host:** `miniPlayer.superSeekBar` with `accessibilityElement(children: .ignore)`. Mute markers are visual-only overlays (no per-marker child identifiers).

### `accessibilityValue` format

**Identical grammar** to `playback.superSeekBar` (Slice 27):

**In flight:**

```text
ready:<int>,processing:<int>,pending:<int>
```

**Complete:**

```text
ready:<int>,processing:<int>,pending:<int>,muteMarkers:<int>
```

Machine-readable, **no spaces**; segment sum **12** on pinned **120.0 s** fixtures.

### Labels and hints (mini host)

| Field | `playback.superSeekBar` (unchanged) | `miniPlayer.superSeekBar` |
|-------|-------------------------------------|---------------------------|
| `accessibilityIdentifier` | `playback.superSeekBar` | `miniPlayer.superSeekBar` |
| `accessibilityLabel` | `Playback position` | `Playback position` |
| `accessibilityHint` | Slice 27 full-player hint | `Tap to seek within analyzed audio. Seeks past unscanned audio move to the analyzed frontier. When analysis is complete, profanity mute regions appear as red marks on the bar.` |

Value grammar is Architect-pinned; label may match full player for parity.

### Pinned terminal examples (120.0 s fixtures)

| Fixture | Mini + full `accessibilityValue` |
|---------|----------------------------------|
| `-UITestFixtureMuteMarkers` | `ready:12,processing:0,pending:0,muteMarkers:2` |
| `-UITestFixtureMuteMarkersAdsOnly` | `ready:12,processing:0,pending:0,muteMarkers:0` |
| `-UITestFixtureLibraryAnalysisTimeline` | `ready:12,processing:0,pending:0,muteMarkers:0` |
| `-UITestFixtureProgressivePlayback` (mid-run) | `ready:3,processing:1,pending:8` (no `muteMarkers` key) |
| `-UITestFixtureProgressivePlayback` (terminal) | `ready:12,processing:0,pending:0,muteMarkers:2` |

### XCTest query helpers

Reuse Slice 27 helpers (`muteMarkerCount(from:)`, `segmentCounts(from:)`). Query mini bar with:

```swift
app.descendants(matching: .any)["miniPlayer.superSeekBar"]
```

**Parity assert pattern (AC#2):**

```swift
let miniValue = miniBar.value as! String
// expand full player…
let fullValue = fullBar.value as! String
XCTAssertEqual(Self.muteMarkerCount(from: miniValue), Self.muteMarkerCount(from: fullValue))
XCTAssertEqual(Self.segmentCounts(from: miniValue), Self.segmentCounts(from: fullValue))
```

## Fixture modes

Reuse existing launch args — **no new fixture family required** unless QA adds a mini-only convenience (prefer existing).

### `-UITestFixtureMuteMarkers` (AC#1, AC#2)

| Concern | Value |
|---------|-------|
| Launch arg | `-UITestFixtureMuteMarkers` |
| Audio | Bundled **120.0 s** local file |
| Cleaning | On |
| Analysis | Immediate complete (`processedEnd = 120.0`) |
| Profanity mutes | **≥ 2** (pinned terminal `muteMarkers:2`) |
| Ads | None |

**Pinned mini AX (within 5.0 s of `miniPlayer` visible):** `ready:12,processing:0,pending:0,muteMarkers:2`

### `-UITestFixtureMuteMarkersAdsOnly` (AC#3)

| Concern | Value |
|---------|-------|
| Launch arg | `-UITestFixtureMuteMarkersAdsOnly` |
| Profanity mutes | **Zero** |
| Ads | Yellow buckets on terminal bar |
| **Pinned mini AX** | `ready:12,processing:0,pending:0,muteMarkers:0` |

### `-UITestFixtureProgressivePlayback` (AC#4)

| Concern | Value |
|---------|-------|
| Launch arg | `-UITestFixtureProgressivePlayback` |
| Mid-run pin | `ready:6,processing:1,pending:5` at `processedEnd = 60.0` |
| Seek-freeze | Fixture holds snapshot at phase (2) for seek step (preferred — avoids terminal race) |

### `-UITestFixtureLibraryAnalysisTimeline` (Library migration)

Terminal complete, **zero** profanity mutes. Mini + full terminal: `ready:12,processing:0,pending:0,muteMarkers:0`.

**Typical Library launch:** `-UITestFixtureDownload` + `-UITestFixtureLibraryAnalysisTimeline` (existing `libraryPlayerAnalysisTimelineArgs`).

### Navigation helpers

**To mini player only** (AC#1, AC#3, AC#4, AC#5 setup):

1. Wait for `libraryRoot` (**10 s**).
2. Tap `libraryCell_0` → wait for `episodeList`.
3. Tap `episodeCell_0` → wait for `miniPlayer` (**5 s**).
4. Tap `miniPlayerPlayPause` if playback not started (`accessibilityValue` → `playing` when needed).

**To expanded full player** (AC#2 after mini read, AC#4 elapsed assert):

5. Tap `miniPlayer` (**not** `miniPlayer.superSeekBar`, **not** `miniPlayerPlayPause`) → wait for `playback.playPause` or `playback.superSeekBar` (**5 s**).

## UI test scenarios

Mapped tests: `PodWashUITests/SuperSeekBarUITests.swift` and/or `PodWashUITests/MiniPlayerSuperSeekBarUITests.swift` (AC#1–AC#5). Use `app.descendants(matching: .any)["<identifier>"]` with pinned timeouts.

### `testMiniPlayerExposesMuteMarkersWhenProfanityMutePresent` (AC#1)

1. Launch `-UITestFixtureMuteMarkers`; navigate to mini player only (fixture navigation above); start playback if needed.
2. Within **5.0 s** of `miniPlayer` visible, assert `miniPlayer.superSeekBar` exists.
3. Read `accessibilityValue` → assert `muteMarkerCount(from:)` is **≥ 1** (pinned fixture: **== 2**).
4. Assert `segmentCounts(from:)` equals **`(12, 0, 0)`**.
5. Assert `miniPlayerAnalysisTimeline` does **not** exist.

### `testMiniAndFullPlayerMuteMarkersParity` (AC#2)

1. Launch `-UITestFixtureMuteMarkers`; navigate to mini player; start playback if needed.
2. Within **5.0 s**, capture `miniValue` from `miniPlayer.superSeekBar`.
3. Tap `miniPlayer` to expand full player.
4. Within **5.0 s**, read `fullValue` from `playback.superSeekBar`.
5. Assert `muteMarkerCount(from: miniValue) == muteMarkerCount(from: fullValue)`.
6. Assert `segmentCounts(from: miniValue) == segmentCounts(from: fullValue)`.

### `testMiniPlayerMuteMarkersZeroForAdsOnly` (AC#3)

1. Launch `-UITestFixtureMuteMarkersAdsOnly`; navigate to mini player; start playback if needed.
2. Within **5.0 s**, read `miniPlayer.superSeekBar` `accessibilityValue`.
3. Assert exact string **`ready:12,processing:0,pending:0,muteMarkers:0`**.
4. Assert `segmentCounts(from:)` equals **`(12, 0, 0)`** (sum **12**).
5. Assert `muteMarkerCount(from:) == 0`.

### `testMiniPlayerSeekClampsToProcessedFrontier` (AC#4)

1. Launch `-UITestFixtureProgressivePlayback`; navigate to mini player; start playback.
2. Wait until `miniPlayer.superSeekBar` `accessibilityValue == "ready:6,processing:1,pending:5"` **or** invoke fixture freeze at `processedEnd = 60.0`.
3. Tap `miniPlayer.superSeekBar` at **`dx = 0.75`** (requests **90.0 s** on **120.0 s** duration).
4. Tap `miniPlayer` to expand full player.
5. Within **2.0 s**, read `playback.elapsed` `accessibilityValue` as `Int` → assert **≥ 55** and **≤ 65**.

### `testMiniPlayerExpandStillOpensFullPlayer` (AC#5)

1. Launch any fixture that shows mini player (e.g. `-UITestFixtureMuteMarkers`); navigate to mini player; start playback if needed.
2. Assert `miniPlayer.superSeekBar` exists (seek bar present).
3. Tap `miniPlayer` (title/artwork row — coordinate in upper portion of mini bar chrome, **not** on `miniPlayer.superSeekBar`).
4. Within **5.0 s**, assert `playback.playPause` **or** `playback.superSeekBar` exists.
5. Assert seek bar tap did **not** occur in this step (full player was not already open).

### Authorized migrations (LibraryUITests — QA test-spec commit)

| Test | Change |
|------|--------|
| `testMiniPlayerShowsAnalysisTimelineWhenAnalysisComplete` | Query `miniPlayer.superSeekBar`; terminal value **`ready:12,processing:0,pending:0,muteMarkers:0`**; retire `miniPlayerAnalysisTimeline` |
| `testFullPlayerShowsMatchingAnalysisTimeline` | Mini query → `miniPlayer.superSeekBar`; assert **full** `accessibilityValue` string equality (including `muteMarkers:0`), not segment triple only |
| Any helper `waitForPlayerAnalysisTimeline(identifier: "miniPlayerAnalysisTimeline")` | Rename / repoint to `miniPlayer.superSeekBar` |

Update `terminalTimelineValue` comment: mini is no longer mute-marker-free — terminal library fixture uses `muteMarkers:0` on **both** hosts.

### UX regression scenarios (not slice ACs; optional QA)

#### `testMiniPlayerMidRunOmitsMuteMarkersKey`

1. Launch `-UITestFixtureProgressivePlayback`; stay on mini player; start playback.
2. Within **5.0 s**, assert `miniPlayer.superSeekBar` `accessibilityValue == "ready:3,processing:1,pending:8"` (no `muteMarkers` substring).

#### `testMiniPlayerCleaningOffShowsGreyBarWithoutSegmentAX`

1. Launch library fixture with cleaning off (existing toggle pattern if needed).
2. Assert `miniPlayer.superSeekBar` exists.
3. Assert `accessibilityValue` does **not** contain `ready:` or `muteMarkers:`.

#### `testMiniSeekBarTapDoesNotExpand`

1. Launch mute-markers fixture; mini visible; full player **not** open.
2. Tap `miniPlayer.superSeekBar` at `dx = 0.25`.
3. Assert `playback.playPause` does **not** exist within **2.0 s** (negative wait).
4. Assert `miniPlayer` still exists.

## Verification mapping

| AC# | UX artifact | Test file / method |
|-----|-------------|-------------------|
| 1 | `testMiniPlayerExposesMuteMarkersWhenProfanityMutePresent` | `SuperSeekBarUITests` or `MiniPlayerSuperSeekBarUITests` |
| 2 | `testMiniAndFullPlayerMuteMarkersParity` | same |
| 3 | `testMiniPlayerMuteMarkersZeroForAdsOnly` | same |
| 4 | Mini `dx=0.75` tap + expand + `playback.elapsed` clamp | same |
| 5 | `testMiniPlayerExpandStillOpensFullPlayer` | same |
| 6 | Shared-host seam (Engineer / QA unit) | `PodWashTests` — both hosts construct `SuperSeekBarView` |
| 7 | — | Full `scripts/verify.sh` |
