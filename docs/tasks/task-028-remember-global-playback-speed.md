# Task 028 — Remember global playback speed

| Field | Value |
|-------|-------|
| **ID** | 028 |
| **Title** | Remember global playback speed |
| **Status** | In Progress |
| **Kind** | tweak |
| **Priority** | P2 |
| **Area** | `PodWash/PodWash/PlaybackEngine.swift`, `PodWash/PodWash/AppShellModel.swift`, `PodWash/PodWash/PlaybackCoordinator.swift`, `PodWash/PodWash/PlaybackControlsView.swift`, `PodWash/PodWash/SettingsStore.swift` |
| **Crux** | Changing rate via player `speedButton` / `setRate` updates `SettingsStore.defaultPlaybackRate`, and every new `PlaybackEngine` seeds `selectedRate` from that store so the rate survives episode switches and app relaunches. |

## Outcome

**Current:** Settings persists `defaultPlaybackRate` (Slice 13 / ADR-010) and Settings UI can cycle it via `defaultSpeedButton`, but player chrome does not participate: `PlaybackEngine.selectedRate` defaults to `1.0` on every new engine (`AppShellModel` constructs `PlaybackEngine` without reading the store), and `cycleRate()` / `setRate(_:)` update only the in-session engine. Changing speed while listening is forgotten on the next episode or relaunch.

**Desired:** One global preference — the existing `SettingsStore.defaultPlaybackRate` / Settings “Default playback speed”. Any change from player `speedButton` (or Settings) is remembered and applied to all future plays. No per-podcast override.

**Framing:** If a unit test sets rate via the player path, reloads the store, and builds a replacement engine that starts at that rate (±0.001), we never re-check on device that 1.5× “stuck.”

## Acceptance criteria

- [ ] 1. Unit (`SettingsStore` injectable suite + production writeback path): after `setRate(1.5)` (or `cycleRate` landing on `1.5`) on an engine wired to the store, `store.defaultPlaybackRate == 1.5` (± **0.001**); a new `SettingsStore(userDefaults: same suite)` still reports **1.5** (± **0.001**).
- [ ] 2. Unit: with `store.defaultPlaybackRate = 2.0`, construct a new `PlaybackEngine` via the production seed path (same seam `AppShellModel` / coordinator uses when starting an episode) → `selectedRate == 2.0` (± **0.001**).
- [ ] 3. Unit: set rate **1.5** on engine A with the store wired; tear down and create engine B with the same store (no further `setRate`) → B’s `selectedRate == 1.5` (± **0.001**).
- [ ] 4. Existing UI contract stays green: `-UITestFixtureAudio` launch still has `speedButton` `accessibilityValue == "1.0"` at start, and six taps still cycle **`"1.25"` → `"1.5"` → `"2.0"` → `"3.0"` → `"0.75"` → `"1.0"`** (`PlaybackControlsUITests/testSpeedButtonCyclesRates`). Fixture may reset `defaultPlaybackRate` to **1.0** so seeded defaults do not flaky the assert.

## Surgical test scope

| AC# | Test id | New? |
|-----|---------|------|
| 1 | `PodWashTests/PlaybackRateTests/testSetRateWritesDefaultPlaybackRate()` | yes |
| 2 | `PodWashTests/PlaybackRateTests/testNewEngineSeedsSelectedRateFromSettingsStore()` | yes |
| 3 | `PodWashTests/PlaybackRateTests/testReplacementEngineKeepsPersistedRate()` | yes |
| 4 | `PodWashUITests/PlaybackControlsUITests/testSpeedButtonCyclesRates` | no (must stay green) |

## Authorized test changes

- `PodWashUITests/PlaybackControlsUITests/testSpeedButtonCyclesRates` — only if fixture/launch isolation is required so the fresh-start `"1.0"` assert remains valid after seeding is wired; do **not** weaken the cycle sequence or drop the start-at-`1.0` assert for a clean fixture.
- New `PlaybackRateTests` methods above may use an injectable `SettingsStore` / `UserDefaults` suite; do not loosen existing AC1–AC2 rate/mute assertions in `PlaybackRateTests`.

## Depends on

- None

## Out of scope

- Per-podcast (or per-channel) playback-rate overrides (may revisit later; not this ticket)
- New rate values beyond `PlaybackEngine.supportedRates`
- CarPlay / remote-command `changePlaybackRate`
- Changing Settings UI layout beyond staying in sync via the shared store
- Subjective “feels right” listening checks

## Human checklist

(not applicable)

## Verification record

> Loop writes `VERIFY RESULT:` here. For tasks, `tier=2` and `filtered=1` are valid for Done.

```
VERIFY RESULT: exit=0 total=5 passed=5 failed=0 skipped=0 filtered=1 bundle=build/test-results/verify-20260716-115028.xcresult tier=2 class=tests
```
