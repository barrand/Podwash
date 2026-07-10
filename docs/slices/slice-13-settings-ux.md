# Slice 13 — UX spec: Settings + word-list management

| Field | Value |
|-------|-------|
| **Slice** | 13 — Settings + word-list management |
| **Screen** | `SettingsView` (fixture-mode root; production: pushed from app chrome) |
| **ADR** | [ADR-010](../adr/010-settings-word-lists.md) §5 (identifiers, fixture routing) |

## Layout

Single `Form` / grouped-list screen (`settingsRoot`). Sections top → bottom:

1. **Cleaning defaults**
   - **Default action** — one discrete control cycles mute ↔ skip (`defaultActionControl`). No slider or segmented scrub (XCUITest prefers discrete taps).
   - **Default playback speed** — one discrete button cycles supported rates (`defaultSpeedButton`). Same rate set and wrap order as Slice 12 `speedButton` (`[0.75, 1.0, 1.25, 1.5, 2.0, 3.0]`).
2. **Word categories**
   - One row per seeded category in stable ID order (`WordCategories.allIDs`: `dWord`, `fWord`, `godsName`, `otherProfanity`, `racialSlurs`, `sWord`).
   - Each row: human-readable title (see labels below) + trailing `Toggle` (`categoryToggle_<categoryID>`).
   - Category rows do **not** enumerate seed tokens in the UI (faith/family posture; slur tokens stay in code only).
3. **Custom words**
   - Inline field + **Add** button (`customWordTextField`, `customWordAddButton`).
   - List of added words below; each row shows the stored (normalized) word and an optional trailing **Remove** control (`customWordRemoveButton_<index>`). Remove is UX-complete but not slice-AC-mapped — Engineer may ship row-only if delete is swipe-to-delete with the same identifier on the delete action.
   - Empty copy: **No custom words** when the list is empty (visible text; not a separate AX element).
4. **Episode behavior**
   - **Auto-download new episodes** — `Toggle` (`autoDownloadToggle`).
   - **Auto-delete after played** — `Toggle` (`autoDeleteToggle`).

**Production entry:** `ContentView` (or future main shell) exposes a toolbar **Settings** affordance (`settingsButton`) that presents or pushes `SettingsView`. Exact chrome may evolve; fixture mode bypasses navigation (see Fixture modes).

**Out of scope (no UI in this slice):** paywall gating, re-analysis prompts when lists change, auto-download/delete side effects, lock-screen settings, timeline/segment colors (Slice 20).

## States

### Screen root

| State | Visible UI | Root `accessibilityIdentifier` | Notes |
|-------|------------|--------------------------------|-------|
| **Ready** | Full form | `settingsRoot` | Default; `SettingsStore` read synchronously from `UserDefaults` |
| **Loading** (fixture bootstrap only) | `ProgressView` | `settings.loading` | Only if `RootView` async-wires store; must resolve to `settingsRoot` within **10 s** |

No network, RSS, or Core Data fetch on this screen.

### Category toggles (per `categoryToggle_<categoryID>`)

| State | `accessibilityValue` | `accessibilityLabel` (category) |
|-------|----------------------|----------------------------------|
| **Enabled** | `"1"` | See identifier table |
| **Disabled** | `"0"` | Same |

Fresh install / fresh `UserDefaults` suite (PRD default profile):

| Category ID | Initial state |
|-------------|---------------|
| `dWord`, `fWord`, `racialSlurs`, `sWord` | **ON** (`"1"`) |
| `godsName`, `otherProfanity` | **OFF** (`"0"`) |

### Default cleaning action (`defaultActionControl`)

| State | `accessibilityValue` | `accessibilityLabel` |
|-------|----------------------|----------------------|
| **Mute** (fresh default) | `"mute"` | `Default cleaning action` |
| **Skip** | `"skip"` | `Default cleaning action` |

**Interaction:** each tap cycles `mute → skip → mute`. State updates synchronously on the main actor before XCTest post-tap idle.

### Default playback speed (`defaultSpeedButton`)

| State | `accessibilityValue` | Notes |
|-------|----------------------|-------|
| **Rate *r*** | Decimal string (`"0.75"`, `"1.0"`, … `"3.0"`) | Fresh default `"1.0"` |

**Interaction:** each tap advances to the next member of `PlaybackEngine.supportedRates` in order **`1.0 → 1.25 → 1.5 → 2.0 → 3.0 → 0.75 → 1.0`** (wrap after `"3.0"`). Matches Slice 12 `speedButton` cycle starting from `1.0`.

### Custom words

| State | UI | Identifiers |
|-------|-----|-------------|
| **Empty** | "No custom words" copy; no `customWordRow_*` | `customWordTextField`, `customWordAddButton` enabled |
| **Has words** | One row per stored word, 0-based index in `customWords` store order | `customWordRow_<index>`; optional `customWordRemoveButton_<index>` |

**Add flow:** user enters text in `customWordTextField`, taps `customWordAddButton`. Store normalizes per matching-spec §3 (trim, strip punctuation) before persist. Empty-after-normalize input is a no-op (button may disable when field is empty/whitespace-only).

**Duplicate:** adding a word whose normalized form already exists does not create a second row (set dedupe per ADR-010).

### Auto-download / auto-delete toggles

| State | `accessibilityValue` |
|-------|----------------------|
| **Off** (fresh default) | `"0"` |
| **On** | `"1"` |

Booleans persist only; no download/delete UI feedback in this slice.

## Accessibility identifiers

| Control / region | `accessibilityIdentifier` | `accessibilityLabel` | `accessibilityValue` | `accessibilityHint` |
|------------------|---------------------------|----------------------|----------------------|---------------------|
| Settings screen root | `settingsRoot` | `Settings` | — | — |
| Production nav entry | `settingsButton` | `Settings` | — | `Opens cleaning and playback defaults.` |
| Default cleaning action | `defaultActionControl` | `Default cleaning action` | `mute` / `skip` | `Changes the default action for new cleaning sessions.` |
| Default playback speed | `defaultSpeedButton` | `Default playback speed` | Rate decimal string | `Changes the default playback speed.` |
| Category toggle `dWord` | `categoryToggle_dWord` | `D-word` | `"1"` / `"0"` | `Includes or excludes D-word cleaning.` |
| Category toggle `fWord` | `categoryToggle_fWord` | `F-word` | `"1"` / `"0"` | `Includes or excludes F-word cleaning.` |
| Category toggle `sWord` | `categoryToggle_sWord` | `S-word` | `"1"` / `"0"` | `Includes or excludes S-word cleaning.` |
| Category toggle `racialSlurs` | `categoryToggle_racialSlurs` | `Racial slurs` | `"1"` / `"0"` | `Includes or excludes racial slur cleaning.` |
| Category toggle `godsName` | `categoryToggle_godsName` | `God's name in vain` | `"1"` / `"0"` | `Includes or excludes this category.` |
| Category toggle `otherProfanity` | `categoryToggle_otherProfanity` | `Other profanity` | `"1"` / `"0"` | `Includes or excludes this category.` |
| Custom word field | `customWordTextField` | `Custom word` | — | `Enter a word to add to your cleaning list.` |
| Custom word add | `customWordAddButton` | `Add custom word` | — | — |
| Custom word row *i* | `customWordRow_<index>` | Stored word (full string) | — | — |
| Custom word remove *i* (optional) | `customWordRemoveButton_<index>` | `Remove custom word` | Stored word | `Removes this word from your cleaning list.` |
| Auto-download toggle | `autoDownloadToggle` | `Auto-download new episodes` | `"1"` / `"0"` | — |
| Auto-delete toggle | `autoDeleteToggle` | `Auto-delete after played` | `"1"` / `"0"` | — |

**Index convention:** `<index>` on custom-word rows is 0-based over `SettingsStore.customWords` display order. After the first add in a fresh store, the new word is `customWordRow_0`.

**Toggle contract:** category and auto toggles are `Switch`es (or equivalent) exposing `accessibilityValue` `"1"` / `"0"` — not icon-only buttons. UI tests query via `app.switches["categoryToggle_sWord"]` or `app.buttons[...]` if the platform maps toggles as buttons; Engineer must ensure post-tap `accessibilityValue` is stable.

**Discrete controls:** `defaultActionControl` and `defaultSpeedButton` are buttons (not sliders). `accessibilityValue` carries the machine-readable state for XCTest.

**Cell scoping:** all identifiers are globally queryable on `XCUIApplication` (descendant search), consistent with Slice 06–11 fixture screens.

## Fixture modes

### Settings fixture (new)

Launch argument: `-UITestFixtureSettings`

When present:

- `RootView` shows `SettingsView` directly (sibling branch to `FixtureAudio` / `FixtureFeed`; no RSS, network, or Core Data episode load).
- `SettingsStore` uses production `UserDefaults` semantics with **PRD-fresh defaults** when keys are absent (AC5 expects `categoryToggle_sWord` `accessibilityValue == "1"` at launch).
- UI test **parallelization off** (Slice 03 precedent — shared `UserDefaults` if tests ever share a simulator install).

Implementation note for Engineer: mirror `FixtureAudio` / `FixtureFeed` — e.g. `FixtureSettings.isEnabled` checks `ProcessInfo.processInfo.arguments` for `-UITestFixtureSettings` (and optional `hasSuffix` guard per `FixtureQueue` pattern).

**Typical argument set:**

| Test | Launch arguments |
|------|------------------|
| All Slice 13 UI tests | `-UITestFixtureSettings` only |

Do **not** combine with `-UITestFixtureFeed` or `-UITestFixtureAudio` for mapped AC tests; routing precedence should prefer Settings when its flag is set.

## UI test scenarios

Mapped tests live in `SettingsUITests.swift`. Scenarios below are the authoritative UX contract for slice AC#5–#6; AC#1–#4 are unit-tested in `SettingsStoreTests` (no UI coverage required).

### `testCategoryToggleAccessibilityValue` (AC#5)

1. **Launch** — `XCUIApplication` with `-UITestFixtureSettings`; wait for `settingsRoot` (timeout **10 s**).
2. **Initial ON** — assert `categoryToggle_sWord` exists; assert `accessibilityValue == "1"`.
3. **Tap off** — tap `categoryToggle_sWord` once; assert `accessibilityValue == "0"`.
4. **Tap on** — tap `categoryToggle_sWord` once more; assert `accessibilityValue == "1"`.

### `testCustomWordAppearsInList` (AC#6)

1. **Launch** — `XCUIApplication` with `-UITestFixtureSettings`; wait for `settingsRoot` (timeout **10 s**).
2. **Assert empty** — assert `customWordRow_0` does **not** exist.
3. **Enter word** — tap `customWordTextField`; type `testword` (no trailing newline required).
4. **Add** — tap `customWordAddButton`; within **2 s**, assert `customWordRow_0` exists; assert `customWordRow_0` `label` contains `testword` (case-insensitive substring match).

### UX smoke scenarios (not slice ACs; optional QA coverage)

Engineer/QA may add these later; documenting expected behavior for completeness:

#### `testDefaultSpeedButtonCycles` (optional)

1. Launch with `-UITestFixtureSettings`; wait for `settingsRoot`.
2. Assert `defaultSpeedButton` `accessibilityValue == "1.0"`.
3. Six consecutive taps assert sequence: `"1.25"` → `"1.5"` → `"2.0"` → `"3.0"` → `"0.75"` → `"1.0"`.

#### `testDefaultActionControlCycles` (optional)

1. Launch with `-UITestFixtureSettings`; wait for `settingsRoot`.
2. Assert `defaultActionControl` `accessibilityValue == "mute"`.
3. Tap once → `"skip"`; tap once → `"mute"`.

## Verification mapping

| Scope | UX artifact | Test method | Notes |
|-------|-------------|-------------|-------|
| AC#5 category toggle contract | `testCategoryToggleAccessibilityValue` scenarios 1–4 | `SettingsUITests.testCategoryToggleAccessibilityValue` | `"1"` ↔ `"0"` on `categoryToggle_sWord` |
| AC#6 custom word add + row label | `testCustomWordAppearsInList` scenarios 1–4 | `SettingsUITests.testCustomWordAppearsInList` | `customWordRow_0` label contains `testword` |
| AC#1–#4 store persistence / target set | — | `SettingsStoreTests` | Unit tests per slice verification table |
| AC#7 full suite | — | `scripts/verify.sh` | Command-level; not UX-authored |
