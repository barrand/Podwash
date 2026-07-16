# Slice 33 — UX spec: Timestamp seek-bar ads + analysis progress chrome

| Field | Value |
|-------|-------|
| **Slice** | 33 — Timestamp seek-bar ads + analysis progress chrome |
| **Screens** | Expanded full player (`PlaybackControlsView`); mini player (`MiniPlayerBar`) — shared `SuperSeekBarView` host |
| **ADR** | [ADR-030](../adr/030-timestamp-seek-bar-ads-progress.md) (retire in-flight segment paint; timestamp yellow ad bands; analysis progress AX; frontier clamp retained) |
| **Builds on** | [slice-25-ux.md](slice-25-ux.md) (super seek bar layout, tap-to-seek, frontier clamp, progressive start), [slice-27-ux.md](slice-27-ux.md) (mute marker overlays, red visual language), [slice-30-ux.md](slice-30-ux.md) (mini/full shared host, expand vs seek), [slice-26-ux.md](slice-26-ux.md) (transcript `skippedAd` semantic twin of yellow bands) |
| **Slice story** | [slice-33-timestamp-seek-bar-ads-progress.md](slice-33-timestamp-seek-bar-ads-progress.md) |

## Scope note

**Player chrome only** (full + mini). Replaces misleading **12-bucket** segment colors (`ready:N,processing:N,pending:N`) and **whole-bucket yellow** with:

1. **In flight** — determinate **analysis progress** + **colorless** seek track + playhead (no yellow, no mute overlays, no segment triple AX).
2. **Complete** — **solid green** content track + **timestamp-proportional yellow** ad-band overlays + existing **red** mute markers.

Yellow ad bands use the **same** applied `.unrelatedContent` + `.skip` interval set as transcript `skippedAd`. A **30.0 s** preroll on a **3600.0 s** episode yellows **≈ 30/3600** of bar width — not whole 10 s buckets.

**Retired on player chrome:** in-flight `AnalysisTimelineModel.segmentColors` paint; terminal bucket-yellow; `ready:` / `processing:` / `pending:` keys on `playback.superSeekBar` / `miniPlayer.superSeekBar`.

**Unchanged:** progressive early play after first chunk (ADR-021); frontier clamp to `processedEnd` while incomplete; tap-to-seek + ±15 s (no continuous scrub); mute filter (`.profanity` + `.mute` only); episode-row `analysisTimeline`; transcript UI; CarPlay / lock screen.

**No continuous slider scrub** — tap-to-seek and ±15 s buttons only (Slice 03 / 25 precedent).

## Layout

### Full player (`PlaybackControlsView`)

Vertical stack, top → bottom:

1. **Analysis progress row** (in flight only) — `playback.analysisProgress` (see Analysis progress control).
2. **Super seek bar** (`playback.superSeekBar`) — interactive seek region:
   - **In flight:** colorless track (`systemGray5` fill — same token as cleaning-off grey track) + playhead; **no** segment fills; **no** yellow or red overlays.
   - **Complete:** solid **green** content fill + yellow ad-band overlays + red mute-marker overlays + playhead.
   - **Minimum strip height** — **≥ 20 pt** (`AnalysisTimelineModel.fullPlayerTimelineHeight`); playhead may extend slightly above/below.
3. **Time row** — `playback.elapsed` | `playback.remaining` (unchanged Slice 25).
4. **Transport row** — `playback.seekBack15` | `playback.playPause` | `playback.seekForward15` (unchanged).
5. **Secondary row** — `speedButton`, `sleepTimerButton`, `themePrimaryAccent` (unchanged).

### Mini player (`MiniPlayerBar`)

Same mode contract as full player; host-specific identifiers only.

1. **Title / transport row** — `miniPlayer` (expand) | `miniPlayerPlayPause` (unchanged Slice 30 hit-target separation).
2. **Analysis progress row** (in flight only) — `miniPlayer.analysisProgress`.
3. **Super seek bar** (`miniPlayer.superSeekBar`) — shared `SuperSeekBarView`; height **≥ 12 pt** strip + playhead extension (`miniPlayerTimelineHeight` formula from Slice 30).

### Z-order within super seek bar (complete mode)

```text
green content track → yellow ad bands → red mute markers → playhead
```

In-flight: grey track → playhead only.

### Analysis progress control

| Attribute | Spec |
|-----------|------|
| **Placement (full)** | Directly **above** `playback.superSeekBar`, full width, **4 pt** vertical gap |
| **Placement (mini)** | Directly **above** `miniPlayer.superSeekBar`, inset `.horizontal 16` to match seek bar |
| **Chrome** | `ProgressView(value:total:)` linear style (or equivalent determinate bar); tint `BrandTheme.primary` |
| **Label (visible)** | Optional caption **Analyzing…** trailing or above bar — **not** required for Done gate; VoiceOver uses AX below |
| **Visibility** | Shown **iff** cleaning on, live snapshot exists, and `processedEnd < episodeDuration` |
| **Hidden when** | Analysis complete, cleaning off, or no snapshot |

Progress reflects **overall** analysis: `processedEnd / duration` — **not** per-segment bucket state.

## Visual language

| Layer | In flight | Complete |
|-------|-----------|----------|
| **Track fill** | `Color(uiColor: .systemGray5)` — colorless / neutral | Solid **green** — `BrandTheme.primary` at **~35%** opacity (continuous fill, not 12 buckets) |
| **Yellow ad bands** | **Hidden** | `BrandTheme.accent` (same token as transcript skipped-ad yellow) at **~85%** opacity; overlay rectangles spanning `[startNormalized × width, endNormalized × width)` |
| **Red mute markers** | **Hidden** | Unchanged Slice 27: `Color.red` **0.85** opacity; min **2 pt** tick width |
| **Playhead** | `Color.primary` capsule, topmost | Same |
| **Analyzing affordance** | `playback.playPause` waveform icon when `isPreparingPlayback && !isPlaying` (unchanged ADR-021) | N/A at terminal |

**Minimum yellow band width:** **2 pt** floor when normalized span &lt; 2 pt on screen (model still exposes true normalized edges for unit tests).

**No** animation on yellow band appearance at terminal swap (instant paint when complete gate flips).

## States

### Player chrome display modes

| Mode | Progress control | Seek-bar paint | `playback.superSeekBar` / `miniPlayer.superSeekBar` `accessibilityValue` | Tap-to-seek frontier |
|------|------------------|----------------|------------------------------------------------------------------------|----------------------|
| **In flight** (cleaning on, `processedEnd < duration`) | **Visible** — fraction `processedEnd/duration` | Colorless track + playhead | **Omitted** — must **not** contain `ready:`, `processing:`, `pending:`, `adBands:`, or `muteMarkers:` | `processedEnd` |
| **Complete** (cleaning on, `processedEnd ≥ duration`) | **Hidden** | Green + yellow ad bands + red mutes | `adBands:N,<bands>,muteMarkers:M` | `duration` |
| **Cleaning off / no snapshot** | **Hidden** | Colorless track + playhead | **Omitted** | `duration` |
| **Complete, zero ad skips** | **Hidden** | Green + mutes only | `adBands:0,muteMarkers:M` | `duration` |

**Complete gate** for yellow ad bands and `adBands:` AX (all required):

1. Cleaning chrome on.
2. `processedEnd >= episodeDuration` (or cache-hit complete with no in-flight snapshot).
3. Applied / cached unrelated-skip intervals supplied from shell (same source as transcript + mute markers).

**In flight:** `adBands` count **0** for paint; progress control owns the story.

### Play / pause during progressive prepare

Unchanged Slice 25 / ADR-021:

| Condition | Icon | `accessibilityLabel` | `accessibilityValue` |
|-----------|------|----------------------|----------------------|
| `isPreparingPlayback && !isPlaying` | Waveform | `Analyzing` | `analyzing` |
| `isPlaying` | Pause | `Pause` | `playing` |
| Paused, not preparing | Play | `Play` | `paused` |

Once `engine.isPlaying == true`, transport must **not** stay on analyzing waveform even if analysis continues.

### Frontier clamp feedback

When the user seeks beyond `processedEnd` (tap-to-seek or ±15 s forward) while incomplete:

- **Behavior:** silent clamp via `SuperSeekBarModel.clampedSeek` — playhead jumps to frontier (unchanged ADR-021).
- **Visual:** colorless track only — **no** grey-bucket “unscanned tail” (retired misleading UI).
- **Copy migration:** “clamp to grey” → “clamp to analyzed frontier (`processedEnd`)”.
- **No** toast, banner, or haptic.

Pinned seek test (120.0 s fixture, frontier **60.0 s**): tap `dx = 0.75` → `playback.elapsed` Int **55–60** (full) or expand-after-mini **55–65** (Slice 30 tolerance).

## Interaction

### Tap-to-seek

Unchanged Slice 25 coordinate contract:

```text
fraction = tapX / barWidth
requestedSeconds = fraction × episodeDuration
actualSeek = clamp(requestedSeconds, 0 … processedEnd)   // processedEnd = duration when complete
```

**Control:** `playback.superSeekBar` / `miniPlayer.superSeekBar`. Single **tap** only — no drag scrub.

**`accessibilityHint` (updated):**

`Tap to seek within analyzed audio. Seeks past unscanned audio move to the analyzed frontier. When analysis is complete, skipped ad regions appear as yellow bands and profanity mute regions as red marks on the bar.`

### Expand vs seek (mini)

Unchanged Slice 30 — `miniPlayer` expands; `miniPlayer.superSeekBar` seeks; `miniPlayerPlayPause` toggles play.

## Accessibility contract

### Analysis progress (in flight only)

| Host | `accessibilityIdentifier` | `accessibilityLabel` | `accessibilityValue` | `accessibilityHint` |
|------|---------------------------|----------------------|----------------------|---------------------|
| Full player | `playback.analysisProgress` | `Analysis progress` | Normalized fraction **0.0000–1.0000**, **4 decimal places**, no unit suffix (e.g. `0.2500` for 30/120) | `Overall progress of episode cleaning analysis.` |
| Mini player | `miniPlayer.analysisProgress` | `Analysis progress` | Same grammar | Same |

Tests parse `Double(value)` and assert within **±0.02** of `processedEnd / duration`.

**Hidden** from AX tree when not visible (prefer absent over disabled).

### Super seek bar

**Single element per host** with `accessibilityElement(children: .ignore)`. Ad bands and mute markers are visual overlays — **no** per-band child identifiers.

| Phase | Identifier | `accessibilityLabel` | `accessibilityValue` |
|-------|------------|----------------------|----------------------|
| In flight | `playback.superSeekBar` / `miniPlayer.superSeekBar` | `Playback position` | **Omitted** |
| Complete | same | `Playback position` | `adBands:N,<start>-<end>(,<start>-<end>)*,muteMarkers:M` |
| Cleaning off | same | `Playback position` | **Omitted** |

#### Complete `accessibilityValue` grammar (pinned)

Machine-readable, **no spaces**:

```text
adBands:<int>,<start>-<end>(,<start>-<end>)*,muteMarkers:<int>
```

Rules:

- `N` = count of unrelated-skip ad bands after complete gate (**N ≥ 0**). When **N = 0**, emit `adBands:0` with **no** band tokens before `muteMarkers`.
- Each band: `<start>-<end>` with normalized edges to **4 decimal places** (half-open `[start, end)` semantics match model).
- Always emit `,muteMarkers:M` on complete bars (**M ≥ 0**), including `M == 0`.
- Bands ordered by increasing `startNormalized`.
- Parsers must **reject** legacy `ready:` prefix as terminal complete state after this slice.

**Pinned examples:**

| Context | Duration | Skip(s) | Full `accessibilityValue` |
|---------|----------|---------|---------------------------|
| Preroll only (AC6 fixture) | **600.0 s** | `[0.0, 30.0)` | `adBands:1,0.0000-0.0500,muteMarkers:0` |
| Preroll on 3600 s (unit AC1) | **3600.0 s** | `[0.0, 30.0)` | `adBands:1,0.0000-0.0083,muteMarkers:0` |
| Two bands (unit AC2) | **3600.0 s** | `[0.0, 30.0)`, `[1800.0, 1860.0)` | `adBands:2,0.0000-0.0083,0.5000-0.5167,muteMarkers:0` |
| Mute + preroll (AC7 fixture) | **600.0 s** | preroll + ≥1 profanity mute | `adBands:1,0.0000-0.0500,muteMarkers:2` (pinned mute count per fixture) |
| Complete, no ads, with mutes | **120.0 s** | none | `adBands:0,muteMarkers:2` |
| Complete, no ads, no mutes | **120.0 s** | none | `adBands:0,muteMarkers:0` |

### Unchanged identifiers

`playback.elapsed`, `playback.remaining`, `playback.playPause`, `playback.seekBack15`, `playback.seekForward15`, `miniPlayer`, `miniPlayerPlayPause`, `speedButton`, `sleepTimerButton`, `themePrimaryAccent`, shell navigation ids.

### XCTest query helpers

```swift
/// Parses adBands count and normalized band ranges from complete-bar AX value.
static func adBandSummary(from barValue: String) -> (count: Int, bands: [(start: Double, end: Double)], muteMarkers: Int)? {
    guard barValue.hasPrefix("adBands:") else { return nil }
    let parts = barValue.split(separator: ",")
    guard let countPart = parts.first,
          countPart.hasPrefix("adBands:"),
          let count = Int(countPart.dropFirst("adBands:".count)) else { return nil }
    var bands: [(Double, Double)] = []
    var muteMarkers: Int?
    for token in parts.dropFirst() {
        if token.hasPrefix("muteMarkers:") {
            muteMarkers = Int(token.dropFirst("muteMarkers:".count))
            break
        }
        let edges = token.split(separator: "-")
        guard edges.count == 2,
              let start = Double(edges[0]),
              let end = Double(edges[1]) else { return nil }
        bands.append((start, end))
    }
    guard let muteMarkers, bands.count == count else { return nil }
    return (count, bands, muteMarkers)
}

/// True when legacy segment triple is absent (in-flight + post-slice complete guard).
static func lacksSegmentTriple(_ barValue: String?) -> Bool {
    guard let barValue else { return true }
    return !barValue.contains("ready:")
        && !barValue.contains("processing:")
        && !barValue.contains("pending:")
}

/// Denormalize first ad band end to wall seconds for preroll asserts.
static func firstAdBandEndSeconds(from barValue: String, duration: Double) -> Double? {
    guard let summary = adBandSummary(from: barValue),
          let first = summary.bands.first else { return nil }
    return first.end * duration
}
```

Use `app.descendants(matching: .any)["<identifier>"]` for all queries.

## Fixture modes

### `-UITestFixturePrerollAdBands` (AC#6 — primary)

| Concern | Value |
|---------|-------|
| Launch arg | `-UITestFixturePrerollAdBands` |
| Persistence | In-memory store (Library path) |
| Audio | Bundled local file, duration **≥ 600.0 s** (pinned: **600.0 s**) |
| Cleaning | Channel + episode cleaning **on** |
| Analysis | **Immediate complete** (`processedEnd = duration`) |
| Cached intervals | **One** `.unrelatedContent` + `.skip`: **`[0.0, 30.0)`** |
| Profanity mutes | **None** |
| Network | **No** live network on play path |

**Pinned terminal AX:** `adBands:1,0.0000-0.0500,muteMarkers:0`

**Typical launch:** `-UITestFixturePrerollAdBands` **only** (exclusive fixture family).

### `-UITestFixturePrerollAdBandsWithMutes` (AC#7)

| Concern | Value |
|---------|-------|
| Launch arg | `-UITestFixturePrerollAdBandsWithMutes` |
| Audio | **600.0 s** (same asset family as preroll fixture) |
| Cached intervals | Preroll skip **`[0.0, 30.0)`** + **≥ 2** profanity mute intervals (e.g. mirror Slice 27 `[0.92, 1.87)`, `[2.92, 3.32)`) |
| Analysis | Immediate complete |
| Cleaning | **On** |

**Pinned terminal AX:** `adBands:1,0.0000-0.0500,muteMarkers:2`

Engineer may implement both preroll fixtures in one `FixturePrerollAdBands.swift` with launch-arg variants.

### `-UITestFixtureProgressivePlayback` (AC#4, AC#5 — migrated)

| Concern | Value |
|---------|-------|
| Launch arg | `-UITestFixtureProgressivePlayback` |
| Audio | **120.0 s** (unchanged) |
| Snapshot pacing | (1) `processedEnd=30`; (2) `processedEnd=60`; (3) terminal `processedEnd=120` |
| Freeze args | `-UITestFixtureProgressivePlaybackFreezeAt30`, `…FreezeAt60` (unchanged) |

**In-flight pins (no segment triple):**

| Phase | `processedEnd` | `playback.analysisProgress` value (±0.02) | `playback.superSeekBar` value |
|-------|----------------|-------------------------------------------|-------------------------------|
| First chunk | **30.0** | `0.2500` | **Omitted** — no `ready:` |
| Mid freeze | **60.0** | `0.5000` | **Omitted** |
| Terminal | **120.0** | control **hidden** | `adBands:0,muteMarkers:2` (fixture partial mutes persist) |

### Reused fixtures (terminal string migrations)

| Launch arg | Terminal `accessibilityValue` (both hosts when applicable) |
|------------|-------------------------------------------------------------|
| `-UITestFixtureMuteMarkers` | `adBands:0,muteMarkers:2` |
| `-UITestFixtureMuteMarkersAdsOnly` | `adBands:1,0.2917-0.3542,muteMarkers:0` (skip `[35.0, 42.5)` on **120.0 s** — timestamp band, not bucket yellow) |
| `-UITestFixtureLibraryAnalysisTimeline` | `adBands:0,muteMarkers:0` |
| `-UITestFixtureTranscript` | `adBands:1,…` per fixture skip seed + `muteMarkers:0` |

**Navigation to full player** (all Slice 33 UI tests):

1. Wait for `libraryRoot` (**10 s**).
2. Tap `libraryCell_0` → wait for `episodeList`.
3. Tap `episodeCell_0` → wait for `miniPlayer` (**5 s**).
4. Tap `miniPlayer` (not `miniPlayerPlayPause`) → wait for `playback.playPause` (**5 s**).
5. Start playback if `playback.playPause` `accessibilityValue != "playing"`.

For immediate-complete fixtures, terminal `adBands:` assertable within **5.0 s** of step 4.

## UI test scenarios

Mapped tests per slice verification table. Timeouts use pinned values unless noted.

### `testInFlightShowsAnalysisProgressWithoutSegmentColors` (AC#4 — unit seam + optional UI)

**Unit (primary):** `AnalysisProgressChromeTests.testInFlightShowsProgressWithoutSegmentColors`.

**Optional UI mirror:**

1. Launch `-UITestFixtureProgressivePlayback` + `-UITestFixtureProgressivePlaybackFreezeAt30`; navigate to expanded full player; start playback.
2. Within **5.0 s**, assert `playback.analysisProgress` exists.
3. Parse `accessibilityValue` as `Double` → assert within **±0.02** of **0.25** (`30/120`).
4. Read `playback.superSeekBar` — assert `lacksSegmentTriple(value)` (**no** `ready:` / `processing:` / `pending:`).
5. Assert `playback.superSeekBar` value does **not** contain `adBands:` or `muteMarkers:`.

### `testPlaybackStartsAfterFirstChunkWithoutSegmentColorGate` (AC#5)

**Unit (primary):** `ProgressivePlaybackTests.testPlaybackStartsAfterFirstChunkWithoutSegmentColorGate`.

**UI migration of Slice 25 `testPlaybackStartsWhileAnalysisInFlight`:**

1. Launch `-UITestFixtureProgressivePlayback` + freeze-at-30; navigate to full player.
2. Tap `playback.playPause` if needed.
3. Within **5.0 s**, assert `playback.playPause` `accessibilityValue == "playing"`.
4. Assert `playback.analysisProgress` exists with value within **±0.02** of **0.25**.
5. Assert `lacksSegmentTriple(accessibilityValue(for: "playback.superSeekBar"))`.
6. **Do not** assert `ready:3,processing:1,pending:8` (retired).

### `testCompleteBarYellowMatchesPrerollSkipNotWholeBuckets` (AC#6)

1. Launch `-UITestFixturePrerollAdBands`; navigate to expanded full player; start playback if needed.
2. Within **5.0 s**, read `playback.superSeekBar` `accessibilityValue`.
3. Assert exact string **`adBands:1,0.0000-0.0500,muteMarkers:0`** (600 s fixture).
4. Parse first band via `adBandSummary` → assert `count == 1`, `start ≈ 0.0000`, `end ≈ 0.0500` (± **0.002**).
5. `firstAdBandEndSeconds(from:duration: 600)` → assert **≥ 29.0** and **≤ 31.0** (± **1.0 s** wall-time).
6. Assert `lacksSegmentTriple(value)` and value **does not** imply opening yellow beyond **60.0 s** (band end ≤ **0.1000** normalized when only 30 s skip on 600 s episode).

### `testMuteMarkersRemainWithTimestampAdBands` (AC#7)

1. Launch `-UITestFixturePrerollAdBandsWithMutes`; navigate to expanded full player; start playback if needed.
2. Within **5.0 s**, read `playback.superSeekBar` `accessibilityValue`.
3. Assert `adBandSummary(from:)` → `count == 1`, preroll band **0.0000–0.0500** (± **0.002**).
4. Assert `muteMarkers >= 1` (pinned fixture: **== 2**).
5. Assert exact pinned string **`adBands:1,0.0000-0.0500,muteMarkers:2`**.
6. Assert value **does not** contain `ready:` (profanity did not create `adBands` entries).

### UX regression / migration scenarios (authorized QA updates)

#### `testProgressiveTerminalUsesAdBandsNotSegmentTriple`

1. Launch `-UITestFixtureProgressivePlayback`; navigate to full player; start playback.
2. Within **10.0 s**, assert `playback.superSeekBar` `accessibilityValue == "adBands:0,muteMarkers:2"`.
3. Assert `playback.analysisProgress` does **not** exist.

#### `testProgressiveMidRunShowsProgressHidesAdBands`

1. Launch progressive + `FreezeAt30`; navigate to full player; start playback.
2. Assert `playback.analysisProgress` value ≈ **0.25**; `lacksSegmentTriple` on seek bar.

#### `testSeekClampsToProcessedFrontier` (Slice 25 migration)

1. Launch progressive + `FreezeAt60`; navigate to full player; start playback.
2. Tap `playback.superSeekBar` at **`dx = 0.75`**.
3. Within **2.0 s**, `playback.elapsed` Int **55–60**.
4. **Remove** assertion on `ready:6,processing:1,pending:5`.

#### `testMiniAndFullPlayerAdBandsParity` (Slice 30 migration)

1. Launch `-UITestFixturePrerollAdBandsWithMutes`; navigate to mini; start playback.
2. Capture `miniPlayer.superSeekBar` value; expand full player.
3. Assert **string equality** with `playback.superSeekBar` (both `adBands:1,0.0000-0.0500,muteMarkers:2`).

#### `testMiniPlayerInFlightShowsAnalysisProgress` (Slice 30 migration)

1. Launch progressive + `FreezeAt30`; mini player only; start playback.
2. Assert `miniPlayer.analysisProgress` ≈ **0.25**; `lacksSegmentTriple` on `miniPlayer.superSeekBar`.

#### `testCleaningOffOmitsProgressAndAdBands` (Slice 25 / 27 migration)

1. Launch library fixture with cleaning forced off.
2. Assert `playback.superSeekBar` exists; `lacksSegmentTriple` on value; no `adBands:`.
3. Assert `playback.analysisProgress` does **not** exist.

#### `testLibraryTerminalAdBandsGrammar` (LibraryUITests migration)

1. Launch `-UITestFixtureDownload` + `-UITestFixtureLibraryAnalysisTimeline`; complete play path.
2. Mini + full terminal: **`adBands:0,muteMarkers:0`** (not `ready:12,…`).

### Authorized string retirements (test-spec commit)

Replace terminal / in-flight expectations in:

| File | Retired | Replacement |
|------|---------|-------------|
| `ProgressivePlaybackUITests` | `ready:3,processing:1,pending:8`, `ready:12,processing:0,pending:0` | progress fraction + `adBands:…` terminal |
| `SuperSeekBarUITests` | segment triple + `muteMarkers` suffix on `ready:` grammar | `adBands:…,muteMarkers:M` |
| `MiniPlayerSuperSeekBarUITests` | segment triple parity asserts | `adBandSummary` + `muteMarkers` parity |
| `LibraryUITests` | `ready:12,processing:0,pending:0,muteMarkers:0` | `adBands:0,muteMarkers:0` |

## Verification mapping

| AC# | UX artifact | Test file / method |
|-----|-------------|-------------------|
| 1 | Preroll normalized width 30/3600 | `SuperSeekBarAdBandTests.testPrerollYellowWidthMatchesTimestampFraction` |
| 2 | Two bands, no spurious coverage | `SuperSeekBarAdBandTests.testTwoAdBandsNoSpuriousCoverage` |
| 3 | Transcript `skippedAd` parity | `SuperSeekBarAdBandTests.testYellowBandsMatchTranscriptSkippedAdIntervals` |
| 4 | In-flight progress AX; no segment triple on bar | `AnalysisProgressChromeTests.testInFlightShowsProgressWithoutSegmentColors` |
| 5 | Progressive start without segment-color gate | `ProgressivePlaybackTests.testPlaybackStartsAfterFirstChunkWithoutSegmentColorGate` |
| 6 | `-UITestFixturePrerollAdBands`, preroll band not whole-bucket | `SuperSeekBarUITests.testCompleteBarYellowMatchesPrerollSkipNotWholeBuckets` |
| 7 | `-UITestFixturePrerollAdBandsWithMutes`, mutes + timestamp yellow | `SuperSeekBarUITests.testMuteMarkersRemainWithTimestampAdBands` |
| 8 | — | Full `scripts/verify.sh` |
