# Slice 26 — UX spec: Episode transcript viewer

| Field | Value |
|-------|-------|
| **Slice** | 26 — Episode transcript viewer |
| **Screens** | `EpisodeListView` (row affordance); expanded `PlaybackControlsView` (toolbar affordance); `TranscriptView` (sheet) |
| **ADR** | [ADR-022](../adr/022-transcript-cache.md) (cache, classification, accessibility contract, fixture) |
| **Builds on** | [slice-06-ux.md](slice-06-ux.md) (`episodeList`, `episodeCell_<index>`), [slice-09-ux.md](slice-09-ux.md) (row trailing accessories), [slice-23-ux.md](slice-23-ux.md) (Library → detail → mini-player → full-player sheet), [slice-25-ux.md](slice-25-ux.md) (progressive in-flight negative — AC9), [slice-21-ux.md](slice-21-ux.md) (`BrandTheme` tokens; dark-only) |
| **Slice story** | [slice-26-episode-transcript-viewer.md](slice-26-episode-transcript-viewer.md) |

## Scope note

**Read-only transcript sheet.** Users preview episode text, see which words they have already listened to, and see which words fell inside skipped unrelated-content spans. **No** tap-word-to-seek, search, copy/share, speaker labels, profanity highlighting, or progressive partial display.

**Entry points (only two):**

1. **Episode row** — trailing `episode.viewTranscript` when a **complete** cached transcript exists.
2. **Expanded full player** — `playback.viewTranscript` (content-tree overlay) under the same gate.

**Affordance hidden** when `TranscriptCache.exists(episodeID:)` is false — including during in-flight progressive analysis (AC9). Mini-player, lock screen, and CarPlay have **no** transcript entry (out of scope).

**Text content:** raw ASR `TimedWord.word` strings in order; profanity is **not** redacted in display.

## Layout

### Episode row affordance (`episode.viewTranscript`)

Extends Slice 06 / 09 / 20 episode row. Trailing accessory area (same band as `episodeCleaningToggle_<index>` / `downloadButton_<index>`):

| Control | Placement | Visible chrome |
|---------|-----------|----------------|
| `episode.viewTranscript` | Trailing `Button` on row *i* | SF Symbol `text.alignleft` (or `doc.text`) at **≥ 44×44 pt** hit target |

- Shown **only** when transcript file exists for that episode.
- Tapping opens the transcript sheet for that episode; **does not** start playback or push a new screen.
- Row tap-to-play (`episodeCell_<index>`) remains unchanged; transcript button is a discrete child (same hit-target discipline as `miniPlayerPlayPause` vs `miniPlayer`).

### Full-player affordance (`playback.viewTranscript`)

Inside the expanded player `NavigationStack` (Slice 23 sheet hosting `PlaybackControlsView`):

| Control | Placement | Visible chrome |
|---------|-----------|----------------|
| `playback.viewTranscript` | `AppShellView` content-tree overlay on full-player sheet (topLeading + safe-area), not `ToolbarItem` | Same symbol as row affordance; label via accessibility only. ToolbarItem wraps the control so `descendants(.any)` matches both Other + Button (ambiguous tap). |
| Done (unchanged) | `ToolbarItem(placement: .topBarTrailing)` | Dismisses full player only — **not** the transcript sheet |

- Shown only when transcript exists for the **currently playing** episode.
- Tapping presents the transcript sheet **on top of** the full-player sheet (nested sheet from `AppShellModel`).

### Transcript sheet (`TranscriptView`)

**Presentation:** `.sheet` owned by `AppShellModel` (e.g. `transcriptSheetEpisodeID`). `NavigationStack` root:

```text
┌─────────────────────────────────────┐
│  Transcript              [Close]    │  ← navigation title; optional Close (not AC-mapped)
│  ─────────────────────────────────  │
│  (hidden AX aggregates — see A11y)  │
│                                     │
│  word₀ word₁ word₂ word₃ …         │  ← single scrollable flow (LazyVStack / wrapped Text)
│  …                                  │
│                                     │
└─────────────────────────────────────┘
```

Vertical structure, top → bottom:

1. **Navigation bar** — title **Transcript**; optional trailing **Close** (dismisses transcript sheet only).
2. **Scroll region** (`ScrollView` + `ScrollViewReader`) — flowing transcript:
   - Words in index order, separated by spaces (or natural inline flow).
   - Each word is an accessibility element `transcript.word_<index>`.
   - Minimum readable body size: `.body` Dynamic Type.
3. **Hidden accessibility hosts** (off-screen or `accessibilityHidden` from visual tree where appropriate) — aggregate counts + scroll anchor (see Accessibility).

**Background:** `BrandTheme.surface`. Primary text `BrandTheme.onSurface`.

**Z-order when both sheets open:** full player (under) → transcript sheet (top). Dismissing transcript returns to full player or episode list unchanged.

## Color contract

Semantic foreground roles (dark theme). Engineer may implement via `foregroundStyle`, opacity, or background pill — **no** pixel/snapshot ACs; counts and identifiers prove behavior.

| Word state | Visual role | Token / style |
|------------|-------------|---------------|
| **Default** (not listened, not skipped ad) | Primary body text | `BrandTheme.onSurface` |
| **Listened** (`end ≤ playbackPosition`, not skipped ad) | De-emphasized / already heard | `.secondary` foreground **or** `BrandTheme.onSurface` at **~60%** opacity |
| **Skipped ad** (overlaps unrelated `skip` interval) | Ad/superfluous span (aligns with Slice 20 yellow ad semantic) | `BrandTheme.accent` (`#E9C46A`) |
| **Profanity** (mute intervals only) | **No** special styling — same as default or listened per rules above | — |

**Precedence:** `skippedAd` styling wins over `listened` (mutual exclusion in `TranscriptViewModel`).

**Out of scope:** profanity highlight, per-word timestamps in the visible UI, speaker color coding.

## States

### Affordance visibility

| Condition | `episode.viewTranscript` | `playback.viewTranscript` |
|-----------|------------------------|---------------------------|
| **No transcript file** | Absent (not in AX tree / not hittable) | Absent |
| **Progressive analysis in flight** (no terminal file yet) | Absent | Absent |
| **Complete transcript on disk** | Present on analyzed episode rows | Present when that episode is loaded in full player |
| **Transcript sheet open** | Row affordance still visible underneath | Player affordance still visible under nested sheet |

No separate loading spinner on the affordance — gate is synchronous `exists` check.

### Transcript sheet

| State | Visible UI | Root identifier | Notes |
|-------|------------|-----------------|-------|
| **Ready** | Scrollable word flow + aggregates | `transcript.view` | Fixture loads synchronously before first frame |
| **Empty transcript** | — | — | **Do not present** — `store` with 0 words is invalid for this slice; affordance requires non-empty cache in fixtures |
| **Loading / error** | — | — | No separate identifiers; failed load → sheet not presented |

### Classification (ViewModel → UI)

Pinned fixture math (`-UITestFixtureTranscript`, `playbackPosition = 30.0`):

| Metric | Rule | Pinned value |
|--------|------|--------------|
| `wordCount` | `transcript.count` | **24** |
| `listenedCount` | words with `end ≤ playbackPosition`, excluding skipped-ad | **12** |
| `skippedAdCount` | words overlapping unrelated `skip` interval `35.0–42.5` s | **3** |
| `scrollAnchorSeconds` | word containing `playbackPosition`, else last listened word, else `0`; `Int(round(anchor.start))` | **28–32** (position **30.0** on 2.5 s words) |

**Overlap rule:** `word.start < interval.end && word.end > interval.start`.

**Mutual exclusion:** no word is both `listened` and `skippedAd`.

### Scroll-to-position on open

When `playbackPosition > 0` and the sheet **first appears**:

1. Compute `scrollAnchorSeconds` per ADR-022 / ViewModel.
2. `ScrollViewReader.scrollTo` the word index whose `start` is nearest the anchor (same index that drives `scrollAnchorSeconds`).
3. Publish `transcript.scrollAnchor` `accessibilityValue` **before** or **with** the scroll animation completing (XCTest polls on first open within **3.0 s** — AC8).

When `playbackPosition <= 0`: anchor **0**; no auto-scroll required (optional scroll to top).

**No** scroll sync with live playback while the sheet stays open (out of scope).

## Interaction

| Action | Behavior |
|--------|----------|
| Tap `episode.viewTranscript` | Present transcript sheet for that episode; load cache + intervals + resume position |
| Tap `playback.viewTranscript` | Same sheet for current episode |
| Scroll transcript | Standard vertical scroll; no snap-to-word |
| Tap word | **No-op** (tap-to-seek out of scope) |
| Dismiss transcript | Swipe down or optional **Close** — returns to underlying screen |
| Dismiss full player while transcript open | Engineer choice: dismiss transcript first or together; **not** AC-mapped |

## Accessibility identifiers

Query via `app.descendants(matching: .any)["<identifier>"]` unless noted.

### Entry affordances

| Control | `accessibilityIdentifier` | `accessibilityLabel` | `accessibilityValue` | `accessibilityHint` |
|---------|---------------------------|----------------------|----------------------|---------------------|
| Episode row transcript | `episode.viewTranscript` | `View transcript` | — | `Shows the episode transcript.` |
| Full player transcript | `playback.viewTranscript` | `View transcript` | — | `Shows the episode transcript.` |

**Row scoping:** `episode.viewTranscript` is a descendant of `episodeCell_<index>` (prefer `app.cells["episodeCell_0"].buttons["episode.viewTranscript"]` or descendant search).

### Transcript sheet

| Control / region | `accessibilityIdentifier` | `accessibilityLabel` | `accessibilityValue` | `accessibilityHint` |
|------------------|---------------------------|----------------------|----------------------|---------------------|
| Sheet root | `transcript.view` | `Transcript` | — | — |
| Word count (aggregate) | `transcript.wordCount` | `Word count` | Decimal string e.g. `24` | — |
| Listened count (aggregate) | `transcript.listenedCount` | `Listened word count` | Decimal string e.g. `12` | — |
| Skipped ad count (aggregate) | `transcript.skippedAdCount` | `Skipped ad word count` | Decimal string e.g. `3` | — |
| Scroll anchor (hidden) | `transcript.scrollAnchor` | `Transcript scroll position` | Whole seconds as decimal string e.g. `30` | `Seconds position scrolled to on open.` |
| Word *i* | `transcript.word_<index>` | The word text (e.g. `hello`) | `listened` / `skippedAd` / omitted | — |

**Index convention:** `<index>` is **0-based** in transcript array order.

**Per-word value contract:**

- `skippedAd == true` → `accessibilityValue == "skippedAd"` (listened suppressed).
- Else `listened == true` → `accessibilityValue == "listened"`.
- Else omit `accessibilityValue` (or empty).

**Aggregate placement:** Hidden accessibility elements grouped at the top of `transcript.view` (visible to XCTest, not required to be on-screen). Values must update when the sheet appears.

**Unchanged identifiers:** `libraryRoot`, `libraryCell_*`, `episodeList`, `episodeCell_*`, `miniPlayer`, `playback.playPause`, `playback.superSeekBar`, etc.

## Fixture modes

### `-UITestFixtureTranscript` (AC4–AC8)

| Concern | Value |
|---------|-------|
| Launch arg | `-UITestFixtureTranscript` |
| Persistence | In-memory store (same policy as `-UITestFixtureLibrary`) |
| Feed / library | Seeded library with **≥ 1** show; lands on **Library** tab |
| Episode | Row **0** in first subscribed show's episode list |
| Transcript | **24** words, **2.5** s each, span **0.0–60.0** s; written to `TranscriptCache` before first frame |
| Intervals | ≥ 1 `unrelatedContent` + `skip` spanning **35.0–42.5** s |
| Resume | `playbackPosition = **30.0**` preset on episode |
| Audio | Bundled local file (play path available for AC6) |
| Network | **No** live network for Library → detail |

**Typical launch:** `-UITestFixtureTranscript` **only** (do not combine with `-UITestFixtureFeed`, `-UITestFixtureAudio`, or other exclusive fixtures).

**No-transcript control (AC7):** Same fixture family with transcript file **omitted** (intervals + resume may still be seeded). Launch arg: e.g. `-UITestFixtureTranscript` + `-UITestFixtureTranscriptNoCache` or dedicated negative flag — Engineer implements one explicit arg; UX pins **behavior** (affordances absent), not the flag name, except AC7 tests use the QA-chosen negative mode bundled with fixture helper.

### `-UITestFixtureProgressivePlayback` (AC9 — reused from Slice 25)

Unchanged Slice 25 fixture. Cleaning **on**. After play start, `playback.superSeekBar` shows `ready:3,processing:1,pending:8` while **no** terminal transcript file exists → `episode.viewTranscript` **absent**.

### Production (no fixture args)

Affordances follow real `TranscriptCache.exists`; sheet reads cache only (no ASR on open). Slice ACs **do not** map production UI tests without fixtures.

## Navigation helpers (UI tests)

### Library → episode list (rows 0)

1. Wait for `libraryRoot` (**10 s**).
2. Tap `libraryCell_0` → wait for `episodeList` (**5 s**).

### Episode row → transcript (AC4, AC5, AC8)

1. Complete library navigation above.
2. Tap `episode.viewTranscript` within row 0 (descendant of `episodeCell_0`).
3. Within **3.0 s**, assert `transcript.view` exists.

### Episode play → full player → transcript (AC6)

1. Complete library navigation above.
2. Tap `episodeCell_0` → wait for `miniPlayer` (**5 s**).
3. Tap `miniPlayer` (bar chrome, **not** `miniPlayerPlayPause`) → wait for `playback.playPause` (**5 s**).
4. Tap `playback.viewTranscript`.
5. Within **3.0 s**, assert `transcript.view` exists.

### Progressive negative (AC9)

1. Launch `-UITestFixtureProgressivePlayback`; navigate to episode list (Slice 25 helper).
2. Enable cleaning if needed; tap `episodeCell_0` → expand full player per Slice 25.
3. Tap `playback.playPause` if not `playing`.
4. Within **5.0 s**, assert `playback.superSeekBar` `accessibilityValue == "ready:3,processing:1,pending:8"`.
5. Assert `episode.viewTranscript` does **not** exist (or is not hittable).

## UI test scenarios

Mapped tests: `PodWashUITests/TranscriptUITests.swift` (AC4–AC9).

**Query helpers:** parse aggregate `accessibilityValue` strings as integers for numeric asserts; use exact string match for `playback.superSeekBar` in AC9.

### `testEpisodeRowOpensTranscriptWithCounts` (AC#4)

1. Launch with `-UITestFixtureTranscript`.
2. Navigate library → episode list (helper above).
3. Tap `episode.viewTranscript` on row 0.
4. Within **3.0 s**, assert `transcript.view` exists.
5. Assert `transcript.wordCount` `accessibilityValue == "24"`.
6. Assert `transcript.listenedCount` `accessibilityValue == "12"`.

### `testTranscriptShowsSkippedAdCount` (AC#5)

1. Launch with `-UITestFixtureTranscript`; open transcript via episode row (steps 1–4 of AC#4).
2. Assert `transcript.skippedAdCount` `accessibilityValue == "3"`.

### `testFullPlayerOpensSameTranscript` (AC#6)

1. Launch with `-UITestFixtureTranscript`.
2. Navigate to expanded full player for episode 0 (helper above).
3. Tap `playback.viewTranscript`.
4. Within **3.0 s**, assert `transcript.view` exists.
5. Assert `transcript.wordCount` `accessibilityValue == "24"`.

### `testTranscriptAffordanceHiddenWithoutCache` (AC#7)

1. Launch with no-transcript control fixture (transcript file omitted).
2. Navigate library → episode list.
3. Assert `episode.viewTranscript` is **not** hittable (or does not exist) on row 0.
4. Tap `episodeCell_0` → expand full player.
5. Assert `playback.viewTranscript` is **not** hittable (or does not exist).

### `testTranscriptScrollsNearPlaybackPosition` (AC#8)

1. Launch with `-UITestFixtureTranscript`; open transcript via episode row.
2. On **first** open (do not dismiss/reopen), read `transcript.scrollAnchor` `accessibilityValue` as `Int`.
3. Assert value is **≥ 28** and **≤ 32**.

### `testTranscriptHiddenDuringProgressiveAnalysis` (AC#9)

1. Launch with `-UITestFixtureProgressivePlayback`.
2. Follow progressive negative navigation helper.
3. Within **5.0 s** of play start, assert `playback.superSeekBar` `accessibilityValue == "ready:3,processing:1,pending:8"`.
4. Assert `episode.viewTranscript` does **not** exist.

### UX smoke scenarios (not slice ACs; optional QA)

#### `testTranscriptWordAccessibilityValues`

1. Open transcript fixture with known skipped-ad words (indices overlapping **35.0–42.5** s).
2. Assert `transcript.word_<i>` `accessibilityValue == "skippedAd"` for pinned skipped indices.
3. Assert a known listened index (e.g. word with `end ≤ 30`) has `accessibilityValue == "listened"`.

#### `testTranscriptDismissReturnsToPlayer`

1. Open transcript from full player; dismiss via swipe.
2. Assert `transcript.view` does not exist; `playback.playPause` still exists.

## Verification mapping

| AC# | UX artifact | Test file / method |
|-----|-------------|-------------------|
| 1 | Cache round-trip (unit) | `TranscriptCacheTests.testStoreLoadRoundTrip` |
| 2 | Pipeline persist + cache hit (unit) | `AnalysisPipelineTests.testAnalyzePersistsTranscriptAndReusesCache` |
| 3 | Listened / skippedAd flags (unit) | `TranscriptViewModelTests.testListenedAndSkippedAdWordFlags` |
| 4 | `testEpisodeRowOpensTranscriptWithCounts` | `TranscriptUITests.testEpisodeRowOpensTranscriptWithCounts` |
| 5 | `testTranscriptShowsSkippedAdCount` | `TranscriptUITests.testTranscriptShowsSkippedAdCount` |
| 6 | `testFullPlayerOpensSameTranscript` | `TranscriptUITests.testFullPlayerOpensSameTranscript` |
| 7 | `testTranscriptAffordanceHiddenWithoutCache` | `TranscriptUITests.testTranscriptAffordanceHiddenWithoutCache` |
| 8 | `testTranscriptScrollsNearPlaybackPosition` | `TranscriptUITests.testTranscriptScrollsNearPlaybackPosition` |
| 9 | `testTranscriptHiddenDuringProgressiveAnalysis` | `TranscriptUITests.testTranscriptHiddenDuringProgressiveAnalysis` |
| 10 | `remove` clears cache (unit) | `TranscriptCacheTests.testRemoveClearsTranscript` |
| 11 | — | Full `scripts/verify.sh` |
