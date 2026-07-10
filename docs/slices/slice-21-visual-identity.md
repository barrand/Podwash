# Slice 21 — Visual identity & branding

| Field | Value |
|-------|-------|
| **ID** | 21 |
| **Title** | Visual identity & branding |
| **Status** | Ready |
| **Crux** | Brand tokens, display name, and App Icon assets are pinned to user-approved values and assertable in unit/structural tests; existing primary screens (player shell, episode list, settings entry) consume those tokens so chrome is branded without subjective visual review. |

## PRD / spec references

- PRD §1 — Design principle: feel like a normal, polished podcast app first; faith/family-friendly audience
- PRD §1 — Target audience framing (brand must not undermine “normal podcast app” credibility)
- `docs/adr/000-foundations.md` — iOS floor; no new verification mechanics
- Slice 03 — Player shell chrome (`PlaybackControlsView`, fixture launch args)
- Slice 06 — Episode list chrome (`EpisodeListView`, `-UITestFixtureFeed`)
- Slice 13 — Settings entry from `ContentView` (`settingsButton`)

## Product decisions (user, 2026-07-10 — unblocks this slice)

| Decision | Choice |
|----------|--------|
| **App display name** | **PodWash** — `CFBundleDisplayName` and `BrandTheme.approvedDisplayName` = **`"PodWash"`** (exact, case-sensitive) |
| **Brand color palette** | **Approved (v1):** primary `#2A9D8F` (r **0.165**, g **0.616**, b **0.561**); accent `#E9C46A` (r **0.914**, g **0.769**, b **0.416**); surface `#0F1419` (r **0.059**, g **0.078**, b **0.098**); on-primary `#FFFFFF` (r **1.0**, g **1.0**, b **1.0**); on-surface `#E8EAED` (r **0.910**, g **0.918**, b **0.929**) |
| **Logo / App Icon** | **Option A — soap bubble + headphones**; source draft: `assets/podwash-logo-option-a-bubble-headphones.png` → committed into `AppIcon.appiconset` (1024 marketing + required idioms) |
| **Theme mode** | **Dark theme only** — `preferredColorScheme(.dark)` at root; no light mode; no appearance toggle in settings |

## Product decisions (halt-and-ask — resolved)

| Decision | Status | Notes |
|----------|--------|-------|
| **App display name** | ✅ **Resolved 2026-07-10** | **PodWash** |
| **Brand color palette** | ✅ **Resolved 2026-07-10** | Dark palette v1 pinned in **Brand token contract** below |
| **Logo / App Icon concept** | ✅ **Resolved 2026-07-10** | Option A (soap bubble + headphones) |
| **Theme mode at MVP** | ✅ **Resolved 2026-07-10** | Dark theme only |

## Goal

Establish a minimal, testable brand system (display name, App Icon, semantic color tokens) and apply it to the existing player, episode list, and settings-entry chrome so PodWash feels intentional and family-friendly while remaining a credible podcast app.

## Deliverables

- `PodWash/PodWash/BrandTheme.swift` (or `PodWashTheme.swift`) — single source of truth for semantic tokens:
  - At minimum: `primary`, `accent`, `surface`, `onPrimary`, `onSurface` as `Color` + exposed sRGB `Double` components for tests (e.g. `BrandTheme.primaryRed`)
  - **Dark-only:** root view forces `.preferredColorScheme(.dark)`; tokens pin dark appearance (no light palette, no theme toggle)
  - Typography: reuse system Dynamic Type styles only (no custom font files in this slice)
  - `BrandTheme.approvedDisplayName: String` — matches resolved `CFBundleDisplayName`
- Asset catalog updates:
  - `Assets.xcassets/AppIcon.appiconset` — derive from approved Option A draft (`assets/podwash-logo-option-a-bubble-headphones.png`); complete required iPhone idioms **or** at minimum **1024×1024** `ios-marketing` PNG committed (per Apple catalog rules)
  - `Assets.xcassets/AccentColor.colorset` — sRGB components **identical** to `BrandTheme.primary` (± **0.001** per channel)
  - Optional `Assets.xcassets/BrandWordmark.imageset` — only if UX spec + user approve in-app wordmark (not required for Done if AC uses text wordmark)
- Build setting / `Info.plist`: `CFBundleDisplayName` = user-approved display name string
- Light UX pass (token wiring only — not feature work):
  - `ContentView` / `RootView` — navigation title or `brandWordmark` host uses display name
  - `PlaybackControlsView` — primary control (`playback.playPause`) binds branded accent via `themePrimaryAccent` accessibility contract
  - `EpisodeListView` — list chrome / nav bar uses `themePrimarySurface` token binding (background or bar tint per UX spec)
  - Settings entry (`settingsButton`) remains reachable; settings screen inherits surface token
- Launch argument **`-UITestFixtureBranding`** — lands on a deterministic chrome surface (player + list tab or combined fixture) without network/RSS; parallelization off per Slice 03 precedent
- `PodWash/PodWashTests/BrandThemeTests.swift` — token + bundle structural asserts
- `PodWash/PodWashUITests/BrandingUITests.swift` — chrome accessibility contract
- `docs/adr/011-brand-theme.md` — module boundary: `BrandTheme` public API, asset catalog linkage, which views may import tokens
- `docs/slices/slice-21-ux.md` — **UX agent authors** (PM links only; not written in this story pass)

## Brand token contract (pinned — user 2026-07-10)

| Token | Hex | sRGB (0.0–1.0) | Role |
|-------|-----|----------------|------|
| `primary` | `#2A9D8F` | r **0.165**, g **0.616**, b **0.561** | Main brand color; key CTAs; `AccentColor` asset |
| `accent` | `#E9C46A` | r **0.914**, g **0.769**, b **0.416** | Secondary highlight |
| `surface` | `#0F1419` | r **0.059**, g **0.078**, b **0.098** | Screen background / chrome |
| `onPrimary` | `#FFFFFF` | r **1.0**, g **1.0**, b **1.0** | Text/icon on primary-filled controls |
| `onSurface` | `#E8EAED` | r **0.910**, g **0.918**, b **0.929** | Primary body text on dark surface |
| `approvedDisplayName` | — | **`"PodWash"`** | Home screen + in-app wordmark label |

**Dark-only:** all tokens are single-appearance (no light palette). Root forces `.preferredColorScheme(.dark)`.

## Fixture strategy (pinned)

| Asset | Role |
|-------|------|
| `-UITestFixtureBranding` | Opens branded chrome without network; episode list may show **0** rows or a single stub row — UI tests assert chrome only |
| `BrandThemeTests` reads `Bundle.main` | Structural `CFBundleDisplayName` assert |
| AppIcon catalog on disk | File-existence / `Contents.json` idiom checks in test bundle or app test target |

## Depends on

- Slice 03 — Player shell exists (`PlaybackControlsView`, playback fixture args)
- Slice 06 — Episode list exists (`EpisodeListView`, `-UITestFixtureFeed` pattern)

**Parallelizable:** Yes — with Slices **14**, **15**, **16**, and **20** once Slice 03 + 06 are **Done** (no shared playback/lock-screen/CarPlay/timeline files required). Serialize with any slice that edits the same SwiftUI chrome files (`ContentView`, `RootView`, `PlaybackControlsView`, `EpisodeListView`).

## Out-of-scope

- Marketing website, brand guidelines PDF, or App Store screenshot production as Done gates
- StoreKit paywall art or subscription merchandising (Slice 17)
- Analysis timeline segment colors (Slice 20 — blue/green/yellow/grey contract stays separate)
- Subjective “fun”, “delight”, or visual polish reviews as completion criteria
- Custom font files that bypass Dynamic Type (system text styles only)
- Full redesign of every screen (analysis UI, queue, downloads, CarPlay templates)
- Renaming the Xcode target / bundle identifier (`com.*.PodWash`) — display name only unless user explicitly expands scope
- Animated splash, haptics, or sound-branding
- Snapshot / pixel-diff testing dependency

## Acceptance criteria

Automatable only. Thresholds use user-approved pinned values from **Product decisions** once resolved. **XCTSkip is not allowed on core ACs** — a mapped test that cannot run must fail.

- [ ] 1. Unit test (`BrandTheme`): `primary` sRGB **(0.165, 0.616, 0.561)**; `accent` **(0.914, 0.769, 0.416)**; `surface` **(0.059, 0.078, 0.098)**; `onPrimary` **(1.0, 1.0, 1.0)**; `onSurface` **(0.910, 0.918, 0.929)** — each channel ± **0.001**.
- [ ] 2. Unit test (`BrandTheme` + asset catalog): `AccentColor` resolved `UIColor` sRGB components match `BrandTheme.primary` ± **0.001** per channel (read catalog color in test bundle or via `UIColor(named:)` in app target test).
- [ ] 3. Structural test (`Bundle.main`): `CFBundleDisplayName` equals **`"PodWash"`** and `BrandTheme.approvedDisplayName == "PodWash"` (exact `String` match, case-sensitive).
- [ ] 4. Structural test (AppIcon): `AppIcon.appiconset/Contents.json` lists an **`ios-marketing`** entry with **1024×1024** PNG present on disk; file size **> 1024** bytes (guards empty placeholder).
- [ ] 5. UI test (`-UITestFixtureBranding`): element `brandWordmark` exists; `accessibilityLabel` equals **`"PodWash"`** (exact match).
- [ ] 6. UI test (`-UITestFixtureBranding`): `playback.playPause` has `accessibilityIdentifier` **`themePrimaryAccent`** OR exposes `accessibilityValue` **`"brandPrimary"`** (UX spec picks one; test asserts the chosen contract) — proves primary CTA uses brand token binding.
- [ ] 7. UI test (`-UITestFixtureBranding`): root chrome exposes `themePrimarySurface` with `accessibilityValue` **`"1"`** when surface token is applied (boolean sentinel — not a color pixel test).
- [ ] 8. UI test (`-UITestFixtureBranding`): `settingsButton` exists and remains hittable (settings entry not regressed by chrome pass).
- [ ] 9. Full suite green via `scripts/verify.sh` (**exit 0, failed 0, skipped 0**).

## Verification mapping

| AC# | Test file | Test method | Notes |
|-----|-----------|-------------|-------|
| 1 | `PodWash/PodWashTests/BrandThemeTests.swift` | `testSemanticTokensMatchApprovedSRGB` | Five tokens; pinned sRGB ±0.001 |
| 2 | `PodWash/PodWashTests/BrandThemeTests.swift` | `testAccentColorAssetMatchesPrimary` | Catalog ↔ `BrandTheme.primary` |
| 3 | `PodWash/PodWashTests/BrandThemeTests.swift` | `testBundleDisplayNameMatchesApproved` | `CFBundleDisplayName` |
| 4 | `PodWash/PodWashTests/BrandThemeTests.swift` | `testAppIconMarketingAssetPresent` | 1024 PNG + json idiom |
| 5 | `PodWash/PodWashUITests/BrandingUITests.swift` | `testBrandWordmarkLabelMatchesDisplayName` | `brandWordmark` a11y |
| 6 | `PodWash/PodWashUITests/BrandingUITests.swift` | `testPrimaryPlayControlUsesBrandAccent` | `themePrimaryAccent` contract |
| 7 | `PodWash/PodWashUITests/BrandingUITests.swift` | `testRootChromeSurfaceTokenApplied` | `themePrimarySurface` sentinel |
| 8 | `PodWash/PodWashUITests/BrandingUITests.swift` | `testSettingsEntryReachable` | `settingsButton` hittable |
| 9 | — | — | Command-level: unfiltered `scripts/verify.sh` exit 0, failed 0, skipped 0 |

## Verification commands

```bash
# Fast inner loop (NOT sufficient for Done):
scripts/verify.sh -only-testing:PodWashTests/BrandThemeTests -only-testing:PodWashUITests/BrandingUITests

# Done gate — FULL suite, zero failures, zero skips:
scripts/verify.sh
```

## Verification record (QA fills at Verify)

> Paste the `VERIFY RESULT:` line from the full-suite `scripts/verify.sh` run here.
> A slice without a recorded full-suite green artifact is not Done.

```
VERIFY RESULT: (pending)
```

## Plan review record (coordinator fills before downstream roles)

> Record readonly review outcomes before QA writes tests (ADR review) and before
> Engineer starts (test spec review). No record = next role must not spawn.
> See [`multitask-workflow.md`](../multitask-workflow.md) § Plan review gates.

```
ADR review: (pending)
Test spec review: (pending)
```

## Done gate

- [x] User product decisions resolved and pinned in **Product decisions** section
- [ ] Every AC mapped to a test; all rows in the mapping table filled
- [ ] **Full suite green:** unfiltered `scripts/verify.sh` exit 0, failed 0, skipped 0
- [ ] Verification record pasted above (exit code + counts + `.xcresult` path)
- [ ] Auto-commit made on green: `slice-21: visual identity` (push only when the user asks)

## Role artifacts

| Role | Gate | Artifact path |
|------|------|---------------|
| PM | Required | `docs/slices/slice-21-visual-identity.md` (this file) |
| Architect | Required | `docs/adr/011-brand-theme.md` (`BrandTheme` API, asset linkage, view import rules) |
| UX | Required | `docs/slices/slice-21-ux.md` (chrome layout, `brandWordmark` / `themePrimaryAccent` / `themePrimarySurface` contracts, fixture screen) |
| QA | Required | `BrandThemeTests.swift`, `BrandingUITests.swift` |
| Engineer | Required | `BrandTheme.swift`, asset catalog, Info.plist display name, token wiring on Slice 03/06/13 chrome |
