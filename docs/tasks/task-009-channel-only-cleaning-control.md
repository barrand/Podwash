# Task 009 — Channel-only cleaning control (remove per-episode toggles)

| Field | Value |
|-------|-------|
| **ID** | 009 |
| **Title** | Channel-only cleaning control (remove per-episode toggles) |
| **Status** | In Progress |
| **Kind** | tweak |
| **Priority** | P2 |
| **Area** | `PodWash/PodWash/EpisodeListView.swift`, `PodWash/PodWash/AnalysisUIViewModel.swift`, `PodWash/PodWash/AppShellModel.swift`, `PodWash/PodWashUITests/AnalysisProgressUITests.swift`, `PodWash/PodWashUITests/AnalysisTimelineUITests.swift`, `PodWash/PodWashTests/ProductionAnalysisWiringTests.swift` (plus any other tests that tap `episodeCleaningToggle_*`) |
| **Crux** | Cleaning is controlled **only** by `channelCleaningToggle`; episode rows expose **no** `episodeCleaningToggle_*`, and playback cleaning ignores per-episode flags. |

## Outcome

**Current:** Podcast detail has **Clean channel** (`channelCleaningToggle`) **and** a per-row `episodeCleaningToggle_<index>`. Cleaning applies if episode **OR** channel is on (`AppShellModel.cleaningApplies`). With channel on, row switches do not opt out — they only matter when channel is off. Users find the row toggles redundant and unclear.

**Desired (option A):** Remove per-episode cleaning switches (and the row `cleaningBadge_episodeOn` affordance that exists only for episode-on). Channel toggle is the sole cleaning control. `cleaningApplies` / play-path analysis gates on **channel cleaning only**. Fixture UI flows that used to enable cleaning via `episodeCleaningToggle_0` use `channelCleaningToggle` instead (channel-on must still drive the same analysis/timeline observable windows those tests require).

**Product note:** Per-episode opt-out / override (channel on + episode off = skip clean) is **out of scope** — not requested.

## Acceptance criteria

- [ ] 1. UI test (`-UITestFixtureFeed` or Library fixture that shows episode list): after detail is up, `episodeCleaningToggle_0` (and `_1` if present) **do not exist**; `channelCleaningToggle` **does** exist.
- [ ] 2. Unit test: with channel cleaning **on** and episode cleaning store flag **off**, `cleaningApplies` / play prepare path still runs analysis (rewrite of today’s AC6 shape — channel alone is sufficient). With channel **off**, analysis is skipped even if a stale episode flag remains in the store.
- [ ] 3. UI tests that previously toggled `episodeCleaningToggle_0` to show timeline/progress/badges instead toggle `channelCleaningToggle` and still meet their existing timing budgets (timeline / completion asserts updated: **no** `cleaningBadge_episodeOn` requirement).

## Surgical test scope

| AC# | Test id | New? |
|-----|---------|------|
| 1 | `PodWashUITests/AnalysisProgressUITests/testEpisodeCleaningTogglesAbsentChannelTogglePresent()` | yes |
| 2 | `PodWashTests/ProductionAnalysisWiringTests/testPlayEpisodeRunsAnalysisWhenChannelOnEpisodeFlagOff()` | yes (or rewrite existing AC6 method) |
| 2b | `PodWashTests/ProductionAnalysisWiringTests/testPlayEpisodeSkipsAnalysisWhenChannelOffEvenIfEpisodeFlagOn()` | yes |
| 3 | `PodWashUITests/AnalysisProgressUITests/testToggleBadges()` | no — authorized bend |
| 3 | `PodWashUITests/AnalysisProgressUITests/testAnalysisProgressLifecycle()` (or equivalent that taps episode toggle) | no — authorized bend |
| 3 | `PodWashUITests/AnalysisTimelineUITests/*` methods that tap `episodeCleaningToggle_0` | no — authorized bend |

## Authorized test changes

- `PodWashUITests/AnalysisProgressUITests.swift` — replace `episodeCleaningToggle_*` taps/asserts with `channelCleaningToggle`; **remove** `cleaningBadge_episodeOn` existence asserts.
- `PodWashUITests/AnalysisTimelineUITests.swift` — same: enable via channel toggle; drop episode-badge requirements; keep timeline value asserts.
- `PodWashTests/ProductionAnalysisWiringTests.swift` — cleaning gate asserts become **channel-only** (episode-only “on” must **not** trigger analysis).
- `PodWashTests/EpisodeTableViewCellLayoutTests.swift` — stop calling `primeEpisodeCleaningToggle` if timeline visibility for layout needs channel priming instead.
- `PodWashTests/AnalysisUIStateTests.swift` — may drop or rewrite episode-toggle-centric cases; must not require UI episode switches.
- Do **not** weaken download/queue/identifier contracts for `queueAddButton_*` / `downloadButton_*`.

## Depends on

- None (orthogonal to task-002 Done badge removal)

## Out of scope

- Per-episode opt-out / override semantics (option C)
- Deleting Core Data / `CleaningToggleStore` episode fields (may remain unused for migration compatibility; UI and play path must not use them)
- Changing “Skip ads on channel” (`channelUnrelatedContentToggle`)
- Rewriting slice-09/20 UX docs as a Done gate (optional follow-up amend)

## Human checklist

- [ ] Library → show: only **Clean channel** controls cleaning; no switches on episode rows.
- [ ] Channel on → play a downloaded episode → cleaned path still engages (same as before when channel was on).

## Verification record

> Loop writes `VERIFY RESULT:` here. For tasks, `tier=2` and `filtered=1` are valid for Done.

```
VERIFY RESULT: exit=0 total=8 passed=8 failed=0 skipped=0 filtered=1 bundle=build/test-results/verify-20260713-172526.xcresult tier=2 class=tests
```
