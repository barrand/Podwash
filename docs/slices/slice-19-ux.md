# Slice 19 — UX spec: Unrelated-content integration (skip override + toggles)

| Field | Value |
|-------|-------|
| **Slice** | 19 — Segmentation integration |
| **Screens** | `SettingsView` (global defaults), `PodcastDetailView` (per-channel toggle), player chrome (`SkipOverrideBanner` overlay) |
| **ADR** | [ADR-013](../adr/013-segmentation-integration.md) §3.6–3.7 (override seam, settings/channel toggles) |
| **PRD** | §4 — skip/mute unrelated segments; visible + overridable skips; **off by default** |

## Layout

### Settings — new **Unrelated content** section

Insert a grouped section in `SettingsView` **below** **Cleaning defaults** and **above** **Word categories**:

1. **Skip unrelated content** — `Toggle` (`unrelatedContentToggle`). Visible label: **Skip unrelated content**.
2. **Unrelated content action** — one discrete button (`unrelatedContentActionControl`) cycles **Skip** ↔ **Mute**. Same interaction pattern as `defaultActionControl` (Slice 13): no slider, no segmented control scrub.

**Visibility:** `unrelatedContentActionControl` is **enabled and visible only when** `unrelatedContentToggle` is on. When the global toggle is off, hide the action row or show it disabled with `accessibilityValue` still reflecting the stored preference (`"skip"` at fresh default) — Engineer picks one; UI tests for AC#5 only assert the global toggle at launch.

### Podcast detail — per-channel toggle

Extend `PodcastDetailView` header (`slice-09-ux.md`), in the trailing `VStack` **below** `channelCleaningToggle`:

3. **Channel unrelated content** — `Toggle` (`channelUnrelatedContentToggle`). Visible label: **Skip unrelated on channel** (caption style, matching channel cleaning row).

No new episode-row toggles in this slice. Unrelated-content enablement is **channel-wide + global** only (`effectiveUnrelated = settings.unrelatedContentEnabled && channelUnrelatedContentEnabled` per ADR-013).

### Player — skip-override banner

Overlay on the active player surface (`PlaybackControlsView` in production chrome; minimal player in skip fixture):

4. **Skip override banner** — full-width tappable strip anchored **above** transport controls (bottom safe area). Visible copy pattern:

   > **Skipped ~{n}s — tap to play**

   where `{n}` is `Int((end − start).rounded())` seconds (e.g. stub interval `[2.0, 5.0]` → **Skipped ~3s — tap to play**). Friendly copy is allowed; **`accessibilityValue` must be the numeric string only** (e.g. `"3"`), not the full sentence.

**Scope:** banner appears **only** after an **unrelated-content** `.skip` boundary fires. Profanity skips and mute actions do **not** show this banner (ADR-013 §3.6).

**Out of scope (no UI in this slice):** lock-screen / CarPlay banner (Slices 14/15), analysis timeline segment colors (Slice 20), re-analysis prompts when toggles change, attorney ship gate.

## States

### Global unrelated-content toggle (`unrelatedContentToggle`)

| State | `accessibilityValue` | Visible UI |
|-------|----------------------|------------|
| **Off** (fresh default) | `"0"` | Toggle off; action row hidden or disabled |
| **On** | `"1"` | Toggle on; `unrelatedContentActionControl` enabled |

### Unrelated-content action (`unrelatedContentActionControl`)

| State | `accessibilityValue` | `accessibilityLabel` |
|-------|----------------------|----------------------|
| **Skip** (fresh default) | `"skip"` | `Unrelated content action` |
| **Mute** | `"mute"` | `Unrelated content action` |

**Interaction:** each tap cycles `skip → mute → skip`. Updates synchronously on the main actor before XCTest post-tap idle.

### Channel unrelated-content toggle (`channelUnrelatedContentToggle`)

| State | `accessibilityValue` | Notes |
|-------|----------------------|-------|
| **Off** (fresh default / new podcast) | `"0"` | Even if global toggle is on, effective enable is false |
| **On** | `"1"` | Contributes to effective enable when global is also on |

Uses `"1"` / `"0"` contract (Slice 13 settings toggles), **not** `on` / `off` (Slice 09 channel cleaning).

### Skip-override banner (`skipOverrideBanner`)

| State | Visible UI | `accessibilityValue` | When |
|-------|------------|----------------------|------|
| **Hidden** | No banner | — | Before first unrelated skip; after dismiss (see below) |
| **Visible** | Banner with skip copy | Rounded skipped seconds as decimal string (e.g. `"3"`, `"13"`) | After unrelated `.skip` seek lands in `[end − 0.1, end]` |

**Dismiss rules (visible → hidden):**

1. **Tap** — invokes `overrideUnrelatedContentSkip`; seeks to `[start ± 0.05 s]`; banner hides immediately; playback stays `.playing`.
2. **Playback passes segment `end`** without tap — banner hides (user accepted the skip).
3. **Optional auto-dismiss** — Engineer may hide after **30 s**; not AC-mapped.

**While visible:** entire banner is one button (`Button` or `accessibilityAddTraits(.isButton)`). Single tap target; no separate close affordance.

### Player fixture bootstrap (`-UITestFixtureSkipOverride`)

| State | Root identifier | Notes |
|-------|-----------------|-------|
| **Loading** | `playback.loading` | Resolves within **10 s** |
| **Ready** | `playback.playPause` exists | Auto-starts playback on appear so stub skip at **2.0 s** fires without manual play tap |

## Accessibility identifiers

| Control / region | `accessibilityIdentifier` | `accessibilityLabel` | `accessibilityValue` | `accessibilityHint` |
|------------------|---------------------------|----------------------|----------------------|---------------------|
| Global unrelated toggle | `unrelatedContentToggle` | `Skip unrelated content` | `"1"` / `"0"` | `Skips or mutes segments that seem unrelated to the story.` |
| Unrelated action control | `unrelatedContentActionControl` | `Unrelated content action` | `skip` / `mute` | `Chooses skip or mute for unrelated segments.` |
| Channel unrelated toggle | `channelUnrelatedContentToggle` | `Channel unrelated content` | `"1"` / `"0"` | `Enables unrelated-content handling for this podcast when on.` |
| Skip override banner | `skipOverrideBanner` | `Skipped segment` | Rounded seconds only (e.g. `"3"`) | `Tap to play the skipped segment.` |
| Elapsed time (replay assert) | `playback.elapsed` | `Elapsed time` | Whole seconds as decimal string | Reuse Slice 03 contract |

Existing identifiers (`settingsRoot`, `channelCleaningToggle`, `episodeList`, `playback.playPause`, etc.) are unchanged.

**Toggle contract:** `unrelatedContentToggle` and `channelUnrelatedContentToggle` expose `accessibilityValue` `"1"` / `"0"`. UI tests may query via `app.switches[...]` or `app.buttons[...]` per platform mapping; post-tap value must be stable.

**Banner contract:** `accessibilityValue` is **only** the rounded skip duration string. Visible label may include words; tests assert `accessibilityValue` contains the expected digit(s) (AC#4: `"3"` for stub `[2.0, 5.0]`).

**Cell scoping:** all identifiers are globally queryable on `XCUIApplication` (descendant search).

## Fixture modes

### Skip-override fixture (new)

Launch argument: **`-UITestFixtureSkipOverride`**

When present:

- `RootView` routes to a **minimal player** (same shell as `-UITestFixtureAudio`) with bundled **10.0 s** local audio (sine or speech); **no** network, RSS, ASR, or Core Data.
- Playback schedule is **stubbed**: one unrelated-content `.skip` interval **`[2.0, 5.0]`** (`source: .unrelatedContent`).
- **Auto-play** on fixture ready so the skip event occurs ~**2 s** after launch without extra taps.
- Hosts `skipOverrideBanner` overlay above transport controls.
- UI test **parallelization off** (Slice 03 / 13 precedent).

**Typical argument set:**

| Test | Launch arguments |
|------|------------------|
| AC#4 override banner | `-UITestFixtureSkipOverride` only |

Do **not** combine with `-UITestFixtureSettings` or `-UITestFixtureFeed` for mapped AC#4 tests. Routing precedence: SkipOverride when its flag is set (mirror `FixtureSettings` / `FixtureAudio` pattern — e.g. `FixtureSkipOverride.isEnabled`).

### Settings fixture (reuse Slice 13)

Launch argument: **`-UITestFixtureSettings`**

Used for AC#5 global-default assert on `unrelatedContentToggle`. Fresh `UserDefaults` → `accessibilityValue == "0"`.

### Feed fixture (reuse Slice 06)

Launch argument: **`-UITestFixtureFeed`**

Used for AC#5 channel-default assert on `channelUnrelatedContentToggle` on `PodcastDetailView`. Wait for `episodeList` (10 s); toggle is in header without scrolling.

## UI test scenarios

Mapped tests live in `SkipOverrideUITests.swift`. Scenarios below are the authoritative UX contract for slice AC#4–#5; AC#1–#3 are unit-tested in `SegmentationIntegrationTests` (no UI coverage).

### `testOverrideBannerAppearsAndReplay` (AC#4)

1. **Launch** — `XCUIApplication` with `-UITestFixtureSkipOverride`; wait for `playback.playPause` (timeout **10 s**). Do **not** tap play (fixture auto-plays).
2. **Banner appears** — within **5.0 s** of launch, assert `skipOverrideBanner` exists; assert `accessibilityValue` contains **`"3"`** (±**1** s rounding tolerance: accept `"2"`, `"3"`, or `"4"`).
3. **Tap override** — tap `skipOverrideBanner` once.
4. **Replay position** — within **3.0 s**, read `playback.elapsed` `accessibilityValue` as `Int` → assert **≥ 2** and **≤ 5** (inside stubbed segment `[2.0, 5.0]`).
5. **Playing** — assert `playback.playPause` `accessibilityValue == "playing"`.

### `testUnrelatedContentGlobalDefaultOff` (AC#5 — settings)

1. **Launch** — `XCUIApplication` with `-UITestFixtureSettings`; wait for `settingsRoot` (timeout **10 s**).
2. **Assert default off** — assert `unrelatedContentToggle` exists; assert `accessibilityValue == "0"`.

### `testChannelToggleDefaultOff` (AC#5 — podcast detail)

1. **Launch** — `XCUIApplication` with `-UITestFixtureFeed`; wait for `episodeList` (timeout **10 s**).
2. **Assert default off** — assert `channelUnrelatedContentToggle` exists; assert `accessibilityValue == "0"`.

### UX smoke scenarios (not slice ACs; optional QA coverage)

#### `testUnrelatedContentActionControlCycles` (optional)

1. Launch with `-UITestFixtureSettings`; wait for `settingsRoot`.
2. Tap `unrelatedContentToggle` on → assert `accessibilityValue == "1"`.
3. Assert `unrelatedContentActionControl` `accessibilityValue == "skip"` (fresh default).
4. Tap once → `"mute"`; tap once → `"skip"`.

#### `testChannelUnrelatedRequiresGlobalOn` (optional)

1. Launch with `-UITestFixtureFeed`; wait for `episodeList`.
2. Tap `channelUnrelatedContentToggle` on → `accessibilityValue == "1"`.
3. (No banner / skip behavior assert without playback + analysis — documents that channel-only on does not satisfy effective enable without global toggle; unit tests own scheduler filtering.)

#### `testBannerDismissesAfterSegmentEnd` (optional)

1. Launch with `-UITestFixtureSkipOverride`; wait for banner.
2. Do **not** tap banner; wait until `playback.elapsed` `accessibilityValue` as `Int` **> 5**.
3. Assert `skipOverrideBanner` does **not** exist within **2 s**.

## Verification mapping

| AC# | UX artifact | Test method | Notes |
|-----|-------------|-------------|-------|
| 4 | `testOverrideBannerAppearsAndReplay` scenarios 1–5 | `SkipOverrideUITests.testOverrideBannerAppearsAndReplay` | `-UITestFixtureSkipOverride`; stub `[2.0, 5.0]` |
| 5 (settings) | `testUnrelatedContentGlobalDefaultOff` scenarios 1–2 | `SkipOverrideUITests.testUnrelatedContentGlobalDefaultOff` | `-UITestFixtureSettings`; global default off |
| 5 (channel) | `testChannelToggleDefaultOff` scenarios 1–2 | `SkipOverrideUITests.testChannelToggleDefaultOff` | `-UITestFixtureFeed`; channel default off |
| 5 (store unit) | — | `SegmentationIntegrationTests.testUnrelatedContentDefaultsOff` | Isolated `UserDefaults`; no UI |
| 1–3 | — | `SegmentationIntegrationTests` | Pipeline / engine; no UI |
| 6 | — | `scripts/verify.sh` | Command-level; not UX-authored |
