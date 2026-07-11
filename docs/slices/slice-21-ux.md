# Slice 21 — UX spec: Visual identity & branding

| Field | Value |
|-------|-------|
| **Slice** | 21 — Visual identity & branding |
| **Screens** | `BrandingChromeView` (fixture root); production chrome: `AppShellView`, `PlaybackControlsView`, `EpisodeListView`, `SettingsView` |
| **ADR** | [ADR-019](../adr/019-brand-theme.md) (token API, sentinel identifiers, fixture routing) |
| **Builds on** | [slice-03-ux.md](slice-03-ux.md) (`playback.playPause` transport contract), [slice-06-ux.md](slice-06-ux.md) (episode list), [slice-13-settings-ux.md](slice-13-settings-ux.md) (`settingsButton`), [slice-23-ux.md](slice-23-ux.md) (`AppShellView` shell) |
| **Slice story** | [slice-21-visual-identity.md](slice-21-visual-identity.md) |

## Scope note

**Chrome-only brand pass.** This slice wires semantic color tokens, display name, and App Icon assets into existing player / list / settings-entry surfaces. It does **not** redesign analysis timeline segment colors (Slice 20 / ADR-018), Discover, queue, downloads, or CarPlay.

**Dark theme only.** Root view forces `.preferredColorScheme(.dark)`. No light palette, no appearance toggle in Settings.

**Text wordmark (MVP).** In-app branding uses `Text(BrandTheme.approvedDisplayName)` — **not** a `BrandWordmark` image asset. `BrandWordmark.imageset` is optional and out of Done scope unless user approves later.

**No subjective visual review.** Done is proven by structural unit tests (sRGB, bundle name, App Icon file) and accessibility sentinels — not pixel/snapshot diff.

## Brand tokens (visual roles)

Engineer applies tokens from `BrandTheme`; UX pins **where** each token appears. Hex/sRGB values are pinned in the slice story and ADR-019 §2.

| Token | Visual role (this slice) |
|-------|--------------------------|
| `primary` (`#2A9D8F`) | Play/Pause control icon tint in `PlaybackControlsView`; mirrors `AccentColor` asset |
| `accent` (`#E9C46A`) | Reserved for secondary highlights — **not** AC-mapped in UI tests this slice |
| `surface` (`#0F1419`) | Screen / shell background (`BrandingChromeView`, `AppShellView`, list chrome) |
| `onPrimary` (`#FFFFFF`) | Icon on primary-filled controls (if any filled primary buttons are added later) |
| `onSurface` (`#E8EAED`) | Primary body text on dark surfaces (wordmark, labels) |
| `approvedDisplayName` | Exact string **`PodWash`** — wordmark label and `CFBundleDisplayName` |

**Typography:** system Dynamic Type text styles only (`.headline`, `.title2`, `.body`, etc.). No custom font files.

## Layout

### Fixture screen — `BrandingChromeView` (`-UITestFixtureBranding`)

Exclusive `RootView` branch. No `TabView`, no RSS/network, no episode rows required (0 rows is valid). Bundled `test-clip.m4a` + `PlaybackEngine` same as Slice 03 audio fixture.

Vertical structure, top → bottom:

```text
┌─────────────────────────────────────┐
│  [settingsButton]          (trailing overlay, 44×44)
│         brandWordmark               │  ← centered headline text "PodWash"
│                                     │
│      PlaybackControlsView           │  ← Slice 03 transport row
│   (elapsed, play/pause, seeks)      │
│                                     │
│  (surface background full bleed)    │
└─────────────────────────────────────┘
```

1. **Background** — full-bleed `BrandTheme.surface`. Hosts hidden surface sentinel (see Accessibility).
2. **Wordmark** — centered `Text(BrandTheme.approvedDisplayName)` below safe-area top, above transport. Font: `.headline` (or `.title3`); foreground `BrandTheme.onSurface`.
3. **Transport** — existing `PlaybackControlsView` centered in remaining space (Slice 03 layout unchanged).
4. **Settings entry** — trailing overlay `settingsButton` (same hittability pattern as `AppShellView`: plain `Button` + gear icon, 44×44 `contentShape`, not `ToolbarItem`). Tap pushes or presents `SettingsView` (in-memory `SettingsStore` acceptable; AC only requires hittable entry).

**Z-order (bottom → top):** surface background + `themePrimarySurface` sentinel → `PlaybackControlsView` → wordmark → settings overlay.

### Production chrome (minimal pass — not slice-AC-mapped except regression on `settingsButton` from other slices)

Changes are **token binding only** — no navigation graph changes.

| Surface | Token application |
|---------|-------------------|
| `PodWashApp` → `RootView` | `.preferredColorScheme(.dark)` on root |
| `AppShellView` | Background `BrandTheme.surface`; outer container hosts `themePrimarySurface` sentinel (`"1"`) in production as well as fixture |
| `AppShellView` Library tab | `brandWordmark` as **inline navigation title** text showing **`PodWash`** (replaces the literal `"Library"` string in `.navigationTitle` for the Library `NavigationStack` only). Tab bar item label remains **Library** for wayfinding (`tabLibrary` unchanged) |
| `AppShellView` Discover tab | No wordmark; inherits surface background only |
| `PlaybackControlsView` | Play/Pause icon `.foregroundStyle(BrandTheme.primary)`; `themePrimaryAccent` sentinel on play control wrapper (see Accessibility) |
| `EpisodeListView` / `PodcastDetailView` | List / detail background inherits `BrandTheme.surface` from parent or sets `.background(BrandTheme.surface)` on list chrome |
| `SettingsView` | Inherits surface from navigation stack; no new controls |

**Out of scope:** recoloring timeline segments, mini-player bar full redesign, Discover search chrome, paywall art, animated splash, haptics.

## States

### Theme mode

| State | User-visible behavior | Settings |
|-------|----------------------|----------|
| **Dark (only)** | All screens render dark palette tokens | No appearance toggle; none added in Settings |

No loading / empty / error states are introduced by branding. Fixture bootstrap may show `playback.loading` briefly (Slice 03 pattern) — UI tests wait on brand elements, not loading.

### Play/Pause (unchanged from Slice 03)

| State | `playback.playPause` `accessibilityValue` | Icon tint |
|-------|-------------------------------------------|-----------|
| **Paused** | `paused` | `BrandTheme.primary` |
| **Playing** | `playing` | `BrandTheme.primary` |

Transport identifiers and values **must not** change. Brand proof uses separate sentinels (below).

### Settings entry

| Context | `settingsButton` | Notes |
|---------|------------------|-------|
| **Branding fixture** | Visible, hittable on launch | AC#8 |
| **Production shell** | Unchanged Slice 23 behavior | Regression guarded by existing `LibraryUITests` |

## Accessibility identifiers

### Binding decisions (AC#6)

**Chosen contract:** dedicated element `themePrimaryAccent` with `accessibilityValue == "brandPrimary"`.

`playback.playPause` keeps identifier **`playback.playPause`** and values **`playing`** / **`paused`** only. Do **not** assign `themePrimaryAccent` to the play button itself.

### Brand sentinels

| Element | `accessibilityIdentifier` | `accessibilityLabel` | `accessibilityValue` | `accessibilityHint` | Placement |
|---------|---------------------------|----------------------|----------------------|---------------------|-----------|
| Wordmark | `brandWordmark` | **`PodWash`** (exact, case-sensitive) | — | — | Visible `Text` in fixture + Library nav title host in production |
| Primary accent proof | `themePrimaryAccent` | `Brand primary accent` | **`brandPrimary`** | — | Hidden or zero-size sibling/wrapper on the play/pause control **after** `BrandTheme.primary` tint is applied; must exist whenever `playback.playPause` is visible in branded contexts |
| Surface proof | `themePrimarySurface` | `Brand surface` | **`1`** when `BrandTheme.surface` is applied; **`0`** or absent when not applied | — | Root chrome container (`BrandingChromeView` background; `AppShellView` outer `Group`/`ZStack`) |
| Settings entry | `settingsButton` | `Settings` | — | `Opens cleaning and playback defaults.` | Trailing overlay (fixture + production shell) |

**Sentinel visibility:** `themePrimaryAccent` and `themePrimarySurface` may use `.accessibilityElement(children: .ignore)` on a 1×1 pt or `Color.clear` host so VoiceOver exposes the contract without duplicating play/pause semantics. They must remain queryable via `app.descendants(matching: .any)["themePrimaryAccent"]`.

### Unchanged transport (Slice 03)

| Control | `accessibilityIdentifier` | `accessibilityValue` |
|---------|---------------------------|----------------------|
| Play/Pause | `playback.playPause` | `playing` / `paused` |
| Seek back 15 s | `playback.seekBack15` | — |
| Seek forward 15 s | `playback.seekForward15` | — |
| Elapsed time | `playback.elapsed` | whole seconds as decimal string |

### Production-only (unchanged — no new ACs)

`tabLibrary`, `tabDiscover`, `libraryRoot`, `episodeList`, `settingsRoot`, etc. retain Slice 06 / 13 / 23 contracts.

## Fixture mode

Launch argument: **`-UITestFixtureBranding`**

Detection: `FixtureBranding.isEnabled` — `ProcessInfo.processInfo.arguments` contains `-UITestFixtureBranding` or suffix `UITestFixtureBranding` (same pattern as `FixtureFeed` / `FixtureSettings`).

### Routing precedence (`RootView`)

Insert branding branch per ADR-019 §5:

```text
SkipOverride > Settings > Branding > Audio > Feed|Analysis|Timeline|Queue > Discover > AppShell
```

When `-UITestFixtureBranding` is set, `RootView` shows `BrandingChromeView` only. No Core Data seed, no network, no tab bar.

### Bootstrap

- Create `PlaybackEngine` with bundled `test-clip.m4a` (reuse `FixtureAudio` loader / `RootView` helper).
- Optional in-memory `SettingsStore` for settings navigation from `settingsButton`.
- Episode list: **not required**; 0 rows is valid for chrome-only asserts.

### Launch argument matrix

| Test file | Launch arguments | Combine with other fixtures? |
|-----------|------------------|------------------------------|
| `BrandingUITests` (AC#5–#8) | `-UITestFixtureBranding` only | **No** — exclusive fixture |
| Existing suites (`PlaybackControlsUITests`, `LibraryUITests`, etc.) | Their existing args | Unaffected; branding branch not taken |

**Parallelization:** `PodWashUITests` parallelization remains **off** (Slice 03 precedent).

**Typical harness:** `app.launchArguments = ["-UITestFixtureBranding"]` plus any global args the shared test base already appends.

## UI test scenarios

Mapped tests live in `BrandingUITests.swift`. Timeout default: **10 s** for first meaningful element unless noted.

Query pattern: `app.descendants(matching: .any)["<identifier>"]` for sentinels and wordmark (consistent with Slice 20 / 23).

### 1. `testBrandWordmarkLabelMatchesDisplayName` (AC#5)

1. **Launch** — `XCUIApplication` with `-UITestFixtureBranding` only.
2. **Wait** — `brandWordmark` exists (timeout **10 s**).
3. **Assert label** — `brandWordmark` `label` equals **`PodWash`** (exact `String` match, case-sensitive).

### 2. `testPrimaryPlayControlUsesBrandAccent` (AC#6)

1. **Launch** — `-UITestFixtureBranding` only.
2. **Wait** — `playback.playPause` exists (timeout **10 s**).
3. **Assert sentinel** — `themePrimaryAccent` exists.
4. **Assert value** — `themePrimaryAccent` `value` equals **`brandPrimary`** (exact match).
5. **Assert transport unchanged** — `playback.playPause` exists; `value` is `paused` or `playing` (not `brandPrimary`).

### 3. `testRootChromeSurfaceTokenApplied` (AC#7)

1. **Launch** — `-UITestFixtureBranding` only.
2. **Wait** — `themePrimarySurface` exists (timeout **10 s**).
3. **Assert value** — `themePrimarySurface` `value` equals **`1`** (exact match).

### 4. `testSettingsEntryReachable` (AC#8)

1. **Launch** — `-UITestFixtureBranding` only.
2. **Wait** — `settingsButton` exists (timeout **10 s**).
3. **Assert hittable** — `settingsButton.isHittable == true` (use `XCTAssertTrue` + optional `waitForExistence` on hittable poll, same pattern as `LibraryUITests.testSettingsButtonHittableFromLibrary`).

### UX smoke scenarios (not slice ACs; optional QA coverage)

#### `testPlayPauseStillWorksInBrandingFixture` (optional)

1. Launch `-UITestFixtureBranding`; wait for `playback.playPause`.
2. Tap `playback.playPause`; assert `value == "playing"`.
3. Tap again; assert `value == "paused"`.

Confirms brand tint/sentinels did not break Slice 03 transport behavior.

#### `testSettingsOpensFromBrandingFixture` (optional)

1. Launch `-UITestFixtureBranding`; wait for `settingsButton`.
2. Tap `settingsButton`; within **5 s**, assert `settingsRoot` exists.

## Verification mapping

| AC# | UX scenario | Test method |
|-----|-------------|-------------|
| 5 | Scenario 1 | `testBrandWordmarkLabelMatchesDisplayName` |
| 6 | Scenario 2 | `testPrimaryPlayControlUsesBrandAccent` |
| 7 | Scenario 3 | `testRootChromeSurfaceTokenApplied` |
| 8 | Scenario 4 | `testSettingsEntryReachable` |

AC#1–#4 are unit-tested in `BrandThemeTests.swift` (no UI coverage). AC#9 is full-suite `scripts/verify.sh`.

## Engineer checklist (implementation hints)

- [ ] `BrandTheme.swift` — components + `Color` wrappers per ADR-019 §2
- [ ] `FixtureBranding.swift` + `BrandingChromeView.swift` — fixture layout above
- [ ] `RootView` — branding branch at correct precedence; loader for fixture engine
- [ ] `PlaybackControlsView` — `.foregroundStyle(BrandTheme.primary)` on play/pause icon; `themePrimaryAccent` wrapper sentinel
- [ ] `AppShellView` — surface background, `themePrimarySurface`, Library `brandWordmark`, `settingsButton` unchanged
- [ ] `PodWashApp` — `.preferredColorScheme(.dark)`
- [ ] Do **not** alter `playback.playPause` identifier or map `brandPrimary` to play state
- [ ] Do **not** recolor analysis timeline segments with brand tokens
