# ADR-019 — Brand theme: tokens, display name, App Icon linkage

| Field | Value |
|-------|-------|
| **Status** | Accepted |
| **Date** | 2026-07-11 |
| **Supersedes** | — (does **not** replace timeline colors in [ADR-018](018-analysis-timeline.md); brand tokens are chrome-only) |
| **Builds on** | [ADR-000](000-foundations.md) §6 (verify.sh); [ADR-001](001-playback-engine.md) (`PlaybackControlsView`, `-UITestFixtureAudio`); [ADR-004](004-rss-parser.md) (`EpisodeListView`); [ADR-010](010-settings-word-lists.md) (`settingsButton`); [ADR-015](015-app-shell-navigation.md) (`RootView` → `AppShellView`, production chrome) |
| **Slice** | [slice-21-visual-identity.md](../slices/slice-21-visual-identity.md) |

## Context

Slice 21 pins a minimal, **assertable** brand system (display name, App Icon,
semantic color tokens) and wires it into existing player / list / settings-entry
chrome. Product decisions (2026-07-10) are closed:

| Pin | Value |
|-----|-------|
| Display name | **`PodWash`** (exact, case-sensitive) |
| Theme mode | **Dark only** — `.preferredColorScheme(.dark)` at root; no light palette; no settings toggle |
| Palette v1 | primary `#2A9D8F`, accent `#E9C46A`, surface `#0F1419`, onPrimary `#FFFFFF`, onSurface `#E8EAED` (sRGB in Decision §2) |
| App Icon | Option A — soap bubble + headphones → `AppIcon.appiconset` |

Acceptance is structural (sRGB ± **0.001**, bundle string, catalog files) plus
UITest accessibility contracts — **no** snapshot / pixel-diff, **no** subjective
visual review.

**Numbering note:** Slice 21 drafts said `011-brand-theme.md`; **011** is already
remote commands ([ADR-011](011-remote-commands-background-audio.md)). This decision
is **ADR-019**.

## Empirical validation

**No framework spike required.** Token components, `CFBundleDisplayName`,
`AccentColor` catalog resolution, and App Icon file presence are pure structural
asserts (unit / disk). UITests assert accessibility identifiers and values only
(same XCTest pattern as Slices 03 / 13 / 23). No AVFoundation, ASR, StoreKit, or
networking claims.

## Decision

### 1. Module layout / file boundaries

| File | Target | Status | Responsibility |
|------|--------|--------|----------------|
| `PodWash/PodWash/BrandTheme.swift` | app | **new** | Single source of truth: semantic `Color`s, sRGB `Double` components for tests, `approvedDisplayName` |
| `PodWash/PodWash/FixtureBranding.swift` | app | **new** | `-UITestFixtureBranding` detection + fixture chrome host wiring helpers |
| `PodWash/PodWash/BrandingChromeView.swift` | app | **new** | Deterministic branding fixture surface (wordmark + surface + player + settings entry) |
| `PodWash/PodWash/Assets.xcassets/AccentColor.colorset` | app | **changed** | sRGB components **identical** to `BrandTheme.primary` (± 0.001) |
| `PodWash/PodWash/Assets.xcassets/AppIcon.appiconset` | app | **changed** | Commit Option A **1024×1024** PNG; `Contents.json` lists **`ios-marketing`** entry |
| `PodWash/PodWash/Info.plist` and/or `INFOPLIST_KEY_CFBundleDisplayName` | app | **changed** | `CFBundleDisplayName` = **`PodWash`** |
| `PodWash/PodWash/PodWashApp.swift` | app | **changed** | Apply `.preferredColorScheme(.dark)` on root `RootView` |
| `PodWash/PodWash/RootView.swift` | app | **changed** | Exclusive branding fixture branch → `BrandingChromeView` |
| `PodWash/PodWash/AppShellView.swift` | app | **changed (minimal)** | Surface token on shell chrome; host `brandWordmark` (nav title or dedicated text) |
| `PodWash/PodWash/PlaybackControlsView.swift` | app | **changed (minimal)** | Primary control tint via `BrandTheme.primary`; brand accent sentinel (see §4) |
| `PodWash/PodWash/EpisodeListView.swift` | app | **changed (minimal)** | List / chrome background binds `BrandTheme.surface` (or inherits from parent) |
| `PodWash/PodWash/LibraryView.swift` / `MiniPlayerBar.swift` | app | **changed (optional, minimal)** | Prefer surface / primary tokens when touching chrome; no feature work |
| `PodWash/PodWashTests/BrandThemeTests.swift` | test | **new (QA)** | AC1–AC4 |
| `PodWash/PodWashUITests/BrandingUITests.swift` | test | **new (QA)** | AC5–AC8 |

**Unchanged public APIs:** `PlaybackEngine`, matching / ASR / pipeline, Core Data,
queue/resume, Discover/Library navigation graph (ADR-015), analysis timeline
segment colors (ADR-018 — **do not** reuse brand tokens for blue/green/yellow/grey).

**Optional:** `BrandWordmark.imageset` — only if UX + user approve an image wordmark;
MVP Done uses **text** wordmark (`brandWordmark` → `Text(BrandTheme.approvedDisplayName)`).

### 2. `BrandTheme` public API

```swift
import SwiftUI

/// Semantic brand tokens — dark appearance only (Slice 21 / ADR-019).
enum BrandTheme {
    /// Home-screen + in-app wordmark label; must equal `CFBundleDisplayName`.
    static let approvedDisplayName: String = "PodWash"

    // MARK: sRGB components (0…1) — test contract AC1 (± 0.001)

    static let primaryRed: Double = 0.165
    static let primaryGreen: Double = 0.616
    static let primaryBlue: Double = 0.561

    static let accentRed: Double = 0.914
    static let accentGreen: Double = 0.769
    static let accentBlue: Double = 0.416

    static let surfaceRed: Double = 0.059
    static let surfaceGreen: Double = 0.078
    static let surfaceBlue: Double = 0.098

    static let onPrimaryRed: Double = 1.0
    static let onPrimaryGreen: Double = 1.0
    static let onPrimaryBlue: Double = 1.0

    static let onSurfaceRed: Double = 0.910
    static let onSurfaceGreen: Double = 0.918
    static let onSurfaceBlue: Double = 0.929

    // MARK: SwiftUI colors (built from the components above)

    static var primary: Color { Color(.sRGB, red: primaryRed, green: primaryGreen, blue: primaryBlue, opacity: 1) }
    static var accent: Color { Color(.sRGB, red: accentRed, green: accentGreen, blue: accentBlue, opacity: 1) }
    static var surface: Color { Color(.sRGB, red: surfaceRed, green: surfaceGreen, blue: surfaceBlue, opacity: 1) }
    static var onPrimary: Color { Color(.sRGB, red: onPrimaryRed, green: onPrimaryGreen, blue: onPrimaryBlue, opacity: 1) }
    static var onSurface: Color { Color(.sRGB, red: onSurfaceRed, green: onSurfaceGreen, blue: onSurfaceBlue, opacity: 1) }
}
```

**Rules:**

- Components are the **canonical** values; `Color` wrappers must not diverge.
- No light-mode variants; no `Color("…")` asset indirection for semantic tokens
  except `AccentColor` mirroring `primary` (catalog ↔ token AC2).
- Typography: **system Dynamic Type text styles only** — no custom font files.

### 3. Asset catalog + display name linkage

| Asset / key | Contract |
|-------------|----------|
| `AccentColor.colorset` | Universal sRGB components = `BrandTheme.primary*` (± **0.001**). Tests resolve via `UIColor(named: "AccentColor", in: Bundle.main, compatibleWith: nil)` in the app test host. |
| `AppIcon.appiconset` | At minimum one **`ios-marketing`** entry, size **1024×1024**, with a committed PNG **filename** whose on-disk size is **> 1024** bytes (AC4). Prefer also filling modern universal 1024 slots so Xcode catalog validation stays green. |
| Icon art | Option A (soap bubble + headphones). Source draft path in the slice: `assets/podwash-logo-option-a-bubble-headphones.png`. If that draft is absent at implement time, Engineer commits a **1024×1024** PNG matching Option A into the appiconset (no halt — concept is product-approved). |
| `CFBundleDisplayName` | Exact string **`PodWash`**. Prefer `INFOPLIST_KEY_CFBundleDisplayName = PodWash` in the app target **and/or** an explicit `Info.plist` key so `Bundle.main.object(forInfoDictionaryKey: "CFBundleDisplayName")` is non-nil and equals the pin. Do **not** rename the Xcode target / bundle id. |

### 4. Accessibility / chrome contracts (QA + UX binding)

Existing Slice 03 play/pause contracts **must not break**:

| Control | Keep unchanged |
|---------|----------------|
| Play/pause | `accessibilityIdentifier` **`playback.playPause`** |
| Play/pause value | **`playing`** / **`paused`** |

Brand proof therefore uses **dedicated sentinels** (not replacing play/pause id/value):

| Element | `accessibilityIdentifier` | Contract |
|---------|---------------------------|----------|
| Wordmark | `brandWordmark` | `accessibilityLabel` == **`PodWash`** (exact) |
| Primary accent proof | `themePrimaryAccent` | Exists on chrome that tints the primary CTA; `accessibilityValue` == **`brandPrimary`** |
| Surface proof | `themePrimarySurface` | `accessibilityValue` == **`1`** when surface token applied |
| Settings | `settingsButton` | Exists and hittable (Slice 13 / 23) |

**AC6 mapping:** assert element `themePrimaryAccent` (value `brandPrimary`) — **not**
reassigning `playback.playPause`’s identifier. Place the sentinel on the tinted
play control’s container / sibling so it proves `BrandTheme.primary` binding.
UX (`slice-21-ux.md`) may refine placement; this ADR pins the identifiers/values.

**Production chrome (minimal pass):**

- `PodWashApp`: `.preferredColorScheme(.dark)` on the root view.
- `AppShellView` / Library nav: `brandWordmark` (text) + surface background.
- `PlaybackControlsView`: `.foregroundStyle(BrandTheme.primary)` (or equivalent)
  on the play/pause control; attach `themePrimaryAccent` sentinel.
- `EpisodeListView` / settings push: inherit or set `BrandTheme.surface`;
  `settingsButton` remains reachable on the shell.

### 5. Fixture mode — `-UITestFixtureBranding`

```swift
enum FixtureBranding {
    static let launchArgument = "-UITestFixtureBranding"

    static var isEnabled: Bool {
        ProcessInfo.processInfo.arguments.contains(launchArgument)
            || ProcessInfo.processInfo.arguments.contains {
                $0.hasSuffix("UITestFixtureBranding")
            }
    }
}
```

**Routing:** exclusive `RootView` branch (same pattern as Audio / Settings). Suggested
precedence insertion — after Settings, before or alongside Audio is fine; must
**not** require network or Library seed:

```text
SkipOverride > Settings > Branding > Audio > Feed|Analysis|Queue > Discover > AppShell
```

**`BrandingChromeView` (fixture-only):**

1. Background = `BrandTheme.surface` + `themePrimarySurface` sentinel (`"1"`).
2. `brandWordmark` = `Text(BrandTheme.approvedDisplayName)` with label **`PodWash`**.
3. Host `PlaybackControlsView` with `FixtureAudio` bundled clip (engine created in
   `RootView` / fixture helper — no RSS).
4. Host hittable `settingsButton` → `SettingsView` (in-memory or production
   `SettingsStore` — AC only requires hittable entry).
5. Parallelization remains **off** for `PodWashUITests` (Slice 03 scheme precedent).

UITests launch with **only** `-UITestFixtureBranding` (plus any global args the
harness already uses). Episode list may show **0** rows — chrome-only asserts.

### 6. Views that may import `BrandTheme`

| May import | Must not import |
|------------|-----------------|
| `PodWashApp`, `RootView`, `BrandingChromeView`, `AppShellView`, `LibraryView`, `MiniPlayerBar`, `PlaybackControlsView`, `EpisodeListView`, `PodcastDetailView`, `SettingsView`, Discover chrome if lightly tinted | `PlaybackEngine`, `WordMatcher`, `AnalysisPipeline`, `AnalysisTimelineModel` / timeline segment colors, download / queue / ASR modules, CarPlay templates (Slice 15 may later tint templates separately) |

Token application outside the Slice 21 chrome list is **out of scope** (no full
redesign).

### 7. Cross-cutting impact

| Area | Impact |
|------|--------|
| `RootView` / `PodWashApp` | Branding fixture branch + dark scheme — serialize with parallel slices editing the same files |
| `PlaybackControlsView` | Tint + sentinel only; transport identifiers unchanged |
| `AppShellView` / list chrome | Wordmark + surface; Settings overlay unchanged |
| ADR-018 timeline colors | **Independent** — do not substitute brand primary/accent for segment blue/green/yellow/grey |
| Bundle / catalog | Display name + AccentColor + App Icon — testable without UI |

### 8. Out of scope (this ADR)

- Marketing site, brand PDF, App Store screenshots
- StoreKit paywall art (Slice 17)
- Custom fonts, animated splash, haptics, sound branding
- Snapshot / pixel-diff testing
- Renaming target / bundle identifier
- Light mode or appearance toggle

## Consequences

- QA maps AC1–AC4 to `BrandThemeTests` and AC5–AC8 to `BrandingUITests` against
  the API and accessibility contracts above.
- Engineer must not invent alternate token names or replace `playback.playPause`
  identifiers to satisfy AC6.
- UX authors `docs/slices/slice-21-ux.md` for layout of wordmark / sentinels /
  fixture chrome; identifiers in this ADR are binding unless a superseding ADR
  changes them.
- Option A icon art is a committed binary in `AppIcon.appiconset`; missing draft
  path does not block Done if the marketing PNG meets AC4 and the Option A concept.
