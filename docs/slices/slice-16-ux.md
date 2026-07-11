# Slice 16 — UX spec: Mute overlay sound (Settings extension)

| Field | Value |
|-------|-------|
| **Slice** | 16 — Beep/quack overlay |
| **Screen** | `SettingsView` — **Cleaning defaults** section (extends Slice 13; no new screen) |
| **ADR** | [ADR-017](../adr/017-overlay-sync.md) §2 (`muteOverlayControl`, `SettingsStore.muteOverlayMode`); [ADR-010](../adr/010-settings-word-lists.md) (Settings fixture routing) |
| **Slice story** | [slice-16-beep-overlay.md](slice-16-beep-overlay.md) |

## Scope note

Slice 16 acceptance criteria **AC1–AC5** are **unit-tested** in `OverlaySyncTests.swift` (overlay sync, offline RMS, seek resync, store-driven asset IDs). This UX spec covers the **Settings control deliverable** only: layout, states, accessibility contract, and **UI test scenarios** automatable in `SettingsUITests.swift`. Playback timing and audio energy are **not** asserted via UI tests.

**Out of scope (no Settings UI):** overlay during skip intervals; live audition of beep/quack in Settings; CarPlay or lock-screen controls; StoreKit gating; re-analysis prompts when mode changes.

## Layout

Extend the existing **Cleaning defaults** section in `SettingsView` (`settingsRoot`). Section order top → bottom within **Cleaning defaults**:

1. **Default cleaning action** — unchanged (`defaultActionControl`).
2. **Mute overlay sound** — **new** discrete cycle control (`muteOverlayControl`). Placed immediately after default cleaning action because overlay applies only when playback action is **mute**.
3. **Default playback speed** — unchanged (`defaultSpeedButton`).

Row pattern matches Slice 13 discrete buttons (`defaultActionControl` / `defaultSpeedButton`): leading label, trailing secondary value text, plain `Button` (not a slider or segmented control).

| Row label (visible) | Trailing value (visible) | Identifier |
|---------------------|--------------------------|------------|
| Mute overlay sound | `Off` / `Beep` / `Quack` | `muteOverlayControl` |

**Production entry:** unchanged from Slice 13 / Slice 23 — `settingsButton` in app chrome presents `SettingsView`. Overlay control is visible whenever Settings is open.

**Behavioral note (not UI-gated):** When an interval uses **skip**, overlay is silent regardless of mode (slice out-of-scope). The control remains enabled and visible so users can preconfigure mute overlay before switching default action to mute.

## States

### Screen root

Unchanged from [slice-13-settings-ux.md](slice-13-settings-ux.md): `settingsRoot` ready state; optional `settings.loading` during fixture bootstrap only.

### Mute overlay control (`muteOverlayControl`)

| State | Visible trailing text | `accessibilityValue` | `accessibilityLabel` |
|-------|----------------------|----------------------|----------------------|
| **Off** (fresh default) | `Off` | `"off"` | `Mute overlay sound` |
| **Beep** | `Beep` | `"beep"` | `Mute overlay sound` |
| **Quack** | `Quack` | `"quack"` | `Mute overlay sound` |

**Interaction:** each tap cycles **`off → beep → quack → off`**. State updates synchronously on the main actor before XCTest post-tap idle (same contract as `defaultActionControl`).

**Persistence:** `SettingsStore` key `podwash.settings.muteOverlayMode`; raw strings `"off"` / `"beep"` / `"quack"`. Fresh / missing key → `.off`. Persistence and playback asset selection are unit-tested in AC4 (`testOverlaySettingRespected`); UI tests verify the control contract only.

**No loading / error / empty states** for this control — local `UserDefaults` read/write only.

## Accessibility identifiers

| Control / region | `accessibilityIdentifier` | `accessibilityLabel` | `accessibilityValue` | `accessibilityHint` |
|------------------|---------------------------|----------------------|----------------------|---------------------|
| Mute overlay sound | `muteOverlayControl` | `Mute overlay sound` | `off` / `beep` / `quack` | `Changes the sound played during muted words. Off is silent.` |

**Discrete control:** `muteOverlayControl` is a `Button` (not a slider). `accessibilityValue` carries the machine-readable mode for XCTest — lowercase tokens exactly as above, not capitalized display strings.

**Cell scoping:** globally queryable on `XCUIApplication` via descendant search, consistent with Slice 13 settings controls.

**VoiceOver:** announces label + value (e.g. “Mute overlay sound, beep”). No separate hint required for Done gate beyond the table above.

## Fixture modes

### Settings fixture (reuse Slice 13)

Launch argument: `-UITestFixtureSettings`

No new launch argument for Slice 16. When present:

- `RootView` shows `SettingsView` directly (same as Slice 13).
- `FixtureSettings.prepareFreshDefaults()` must clear `podwash.settings.muteOverlayMode` so UI tests start at **`accessibilityValue == "off"`** (Engineer extends `SettingsStore.clearPersistedValues`).

**Typical argument set:**

| Test | Launch arguments |
|------|------------------|
| All Slice 16 Settings UI tests | `-UITestFixtureSettings` only |

Do **not** combine with `-UITestFixtureFeed`, `-UITestFixtureAudio`, `-UITestFixtureLibrary`, or other exclusive fixtures. Routing precedence: Settings flag wins when set.

**Parallelization:** UI test **parallelization off** (Slice 03 / 13 precedent — shared `UserDefaults` on simulator install).

## UI test scenarios

Mapped tests extend `SettingsUITests.swift`. Scenarios below are the authoritative UX contract for the `muteOverlayControl` deliverable.

### `testMuteOverlayControlCycles` (Slice 16 UI deliverable)

1. **Launch** — `XCUIApplication` with `-UITestFixtureSettings`; wait for `settingsRoot` (timeout **10 s**).
2. **Fresh default** — assert `muteOverlayControl` exists; assert `accessibilityValue == "off"`.
3. **Tap beep** — tap `muteOverlayControl` once; within **2 s**, assert `accessibilityValue == "beep"`.
4. **Tap quack** — tap once; within **2 s**, assert `accessibilityValue == "quack"`.
5. **Tap off** — tap once; within **2 s**, assert `accessibilityValue == "off"`.

**Query:** prefer `app.buttons["muteOverlayControl"]`; fall back to `app.descendants(matching: .any)["muteOverlayControl"]` if needed (same pattern as Slice 13 category rows).

**Scroll:** `muteOverlayControl` sits in **Cleaning defaults** at the top of `SettingsView`; no scroll helper required in portrait. If landscape leaves the control off-screen, reuse the Slice 13 edge-drag scroll helper before tap.

### UX smoke scenarios (not slice ACs; optional QA coverage)

#### `testMuteOverlayControlReachableFromLibrary` (optional)

1. Launch `-UITestFixtureLibrary`; wait for `libraryRoot`.
2. Tap `settingsButton`; wait for `settingsRoot`.
3. Assert `muteOverlayControl` exists and `accessibilityValue == "off"`.

Documents production shell path (Slice 23); Slice 16 Done gate does not require this if `testSettingsReachableFromLibrary` (Slice 23) already passes and `testMuteOverlayControlCycles` covers the control contract.

## Verification mapping

| Scope | UX artifact | Test method | Notes |
|-------|-------------|-------------|-------|
| Overlay start/stop sync ±50 ms | — | `OverlaySyncTests.testOverlayStartSync` | AC1; unit |
| Overlay stop + exterior silence | — | `OverlaySyncTests.testOverlayEndAndExteriorSilence` | AC2; unit |
| Offline interior RMS beep vs off | — | `OverlaySyncTests.testOfflineRenderOverlayEnergy` | AC3; unit |
| Store mode → asset ID / event counts | — | `OverlaySyncTests.testOverlaySettingRespected` | AC4; unit; default `.off` |
| Seek resync / orphan events | — | `OverlaySyncTests.testSeekResync` | AC5; unit |
| **Mute overlay control cycles off/beep/quack** | `testMuteOverlayControlCycles` scenarios 1–5 | `SettingsUITests.testMuteOverlayControlCycles` | Slice 16 Settings deliverable |
| Full suite | — | `scripts/verify.sh` | AC6; command-level |
