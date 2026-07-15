# Slice 27 — UX spec: Super seek bar mute markers

| Field | Value |
|-------|-------|
| **Slice** | 27 — Super seek bar mute markers |
| **Screen** | Expanded full player — `SuperSeekBarView` inside `PlaybackControlsView` |
| **ADR** | [ADR-023](../adr/023-super-seek-bar-mute-markers.md) (filter, complete-only gate, `muteMarkers:` AX suffix) |
| **Builds on** | [slice-25-ux.md](slice-25-ux.md) (super seek bar layout, tap-to-seek, segment colors), [slice-20-ux.md](slice-20-ux.md) (12-bucket geometry, yellow = ads only), [slice-26-ux.md](slice-26-ux.md) (transcript does **not** highlight profanity — markers live on the bar) |
| **Slice story** | [slice-27-super-seek-bar-mute-markers.md](slice-27-super-seek-bar-mute-markers.md) |

## Scope note

**Full-player `playback.superSeekBar` only.** Mute markers are narrow overlay ticks on the existing super seek bar when analysis is **complete** and segment colors are shown. Mini-player `miniPlayerAnalysisTimeline`, episode-row `analysisTimeline`, transcript word highlighting, CarPlay / lock-screen chrome, and `.profanity` + `.skip` intervals are **out of scope**.

**No new segment color.** Yellow remains ad / unrelated only (ADR-018). Mute spans are **not** painted yellow or green.

**No per-marker hit targets.** Tap-to-seek, ±15 s, and frontier clamp behave exactly as Slice 25; markers are informational overlays only.

## Layout

### Z-order (bottom → top)

1. **12-segment color strip** — unchanged Slice 20 / 25 fills (green / blue / grey / yellow).
2. **Mute marker overlays** — one visual mark per filtered `MuteMarker` (see Visual language).
3. **Playhead** — unchanged Slice 25 capsule (`Color.primary`), always on top.

Markers sit **inside** the bar’s colored strip height (`AnalysisTimelineModel.fullPlayerTimelineHeight`, **≥ 20 pt**). They must not change overall bar height or displace the time row / transport row.

### Marker placement

For each `MuteMarker` with normalized `[startNormalized, endNormalized)`:

```text
leadingX  = startNormalized × barWidth
trailingX = endNormalized   × barWidth
markerWidth = max(trailingX − leadingX, minimumTickWidth)
```

| Case | Rule |
|------|------|
| Visible span ≥ **2 pt** | Fill a `Rectangle` (or rounded rect) from `leadingX` to `leadingX + markerWidth` across the strip height |
| Sub-pixel / &lt; **2 pt** | Draw a **fixed-width tick** (**2 pt** wide) centered at `leadingX` (model still exposes start **and** end for unit tests) |

Horizontal alignment matches playhead math: leading edge of bar = **0.0**, trailing = episode duration.

### Unchanged chrome

Elapsed (`playback.elapsed`), remaining (`playback.remaining`), transport ids, and tap-to-seek coordinate contract (`dx` fraction → seconds → frontier clamp) are **unchanged** from [slice-25-ux.md](slice-25-ux.md).

## Visual language

| Attribute | Spec |
|-----------|------|
| **Shape** | Full-height vertical band when wide enough; otherwise a narrow centered tick |
| **Color** | **`Color.red`** at **opacity 0.85** in light and dark mode — distinct from green / blue / grey / **yellow** ad fills |
| **Border** | Optional **1 pt** `Color.primary` stroke at **opacity 0.25** when marker width ≥ **4 pt** (improves contrast on green/yellow underlays; omit on 2 pt ticks) |
| **Count** | One overlay per profanity **mute** interval after filter (not merged visually — overlapping mutes may stack) |
| **Motion** | Static; no pulse or animation required for Done gate |

**Rationale:** Red reads as “caution / will be cleaned” without reusing yellow (ads) or borrowing segment palette entries. Engineer may use `UIColor.systemRed` twin if needed for UIKit bridges; UX pins **semantic** = high-contrast, not yellow.

## States

### Mute marker visibility

| Mode | Segment colors | Marker paint | `playback.superSeekBar` `accessibilityValue` |
|------|----------------|--------------|-----------------------------------------------|
| **Progressive in flight** | Green / blue / grey | **Hidden** (empty marker array) | `ready:N,processing:N,pending:N` — **no** `muteMarkers` key (Slice 25 exact strings preserved) |
| **Terminal / cache hit, cleaning on** | Full bar incl. yellow when ads exist | Shown per filtered mute intervals | `ready:N,processing:N,pending:N,muteMarkers:M` |
| **Terminal, zero mute intervals** | Unchanged | **None** | Same format with **`muteMarkers:0`** (key always present when complete + colors on) |
| **Cleaning off / no snapshot** | Hidden | **None** | **Omitted** (unchanged Slice 25) |

**Complete gate** (all required to paint markers or emit `muteMarkers:`):

1. Segment colors visible (`timelineColors != nil`).
2. `snapshot.processedEnd >= snapshot.episodeDuration`.
3. Applied / cached intervals supplied from shell (not a second analyze pass).

### Filter (what gets a marker)

| Interval | Marker |
|----------|--------|
| `source == .profanity` && `action == .mute` | **Yes** |
| `source == .profanity` && `action == .skip` | **No** (follow-up slice) |
| `source == .unrelatedContent` (any action) | **No** — ads stay yellow only |
| Zero matches | **Count 0**, no overlays |

### Interaction during markers

| User action | Behavior |
|-------------|----------|
| Tap-to-seek on bar | Unchanged — seek to clamped seconds; markers do not intercept |
| ±15 s | Unchanged frontier clamp |
| VoiceOver focus on bar | Single element; hear segment counts + mute marker **count** in `accessibilityValue` (not per-marker elements) |

**No** toast, haptic, or playhead snap when playhead crosses a mute marker.

## Accessibility contract

**Single element:** `playback.superSeekBar` with `accessibilityElement(children: .ignore)`. **No** required child identifiers for markers (visual-only overlays).

### `accessibilityValue` format

**In flight** (colors on, analysis incomplete):

```text
ready:<int>,processing:<int>,pending:<int>
```

**Complete** (colors on):

```text
ready:<int>,processing:<int>,pending:<int>,muteMarkers:<int>
```

Rules:

- Machine-readable, **no spaces**; comma-separated keys.
- `ready` + `processing` + `pending` sums still equal **12** on the pinned **120.0 s** fixtures.
- `muteMarkers` = count of filtered mute intervals after the complete gate (**M ≥ 0**).
- Parsers that read only `ready` / `processing` / `pending` must ignore the trailing `,muteMarkers:M` suffix (QA helper below).

### Pinned terminal examples (120.0 s fixtures)

| Fixture context | Segment triple | `muteMarkers` | Full `accessibilityValue` |
|-----------------|----------------|---------------|---------------------------|
| Progressive playback terminal (2 partial mutes in fixture) | `12,0,0` | `2` | `ready:12,processing:0,pending:0,muteMarkers:2` |
| Library analysis timeline (no mutes) | `12,0,0` | `0` | `ready:12,processing:0,pending:0,muteMarkers:0` |
| Mute-markers fixture (≥ 1 mute, no ads) | `12,0,0` | `≥ 1` (pinned: `2` in primary fixture) | `ready:12,processing:0,pending:0,muteMarkers:2` |
| Ads-only control (yellow, zero mutes) | includes yellow buckets | `0` | `ready:12,processing:0,pending:0,muteMarkers:0` |

**Cross-suite churn:** Any UITest that asserts terminal `ready:12,processing:0,pending:0` **exactly** must append `,muteMarkers:N` for that fixture’s mute count in the slice-27 test-spec commit. **Mid-run** progressive strings (`ready:3,processing:1,pending:8`, etc.) stay **unchanged**.

### Labels and hints

| Field | Value |
|-------|-------|
| `accessibilityIdentifier` | `playback.superSeekBar` (unchanged) |
| `accessibilityLabel` | `Playback position` (unchanged) |
| `accessibilityHint` | `Tap to seek within analyzed audio. Seeks past unscanned audio move to the analyzed frontier. When analysis is complete, profanity mute regions appear as red marks on the bar.` |

**VoiceOver:** Users hear the label, then the value string (including `muteMarkers` count when complete). Per-marker positions are **not** exposed as separate elements in this slice.

### XCTest query helpers

```swift
/// Parses muteMarkers suffix; returns nil when key absent (in-flight).
static func muteMarkerCount(from barValue: String) -> Int? {
    guard let range = barValue.range(of: "muteMarkers:") else { return nil }
    let tail = barValue[range.upperBound...]
    let digits = tail.prefix(while: { $0.isNumber })
    return Int(digits)
}

/// Segment triple without mute suffix (complete bars).
static func segmentCounts(from barValue: String) -> (ready: Int, processing: Int, pending: Int)? {
    let segmentPart = barValue.split(separator: ",").filter { !$0.hasPrefix("muteMarkers:") }
    guard segmentPart.count == 3 else { return nil }
    func parse(_ s: Substring, prefix: String) -> Int? {
        guard s.hasPrefix(prefix), let v = Int(s.dropFirst(prefix.count)) else { return nil }
        return v
    }
    guard let r = parse(segmentPart[0], prefix: "ready:"),
          let p = parse(segmentPart[1], prefix: "processing:"),
          let n = parse(segmentPart[2], prefix: "pending:") else { return nil }
    return (r, p, n)
}
```

Use `app.descendants(matching: .any)["playback.superSeekBar"]` for all queries.

## Fixture modes

### `-UITestFixtureMuteMarkers` (AC#3 — primary)

| Concern | Value |
|---------|-------|
| Launch arg | `-UITestFixtureMuteMarkers` |
| Persistence | In-memory store (Library path) |
| Audio | Bundled **120.0 s** local file (may reuse `progressive-120s` or equivalent) |
| Cleaning | Channel + episode cleaning **on** |
| Analysis | **Immediate complete** snapshot (`processedEnd = 120.0`) — cache hit or instant analyzer |
| Cached intervals | **≥ 2** profanity mute intervals, e.g. `[0.92, 1.87)` and `[2.92, 3.32)` (may mirror `FixtureProgressivePlayback.firstChunkPartialIntervals`) |
| Ads | **None** (`adRanges: []` → no yellow) |
| Network | **No** live network on play path |

**Typical launch:** `-UITestFixtureMuteMarkers` **only** (exclusive fixture family).

**Pinned terminal AX:** `ready:12,processing:0,pending:0,muteMarkers:2`

### `-UITestFixtureMuteMarkersAdsOnly` (AC#4 — negative control)

| Concern | Value |
|---------|-------|
| Launch arg | `-UITestFixtureMuteMarkersAdsOnly` |
| Analysis | Immediate complete |
| Cached intervals | **One** `.unrelatedContent` + `.skip` span overlapping bucket(s) — e.g. `[35.0, 42.5)` on **120.0 s** (yields yellow on terminal bar) |
| Profanity mutes | **Zero** |
| Cleaning | **On** |

**Pinned terminal AX:** `ready:12,processing:0,pending:0,muteMarkers:0` with **≥ 1** yellow bucket visible (segment triple still sums to **12**).

Engineer may implement both modes in `FixtureMuteMarkers.swift` (or extend `FixtureTranscript` / `FixtureProgressivePlayback` with explicit interval seeds) as long as launch args and pinned counts match this table.

### Reused fixtures (cross-suite terminal updates)

| Launch arg | Terminal `muteMarkers` | Notes |
|------------|------------------------|-------|
| `-UITestFixtureProgressivePlayback` | `2` | Partial mutes from first chunk persist in cached schedule at terminal |
| `-UITestFixtureLibraryAnalysisTimeline` | `0` | No profanity mutes seeded |
| `-UITestFixtureTranscript` | `0` | Skip ad only; no profanity mute intervals |

**Navigation to full player** (all Slice 27 UI tests — same as Slice 25):

1. Wait for `libraryRoot` (**10 s**).
2. Tap `libraryCell_0` → wait for `episodeList`.
3. Tap `episodeCell_0` → wait for `miniPlayer` (**5 s**).
4. Tap `miniPlayer` (not `miniPlayerPlayPause`) → wait for `playback.playPause` (**5 s**).
5. Start playback if needed (`playback.playPause` → `playing`).

For **immediate-complete** fixtures, terminal `muteMarkers` may be assertable within **5.0 s** of step 4 without waiting for progressive pacing.

## UI test scenarios

Mapped tests: `PodWashUITests/SuperSeekBarUITests.swift` (AC#3–AC#4). Unit math: `PodWashTests/SuperSeekBarMuteMarkerTests.swift` (AC#1–AC#2).

### `testMuteMarkersExposedWhenProfanityMutePresent` (AC#3)

1. Launch with `-UITestFixtureMuteMarkers`; navigate to expanded full player (fixture navigation above).
2. Start playback if `playback.playPause` is not yet `playing`.
3. Within **5.0 s** of `playback.playPause` appearing, read `playback.superSeekBar` `accessibilityValue`.
4. Assert `segmentCounts(from: value)` equals **`(12, 0, 0)`**.
5. Assert `muteMarkerCount(from: value)` is **≥ 1** (pinned fixture: **== 2**).
6. Assert value **does not** equal in-flight `ready:3,processing:1,pending:8` (guards complete gate).

**Optional stricter assert (pinned fixture):** exact match `ready:12,processing:0,pending:0,muteMarkers:2`.

### `testMuteMarkersAbsentForAdsOnly` (AC#4)

1. Launch with `-UITestFixtureMuteMarkersAdsOnly`; navigate to expanded full player; start playback if needed.
2. Within **5.0 s**, read `playback.superSeekBar` `accessibilityValue`.
3. Assert exact string **`ready:12,processing:0,pending:0,muteMarkers:0`**.
4. Assert `segmentCounts(from: value)` equals **`(12, 0, 0)`** (yellow ad buckets still count toward `ready`, not `muteMarkers`).
5. Assert `muteMarkerCount(from: value) == 0`.
6. Assert `playback.superSeekBar` exists and `playback.elapsed` is present (no regression to cleaning-on chrome).

### UX regression scenarios (not slice ACs; QA updates in test-spec commit)

#### `testProgressiveMidRunOmitsMuteMarkersKey` (Slice 25 guard)

1. Launch `-UITestFixtureProgressivePlayback`; navigate to full player; start playback.
2. Within **5.0 s**, assert `playback.superSeekBar` `accessibilityValue == "ready:3,processing:1,pending:8"` **exactly** (no `muteMarkers` substring).

#### `testProgressiveTerminalIncludesMuteMarkers` (terminal string migration)

1. Launch `-UITestFixtureProgressivePlayback`; navigate to full player; start playback.
2. Within **10.0 s**, assert `playback.superSeekBar` `accessibilityValue == "ready:12,processing:0,pending:0,muteMarkers:2"`.

#### `testCleaningOffOmitsTimelineAndMarkers` (unchanged Slice 25)

1. Launch mute-markers or progressive fixture with cleaning forced off (existing Slice 09 toggle pattern if needed).
2. Assert `playback.superSeekBar` exists; `accessibilityValue` does **not** contain `ready:` or `muteMarkers:`.

## Verification mapping

| AC# | UX artifact | Test file / method |
|-----|-------------|-------------------|
| 1 | Normalized `[10,11)` on **120.0 s** → **±0.001** | `SuperSeekBarMuteMarkerTests.testSingleMuteMarkerNormalized` |
| 2 | Count **2** / **0**; ads alone → **0** | `SuperSeekBarMuteMarkerTests.testMuteMarkerCountIgnoresAds` |
| 3 | `-UITestFixtureMuteMarkers`, `muteMarkers ≥ 1` within **5.0 s** | `SuperSeekBarUITests.testMuteMarkersExposedWhenProfanityMutePresent` |
| 4 | `-UITestFixtureMuteMarkersAdsOnly`, `muteMarkers:0`, segment triple intact | `SuperSeekBarUITests.testMuteMarkersAbsentForAdsOnly` |
| 5 | — | Full `scripts/verify.sh` |
