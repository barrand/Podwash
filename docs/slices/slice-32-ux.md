# Slice 32 — UX spec: Transcript follow-along (karaoke + auto-scroll)

| Field | Value |
|-------|-------|
| **Slice** | 32 — Transcript follow-along (karaoke + auto-scroll) |
| **Screens** | `TranscriptView` (sheet, additive chrome); minimal `AppShellView` playhead pass-through |
| **ADR** | [ADR-028](../adr/028-transcript-follow-along.md) (active index rule, follow break seam, live playhead wiring, AX contract) |
| **Builds on** | [slice-26-ux.md](slice-26-ux.md) (transcript sheet, word AX, fixture, open-time scroll anchor), [slice-23-ux.md](slice-23-ux.md) (full-player entry), [slice-03-ux.md](slice-03-ux.md) (`playback.playPause`, `playback.elapsed`), [slice-21-ux.md](slice-21-ux.md) (`BrandTheme` tokens) |
| **Slice story** | [slice-32-transcript-follow-along.md](slice-32-transcript-follow-along.md) |

## Scope note

**Additive live-sync chrome on the existing transcript sheet.** While `transcript.view` is presented and playback is advancing, the **current word** is highlighted (karaoke), the list **auto-scrolls** to keep that word on screen when follow mode is **on**, a **manual scroll** turns follow **off** without freezing the highlight, and **`transcript.snapToFollow`** restores follow and scrolls to the live word.

**In scope:** per-word active state, follow flag, snap-back control, live playhead sampling, new AX hosts.

**Out of scope:** mini player under transcript (Task 027), tap-word-to-seek, sentence-only highlight, live recompute of listened/skipped-ad counts, CarPlay / lock-screen transcript, changing open-time `transcript.scrollAnchor` AC8 band (Slice 26).

**Entry path for follow UITests:** open transcript from the **expanded full player** while the **same episode is playing** so the shell passes a live `PlaybackEngine` playhead (ADR-028 §5). Episode-row entry without an active session is valid in production but **not** the AC#3–#8 harness path.

## Layout

### Transcript sheet (additive)

Extends Slice 26 `TranscriptView`. Unchanged: navigation title **Transcript**, optional **Close**, paragraph timestamps (Task 021), aggregate hidden hosts, word flow inside `ScrollView` + `ScrollViewReader`.

```text
┌─────────────────────────────────────┐
│  Transcript              [Close]    │
│  ─────────────────────────────────  │
│  (hidden AX: counts, anchor, follow)│
│                                     │
│  0:00                               │
│  word₀ word₁ [word₁₂] word₁₃ …    │  ← active word = distinct highlight
│  …                                  │
│                                     │
│                    [Follow ▼]       │  ← transcript.snapToFollow (follow off only)
└─────────────────────────────────────┘
```

Vertical structure, top → bottom:

1. **Navigation bar** — unchanged Slice 26.
2. **Scroll region** (`transcript.view` root contains the `ScrollView`) — flowing transcript with live active overlay on the current word.
3. **Snap-back control** — `transcript.snapToFollow`, **only when follow is off** (prefer absent from AX tree over disabled).
4. **Hidden accessibility hosts** — existing aggregates **plus** `transcript.followMode` and optional `transcript.activeWord` (see Accessibility).

### Snap-back control (`transcript.snapToFollow`)

| Attribute | Spec |
|-----------|------|
| **Placement** | Bottom-trailing **safe-area inset** inside `transcript.view`, **above** home indicator; **≥ 44×44 pt** hit target; does not obscure navigation bar |
| **Chrome** | `Button` with SF Symbol `arrow.down.to.line.compact` (or `text.line.first.and.arrowtriangle.forward`); filled capsule background `BrandTheme.surface` at **~90%** opacity + subtle stroke `BrandTheme.onSurface` **~20%** |
| **Visibility** | Rendered **iff** `isFollowModeOn == false` — remove from hierarchy when follow is on (AC#6) |
| **Z-order** | Above scroll content; does not block word taps (tap-to-seek remains out of scope — words are non-interactive) |

### Active word (karaoke)

| Attribute | Spec |
|-----------|------|
| **Grain** | **One** active word — index from `activeWordIndex(transcript:playhead:)` (ADR-028 §3) |
| **Visual** | Rounded rect “pill” behind the word: fill `BrandTheme.primary` at **~25%** opacity; foreground `BrandTheme.onSurface` at **full** opacity; optional **semibold** `.body` |
| **Precedence** | **Active wins** for the current word only — active styling is **additive** to listened / skipped-ad classification (skipped-ad yellow may show through pill edge; active pill still applied) |
| **Scroll target** | Word views keep `id(index)` for `ScrollViewReader.scrollTo(_:anchor:)` — **`.center`** anchor when follow is on |

**No** visible playhead cursor, progress bar, or per-word timestamps beyond existing paragraph headers.

## Color contract

Extends Slice 26 semantic roles. No pixel/snapshot ACs — AX values and viewport geometry prove behavior.

| Word state | Visual role | Token / style |
|------------|-------------|---------------|
| **Default** | Primary body | `BrandTheme.onSurface` |
| **Listened** | De-emphasized | `BrandTheme.onSurface` **~60%** opacity (unchanged) |
| **Skipped ad** | Ad span | `BrandTheme.accent` (unchanged) |
| **Active** (current playhead word) | Karaoke highlight | Pill `BrandTheme.primary` **~25%**; text `BrandTheme.onSurface` full opacity |
| **Active + listened** | Current word in past | Active pill + de-emphasized text inside pill |
| **Active + skipped ad** | Current word in ad span | Active pill over accent text |

**Precedence:** `skippedAd` classification unchanged; **active overlay** applies on top for the single current index only.

## States

### Follow mode

| State | `transcript.followMode` `accessibilityValue` | Auto-scroll | `transcript.snapToFollow` |
|-------|----------------------------------------------|-------------|---------------------------|
| **On** (default at sheet appear) | `on` | Scrolls to `activeWordIndex` on each change (after open-time anchor scroll) | **Absent** / not hittable |
| **Off** (user manual scroll) | `off` | Frozen — no programmatic `scrollTo` for follow | **Present** and hittable |
| **Restored** (tap snap-back) | `on` | Immediate scroll to current active word; resumes live follow | **Absent** / not hittable |

**Default on appear:** `isFollowModeOn = true` after Slice 26 one-shot open-time `scrollTo(scrollAnchorIndex)`.

### Active word index (live)

| Condition | Active index | Highlight | Follow scroll |
|-----------|--------------|-----------|---------------|
| Playhead inside word *i* `[start, end)` | *i* | `transcript.word_<i>` value includes `active`; `transcript.activeWord` = `"<i>"` | When follow **on**, scroll keeps word on screen |
| Playhead at word *i* `end` (boundary) | Per ADR-028 §3 table (AC#2 unit pin) | Same AX contract | Same |
| Follow **off**, playback advancing | Index still updates | Highlight updates within **1.0 s** of boundary (AC#8) | **No** scroll |
| No engine / wrong episode | Frozen at open-time resume index | Stable highlight | No-op after first appear |

### Open-time vs live (unchanged Slice 26 + additive)

| Concern | Source | Updates while sheet open? |
|---------|--------|---------------------------|
| `listened` / `skippedAd` / counts / `scrollAnchor*` | `TranscriptViewModel.make` at present | **No** |
| `activeWordIndex` | Live playhead (`TimelineView` ≤ **0.25 s**) | **Yes** |
| `isFollowModeOn` | `TranscriptView` state | User scroll → `off`; snap → `on` |

**Open-time scroll anchor:** `transcript.scrollAnchor` `accessibilityValue` remains **28…32** for fixture `playbackPosition = 30.0` on **first** appear (Slice 26 AC#8). Live follow does **not** change the published anchor seconds value.

### Pinned fixture indices (`-UITestFixtureTranscript`, 2.5 s words)

| Playhead *t* (s) | `activeWordIndex` | Notes |
|------------------|-------------------|-------|
| **30.0** (resume at open) | **12** | `30.0 ≤ t < 32.5` |
| **32.5** (boundary) | **13** | Contiguous words — containing rule |
| **35.0** | **14** | First word overlapping skipped-ad span starts at 35.0 |

## Interaction

| Action | Behavior |
|--------|----------|
| Sheet appears (playing session) | Open-time scroll to anchor (Slice 26); follow **on**; active word at live playhead |
| Playback advances, follow **on** | Active highlight moves; list auto-scrolls to keep active word midY in viewport |
| User vertical scroll / drag on transcript `ScrollView` | Follow → **off**; highlight **continues** updating; scroll position **stays** where user left it |
| Programmatic follow / open `scrollTo` | Follow stays **on** — must **not** clear follow |
| Tap `transcript.snapToFollow` (follow **off** only) | Follow → **on**; scroll to current active word |
| Tap word | **No-op** (out of scope) |
| Dismiss sheet | Follow state discarded; no persistence |

**Break trigger:** `ScrollView.onScrollPhaseChange` → `.interacting` when **not** a programmatic follow scroll (ADR-028 §6). XCTest uses a vertical swipe on `transcript.view`.

**No slider scrub** in transcript tests — use natural 1× playback advance and/or `playback.seekForward15` **before** opening the sheet when a pinned start index is needed.

## Accessibility identifiers

Query via `app.descendants(matching: .any)["<identifier>"]` unless noted.

### Additive hosts (transcript sheet)

| Control / region | `accessibilityIdentifier` | `accessibilityLabel` | `accessibilityValue` | `accessibilityHint` |
|------------------|---------------------------|----------------------|----------------------|---------------------|
| Follow mode (hidden) | `transcript.followMode` | `Transcript follow mode` | `on` \| `off` | `Whether the transcript scrolls with playback.` |
| Active word index (hidden, optional) | `transcript.activeWord` | `Active transcript word` | Decimal index string e.g. `12` | `Index of the word at the current playback position.` |
| Snap to follow | `transcript.snapToFollow` | `Follow transcript` | — | `Scrolls to the current word and turns follow mode on.` |

**Primary assert strategy (QA):** prefer `transcript.activeWord` `accessibilityValue` for index checks; fall back to `transcript.word_<i>` value containing `active` (ADR-028 requires at least one).

### Per-word value contract (updated)

Extends Slice 26. `<index>` is **0-based**.

| Condition | `transcript.word_<index>` `accessibilityValue` |
|-----------|-----------------------------------------------|
| Active only | `active` |
| Active + listened | `listened,active` (comma-separated, order fixed) |
| Active + skipped ad | `skippedAd,active` |
| Listened only | `listened` |
| Skipped ad only | `skippedAd` |
| Neither | omitted or empty |

**Unchanged identifiers:** `transcript.view`, `transcript.wordCount`, `transcript.listenedCount`, `transcript.skippedAdCount`, `transcript.scrollAnchor`, `transcript.word_<index>` labels, `transcript.paragraph_<n>.timestamp`, entry affordances `episode.viewTranscript`, `playback.viewTranscript`, player chrome ids.

## Fixture modes

### `-UITestFixtureTranscript` (AC#3–#8 — extended harness)

Reuses Slice 26 fixture constants. **No new launch arg required** unless Engineer adds an optional playhead helper (ADR-028).

| Concern | Value |
|---------|-------|
| Launch arg | `-UITestFixtureTranscript` |
| Transcript | **24** words × **2.5** s, span **0.0–60.0** s |
| Resume at open | `playbackPosition = **30.0**` → anchor index **12**, `scrollAnchor` **28…32** |
| Intervals | Unrelated skip **35.0–42.5** s (unchanged) |
| Audio | Bundled local file — **play path required** |
| Live playhead | User starts playback **before** presenting transcript from full player |

**Typical launch:** `-UITestFixtureTranscript` only.

**Optional Engineer helper (non-blocking):** `-UITestFixtureTranscriptAutoPlay` — if natural 1× advance is flaky in CI, auto-start playback at resume position on full-player expand. UX pins **behavior** for tests below; flag name is Engineer/QA choice.

### Production (no fixture args)

Follow-along runs when transcript sheet is open over a playing session. Slice ACs **do not** map production UI tests without fixtures.

## Navigation helpers (UI tests)

### Library → expanded full player, playing

1. Launch `-UITestFixtureTranscript`; wait for `libraryRoot` (**10 s**).
2. Tap `libraryCell_0` → wait for `episodeList` (**5 s**).
3. Tap `episodeCell_0` → wait for `miniPlayer` (**5 s**).
4. If `miniPlayerPlayPause` `accessibilityValue != "playing"`, tap `miniPlayerPlayPause`; within **5 s** assert `playing`.
5. Tap `miniPlayer` bar (not `miniPlayerPlayPause`) → wait for `playback.playPause` (**5 s**).
6. If `playback.playPause` `accessibilityValue != "playing"`, tap once; assert `playing`.

### Open transcript while playing (AC#3–#8 base)

1. Complete **Library → full player, playing** helper above.
2. Tap `playback.viewTranscript`.
3. Within **3 s**, assert `transcript.view` exists.
4. Within **1 s**, assert `transcript.followMode` `accessibilityValue == "on"`.
5. Within **1 s**, assert active index **12** at resume (`transcript.activeWord == "12"` **or** `transcript.word_12` value contains `active`).

### Viewport on-screen helper (recommended)

```swift
/// Active word midY must fall inside transcript.view visible frame (AC#4, #7).
func assertWordMidYInTranscriptViewport(wordIndex: Int, in app: XCUIApplication) {
    let viewport = app.descendants(matching: .any)["transcript.view"]
    let word = app.descendants(matching: .any)["transcript.word_\(wordIndex)"]
    XCTAssertTrue(viewport.exists && word.exists)
    let midY = word.frame.midY
    XCTAssertGreaterThanOrEqual(midY, viewport.frame.minY)
    XCTAssertLessThanOrEqual(midY, viewport.frame.maxY)
}
```

### Manual scroll break helper (AC#5)

1. Record `transcript.view` frame origin (or first visible word midY).
2. Vertical swipe on `transcript.view`: start **(0.5, 0.7)**, end **(0.5, 0.3)** normalized coordinates.
3. Within **1 s**, assert `transcript.followMode` `accessibilityValue == "off"`.
4. Wait **≥ 2.0 s** while playback remains `playing`.
5. Assert scroll offset **unchanged** (origin delta **< 8 pt** **or** previously off-screen word still off-screen).

### Wait for active index (polling)

Poll every **0.05 s** up to **1.0 s** for `transcript.activeWord` `accessibilityValue == "<expected>"` (or word value contains `active`).

## UI test scenarios

Mapped tests: `PodWash/PodWashUITests/TranscriptUITests.swift` (AC#3–#8). Unit AC#1–#2: `TranscriptViewModelTests` (not UX-mapped).

**Timeouts:** follow/active asserts **1.0 s**; transcript open **3.0 s**; playback start **5.0 s**; manual-scroll freeze observation **≥ 2.0 s**.

### `testActiveWordUpdatesWithPlayback` (AC#3)

1. Launch `-UITestFixtureTranscript`.
2. Open transcript while playing (helper); confirm follow `on` and initial active **12**.
3. Wait until `transcript.activeWord` `accessibilityValue == "13"` (natural playback crosses **32.5 s** boundary) **or** poll `transcript.word_13` value contains `active` — within **1.0 s** of boundary crossing.
4. Assert previous word **12** value no longer contains `active` (optional stricter check).

### `testFollowModeAutoScrollsActiveWordOnScreen` (AC#4)

1. Launch fixture; open transcript while playing at index **12** near bottom of long content — if word **12** already on screen, swipe up manually to move it off screen, then tap `transcript.snapToFollow` to restore follow (setup) **or** wait for natural advance.
2. With follow `on`, observe **two** successive boundary crossings (e.g. **12 → 13 → 14**).
3. Within **1.0 s** of each crossing, call `assertWordMidYInTranscriptViewport` for the new active index.

### `testManualScrollDisablesFollowMode` (AC#5)

1. Launch fixture; open transcript while playing; assert follow `on`.
2. Perform manual scroll break helper.
3. Assert `transcript.followMode` `accessibilityValue == "off"` within **1.0 s**.
4. With `playback.playPause` still `playing`, wait **≥ 2.0 s**.
5. Assert transcript scroll offset did **not** jump back toward the active word (frozen follow).

### `testSnapToFollowVisibleOnlyWhenFollowOff` (AC#6)

1. Launch fixture; open transcript while playing.
2. Assert `transcript.followMode` `on`; assert `transcript.snapToFollow` **does not exist** or `isHittable == false`.
3. Perform manual scroll break; assert follow `off`.
4. Within **1.0 s**, assert `transcript.snapToFollow` exists and `isHittable`.
5. Tap `transcript.snapToFollow`; within **1.0 s** assert follow `on` and snap control not hittable again.

### `testSnapToFollowRestoresFollowAndScroll` (AC#7)

1. Launch fixture; open transcript while playing.
2. Manual scroll break → follow `off`.
3. Wait until active index advances to **≥ 13** (playback continues).
4. Tap `transcript.snapToFollow`.
5. Within **1.0 s**, assert `transcript.followMode` `accessibilityValue == "on"`.
6. Within **1.0 s**, `assertWordMidYInTranscriptViewport` for current `transcript.activeWord` index.

### `testActiveWordStillUpdatesWhenFollowOff` (AC#8)

1. Launch fixture; open transcript while playing.
2. Manual scroll break → follow `off`.
3. Record current active index *i*.
4. Wait for next boundary *i+1* (poll playhead via `transcript.activeWord` or `playback.elapsed` ≥ next word start).
5. Within **1.0 s** of boundary, assert active index updated to *i+1* while `transcript.followMode` remains `off`.
6. Assert `assertWordMidYInTranscriptViewport` for *i+1* is **not** required (word may be off screen).

## Verification mapping

| AC# | UX artifact | Test file / method |
|-----|-------------|-------------------|
| 1 | Active index containing word (unit) | `TranscriptViewModelTests.testActiveWordIndexMatchesPlayheadContainingWord` |
| 2 | Boundary index pin (unit) | `TranscriptViewModelTests.testActiveWordIndexAtWordEndBoundary` |
| 3 | `testActiveWordUpdatesWithPlayback` | `TranscriptUITests.testActiveWordUpdatesWithPlayback` |
| 4 | `testFollowModeAutoScrollsActiveWordOnScreen` | `TranscriptUITests.testFollowModeAutoScrollsActiveWordOnScreen` |
| 5 | `testManualScrollDisablesFollowMode` | `TranscriptUITests.testManualScrollDisablesFollowMode` |
| 6 | `testSnapToFollowVisibleOnlyWhenFollowOff` | `TranscriptUITests.testSnapToFollowVisibleOnlyWhenFollowOff` |
| 7 | `testSnapToFollowRestoresFollowAndScroll` | `TranscriptUITests.testSnapToFollowRestoresFollowAndScroll` |
| 8 | `testActiveWordStillUpdatesWhenFollowOff` | `TranscriptUITests.testActiveWordStillUpdatesWhenFollowOff` |
| 9 | — | Full `scripts/verify.sh` |

## UX regression scenarios (optional QA — not slice ACs)

### `testFollowModeOnByDefaultAfterOpen`

1. Open transcript while playing.
2. Assert `transcript.followMode` `accessibilityValue == "on"` without user interaction.

### `testOpenTimeScrollAnchorUnchangedWithFollow`

1. Open transcript via episode row (resume **30.0**).
2. Assert `transcript.scrollAnchor` `accessibilityValue` as `Int` is **≥ 28** and **≤ 32** (Slice 26 AC#8 regression).

### `testListenedAndSkippedAdValuesPreservedWhenActive`

1. Open transcript while playing; advance into skipped-ad word **14** at **35.0 s**.
2. Assert `transcript.word_14` `accessibilityValue == "skippedAd,active"`.
