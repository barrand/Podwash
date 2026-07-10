# ADR-010 — Settings + word-list management

| Field | Value |
|-------|-------|
| **Status** | Accepted |
| **Date** | 2026-07-10 |
| **Supersedes** | — |
| **Builds on** | [ADR-000](000-foundations.md) §4 (`TimedWord` / matcher inputs unchanged); [ADR-005](005-analysis-pipeline.md) (`targetWords: Set<String>` fingerprint seam); [ADR-006](006-playback-integration.md) (`PlaybackCoordinator.preparePlayback` / `CensorAction`); [ADR-007](007-persistence-core-data.md) / [ADR-009](009-queue-resume.md) (Core Data for episode/queue — **not** settings); Slice 02 `WordMatcher` / `WordProfiles`; Slice 12 `PlaybackEngine.supportedRates` |
| **Slice** | [slice-13-settings.md](../slices/slice-13-settings.md) |

## Context

Slice 13 ships on-device Settings so users persist cleaning defaults (action,
categories, custom words) and playback defaults (speed, auto-download /
auto-delete toggles). The composed normalized target set must feed
`WordMatcher` / analysis / playback the same way call sites today pass a raw
`Set<String>`.

Product decisions (2026-07-10) pin the default profile: **F/S/D-word + racial
slurs ON**; other categories OFF; default action **mute**; analysis timing and
interval retention are product policy for later wiring — this slice persists
settings and exposes the target set only (no re-analysis orchestration).

Constraints from the slice and prior ADRs:

- Settings use **`UserDefaults`**, not Core Data entities (no schema migration).
- `WordMatcher.normalize` / `normalizedTargetSet` remain the only normalization
  path (matching-spec §3–4).
- `AnalysisPipeline` / `PlaybackCoordinator` keep `targetWords: Set<String>` —
  callers supply the set; do not change fingerprint math (ADR-005).
- Default playback rate must be a member of Slice 12
  `PlaybackEngine.supportedRates` (`[0.75, 1.0, 1.25, 1.5, 2.0, 3.0]`).
- Skip remains a selectable default action; attorney-gated skip **ship** policy
  is out of scope (PRD §11).

## Decision

### 1. Module layout

| File | Target | Status | Responsibility |
|------|--------|--------|----------------|
| `PodWash/PodWash/WordCategories.swift` | app | **new** | Stable category IDs + seeded word lists; default-enabled ID set |
| `PodWash/PodWash/WordProfiles.swift` | app | **keep** | Slice 02 fixture profiles (`harmless`, `profanity`) — unchanged for existing tests |
| `PodWash/PodWash/SettingsStore.swift` | app | **new** | Injectable `UserDefaults`; category/custom-word/defaults persistence; `activeNormalizedTargetSet()` |
| `PodWash/PodWash/SettingsView.swift` | app | **new** | SwiftUI settings screen; accessibility identifiers per slice |
| `PodWash/PodWash/FixtureSettings.swift` | app | **new** | Launch-argument detection (`-UITestFixtureSettings`) |
| `PodWash/PodWash/RootView.swift` (or app chrome) | app | **changed** | Route fixture → `SettingsView`; production entry from app chrome |
| Analysis / playback call sites | app | **changed** | Pass `settingsStore.activeNormalizedTargetSet()` (and `defaultCleaningAction` where action is chosen) instead of `[]` / hardcoded sets — **minimal seam** |
| `PodWash/PodWashTests/SettingsStoreTests.swift` | test | **new (QA)** | AC1–AC4 |
| `PodWash/PodWashUITests/SettingsUITests.swift` | test | **new (QA)** | AC5–AC6 |

**Unchanged:** `WordMatcher`, `IntervalBuilder`, `TimedWord`, `IntervalCache`
fingerprint algorithm, `AnalysisPipeline` / `EpisodeAnalyzing` /
`PlaybackCoordinator` method signatures (`targetWords: Set<String>`), Core Data
schema (ADR-009), download/queue/resume behavior.

### 2. Category IDs and seeded lists (`WordCategories`)

Stable string IDs (used in persistence keys, accessibility identifiers, and
`enabledCategoryIDs`):

| ID | Default | Seed rules |
|----|---------|------------|
| `fWord` | **ON** | ≥ 1 word including `"fuck"`; commit full F-word inflection list (may equal the F-half of `WordProfiles.profanity`) |
| `sWord` | **ON** | **Exactly 4** words: `"shit"`, `"shits"`, `"shitty"`, `"bullshit"` (spec §7 S-word subset) |
| `dWord` | **ON** | Committed seed ≥ 1 word (e.g. `"damn"` + common D-word inflections); tests need not assert tokens |
| `racialSlurs` | **ON** | Committed seed ≥ 1 word; tests assert **count delta on disable**, not slur tokens |
| `godsName` | **OFF** | Committed seed ≥ 1 word (opt-in) |
| `otherProfanity` | **OFF** | Committed seed ≥ 1 word (opt-in) |

```swift
enum WordCategories {
    static let allIDs: [String] = [
        "dWord", "fWord", "godsName", "otherProfanity", "racialSlurs", "sWord"
    ]

    /// Sorted set equality target for fresh-store AC1.
    static let defaultEnabledIDs: Set<String> = [
        "dWord", "fWord", "racialSlurs", "sWord"
    ]

    static func words(for categoryID: String) -> [String]
}
```

- Inflections are enumerated explicitly (no stemming) — same rule as Slice 02.
- `WordProfiles.harmless` / `.profanity` remain for matcher/pipeline fixtures;
  production Settings composition uses **`WordCategories` only**.
- Overlap across categories is allowed but discouraged; `activeNormalizedTargetSet`
  is a **set union**, so duplicate normalized tokens collapse once.

### 3. `SettingsStore` public API

```swift
enum SettingsCleaningAction: String, Codable, Equatable {
    case mute
    case skip
}

final class SettingsStore {
    init(userDefaults: UserDefaults = .standard)

    /// Sorted array of currently enabled category IDs (for AC1 set equality).
    var enabledCategoryIDs: [String] { get }

    func isCategoryEnabled(_ categoryID: String) -> Bool
    func setCategoryEnabled(_ categoryID: String, _ enabled: Bool)

    func addCustomWord(_ raw: String)
    func removeCustomWord(_ rawOrNormalized: String)
    var customWords: [String] { get }  // stored normalized forms, stable order for UI rows

    var defaultCleaningAction: SettingsCleaningAction { get set }
    var defaultPlaybackRate: Float { get set }
    var autoDownloadEnabled: Bool { get set }
    var autoDeleteAfterPlayedEnabled: Bool { get set }

    /// Union of enabled category seeds + custom words, each via
    /// `WordMatcher.normalizedTargetSet` / `normalize`.
    func activeNormalizedTargetSet() -> Set<String>
}
```

**Defaults (fresh suite / missing keys):**

| Key concern | Fresh value |
|-------------|-------------|
| Enabled categories | `WordCategories.defaultEnabledIDs` (exactly 4) |
| Custom words | `[]` |
| `defaultCleaningAction` | `.mute` |
| `defaultPlaybackRate` | `1.0` |
| `autoDownloadEnabled` | `false` |
| `autoDeleteAfterPlayedEnabled` | `false` |

**Persistence:** dedicated `UserDefaults` keys under a `podwash.settings.*`
prefix (exact key strings are an implementation detail). Persist:

- Enabled category IDs as `[String]` (or a dictionary of ID → Bool).
- Custom words as `[String]` of **already-normalized** tokens.
- Action as raw string `"mute"` / `"skip"`.
- Rate as `Float` / `Double`; booleans as `Bool`.

**Rate validation:** on set, snap `defaultPlaybackRate` to the nearest member of
`PlaybackEngine.supportedRates` (same helper pattern as Slice 12). Fresh default
is exactly `1.0`. Persist tests use `2.0`.

**Action type:** `SettingsCleaningAction` mirrors `CensorAction` raw values.
Call sites map `.mute` / `.skip` → `CensorAction` when calling
`preparePlayback` / `setAction`. Do **not** move `CensorAction` into Settings;
keep IntervalBuilder’s type as the playback/interval authority.

**Custom words:**

- `addCustomWord` trims, runs `WordMatcher.normalize`, drops empty results, stores
  the normalized form (dedupe by set membership).
- `removeCustomWord` normalizes the argument then removes that token.
- UI row labels show the stored (normalized) word; `customWordRow_<index>` is
  0-based over `customWords` order.

**`activeNormalizedTargetSet()`:**

```text
raw = ∪{ WordCategories.words(for: id) | id enabled } ∪ customWords
return WordMatcher.normalizedTargetSet(raw)
```

Category disable removes that category’s seeds from the union only; other
categories and custom words stay. Disabling `sWord` must drop set size by
**exactly 4** and remove `"shit"` membership when no other source re-adds it
(AC2).

### 4. Matcher / analysis / playback seam

| Layer | Change |
|-------|--------|
| `WordMatcher` / `IntervalBuilder` / `IntervalCache` | **None** |
| `EpisodeAnalyzing.analyze(… targetWords:)` | **None** (signature stays) |
| `PlaybackCoordinator.preparePlayback(… targetWords:action:)` | **None** (signature stays) |
| App call sites that currently pass `targetWords: []` or a hardcoded set for real cleaning | Pass `settings.activeNormalizedTargetSet()`; pass `CensorAction` mapped from `defaultCleaningAction` when applying the user default |

This slice does **not**:

- Trigger re-analysis when categories/custom words change (cache miss on
  fingerprint change remains ADR-005 / Slice 07 AC3 behavior only when analyze
  is invoked with a new set).
- Implement auto-download fetches or auto-delete file deletion (booleans only).
- Change cleaning-toggle / first-play analysis orchestration (product timing is
  recorded; wiring beyond the target-set seam is out of scope).

### 5. UI + fixture mode

**`SettingsView`:** single settings screen with category toggles, default action
control, default speed control, custom-word field/add/list, auto-download and
auto-delete toggles. Accessibility contract (slice ACs):

| Identifier | `accessibilityValue` |
|------------|----------------------|
| `categoryToggle_<categoryID>` | `"1"` enabled / `"0"` disabled |
| `defaultActionControl` | `"mute"` / `"skip"` |
| `defaultSpeedButton` | decimal rate string (`"0.75"` … `"3.0"`) |
| `customWordTextField` / `customWordAddButton` | (interaction) |
| `customWordRow_<index>` | label contains stored word |
| `autoDownloadToggle` / `autoDeleteToggle` | `"1"` / `"0"` |

**`-UITestFixtureSettings`:**

```swift
enum FixtureSettings {
    static let launchArgument = "-UITestFixtureSettings"
    static var isEnabled: Bool { /* ProcessInfo contains launchArgument */ }
}
```

- Opens `SettingsView` directly (no RSS/network).
- UI test parallelization **off** (Slice 03 precedent).
- Routing precedence: existing fixture modes (`FixtureAudio`, `FixtureFeed`, …)
  unchanged; Settings fixture is a sibling branch in `RootView` (like Audio) —
  when `-UITestFixtureSettings` is present, show Settings and do not load feed.

Production chrome: Settings reachable from the main app shell (exact nav chrome
is UX-owned; Architect requires a reachable path + fixture bypass).

### 6. Test isolation

| Pattern | Rule |
|---------|------|
| Unit tests | `UserDefaults(suiteName: UUID().uuidString)!` (or equivalent unique suite) per test; never `.standard` |
| Reload | `SettingsStore(userDefaults: sameSuite)` — proves persistence without process relaunch |
| Custom-word fixture token | `"xyzzy!"` → `"xyzzy"` (spec §3) |
| UI tests | Launch with `-UITestFixtureSettings` only; do not depend on Core Data / RSS |

### 7. Empirical validation

No framework spike required. Persistence is Foundation `UserDefaults` with an
injectable suite — behavior is fully assertable in XCTest without network, ASR,
StoreKit, or audio render. Normalization claims reuse Slice 02’s already-verified
`WordMatcher` (matching-spec §3). Rate membership reuses Slice 12’s supported set.

## Cross-cutting impact

| Area | Impact |
|------|--------|
| `PlaybackEngine` / `TimedWord` | **None** |
| Parallel slices 12 / 14 | Safe — no queue-order, download-bytes, or lock-screen API changes |
| Slice 17 (StoreKit) | May later gate Settings affordances; no entitlement checks here |
| Slice 20 (timeline UI) | Out of scope |
| Fingerprint / cache | Changing enabled categories changes `activeNormalizedTargetSet` → new fingerprint on next analyze; this slice does not invoke analyze |

## Consequences

- Engineer implements `WordCategories`, `SettingsStore`, `SettingsView`, fixture
  routing, and the minimal target-set/action wiring against this ADR after QA
  test spec + Architect test-spec review.
- QA asserts AC1–AC6 via isolated `UserDefaults` and `-UITestFixtureSettings`
  without subjective listening.
- ADR-007/009 remain authoritative for episode/queue Core Data; settings stay on
  `UserDefaults` unless a future ADR supersedes this boundary.
- `WordProfiles` continues as the Slice 02/07/08 test seed surface; production
  default profile is a **toggle mask over `WordCategories`**, not a third
  monolithic word list.
