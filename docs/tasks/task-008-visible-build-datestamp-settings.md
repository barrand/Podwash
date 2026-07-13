# Task 008 — Visible build datestamp in Settings

| Field | Value |
|-------|-------|
| **ID** | 008 |
| **Title** | Visible build datestamp in Settings |
| **Status** | Queued |
| **Kind** | tweak |
| **Priority** | P2 |
| **Area** | `PodWash/PodWash/SettingsView.swift`, new small build-stamp helper (e.g. `BuildStamp.swift`), Xcode build-phase / Info.plist key as needed, `PodWash/PodWashUITests/SettingsUITests.swift`, `PodWash/PodWashTests/` (formatter unit test) |
| **Crux** | Settings shows a **compile-time** build stamp in Mountain Time (`America/Denver`) as `YY.M.D.H.MM.SS` (e.g. `26.7.13.16.55.23`) that only changes when the app is rebuilt. |

## Outcome

**Current:** Marketing version stays `1.0` / project version `1`. On device there is no way to tell which Xcode Run is installed (blocks verifying fixes like task-001 / task-007).

**Desired:** Open Settings (`settingsButton` → `settingsRoot`). At the bottom (after Episode behavior), a non-interactive line shows the stamp for **this binary**, labeled clearly (e.g. “Build”), with `accessibilityIdentifier == "buildStamp"` and `accessibilityValue` equal to the stamp string. Stamp uses **Mountain Time** (`America/Denver`), format **`YY.M.D.H.MM.SS`** with unpadded month/day/hour (minutes and seconds zero-padded to 2 digits). Value is fixed at **compile/link** time — not recomputed as “now” on every launch.

**Slice note:** Slice 13 UX has no About/footer section — this tweak adds a footer row; do not rewrite cleaning/word/episode controls.

## Acceptance criteria

- [ ] 1. Unit test: formatting a fixed `Date` in `America/Denver` yields an **exact** expected string in `YY.M.D.H.MM.SS` (pin one known instant → golden string in the test).
- [ ] 2. UI test (`-UITestFixtureSettings`): within **10 s**, `buildStamp` exists under `settingsRoot`; `accessibilityValue` is non-empty and matches regex `^\d{2}\.\d{1,2}\.\d{1,2}\.\d{1,2}\.\d{2}\.\d{2}$`.
- [ ] 3. Unit or UI assert: the stamp string equals the **bundled compile-time** value (Info.plist custom key or generated Swift constant) — not `Date()` sampled at first Settings appear (two reads in one process must be identical; regenerating “now” on appear fails).

## Surgical test scope

| AC# | Test id | New? |
|-----|---------|------|
| 1 | `PodWashTests/BuildStampTests/testFormatsPinnedDateInMountainTime()` | yes |
| 2 | `PodWashUITests/SettingsUITests/testBuildStampVisibleWithExpectedPattern()` | yes |
| 3 | `PodWashTests/BuildStampTests/testStampMatchesBundledCompileTimeConstant()` | yes |

## Authorized test changes

- `PodWashUITests/SettingsUITests.swift` — **add** `testBuildStampVisibleWithExpectedPattern()` only; do not weaken existing Settings ACs (category toggles, defaults, custom words, episode behavior).
- Slice 13 UX: allow a Settings footer `buildStamp` row (doc amend optional; behavior owned by this task).

## Depends on

- None

## Out of scope

- App Store marketing version bumps / TestFlight changelog
- Git SHA or branch name in the stamp (datestamp only unless a follow-up asks)
- Showing the stamp outside Settings (Library chrome, about sheet, CarPlay)
- DEBUG-only gating — stamp is always visible in Settings (including Release) for device punch-list builds

## Human checklist

- [ ] Xcode → Run to iPhone; open Settings; note the stamp.
- [ ] Make a no-op edit or clean rebuild → Run again; stamp’s time component advances; matches wall clock in **MT** within a minute of the build.

## Verification record

> Loop writes `VERIFY RESULT:` here. For tasks, `tier=2` and `filtered=1` are valid for Done.

```
VERIFY RESULT: (pending)
```
