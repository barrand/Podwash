# Task 010 — Mini player covers tab bar navigation

| Field | Value |
|-------|-------|
| **ID** | 010 |
| **Title** | Mini player covers tab bar navigation |
| **Status** | Done |
| **Kind** | fix |
| **Priority** | P1 |
| **Area** | `PodWash/PodWash/AppShellView.swift`, `PodWash/PodWash/MiniPlayerBar.swift`, `PodWash/PodWashUITests/LibraryUITests.swift` |
| **Crux** | When `miniPlayer` is visible, `tabLibrary` and `tabDiscover` remain **hittable** and switching tabs works — the mini-player chrome does not cover the tab bar. |

## Outcome

**Observed (physical iPhone, 100% when playing):** Library → show → tap episode → `miniPlayer` appears at the bottom. The bar sits on (or over) the tab-bar region; **Library** and **Discover** tabs are not tappable — user cannot leave the current screen via tab navigation. Matches screenshot on podcast detail with playback active.

**Expected (slice-23-ux / ADR-015):** `MiniPlayerBar` is pinned **above** the `TabView` tab bar; tab items stay visible and hittable. Mini player does not consume the tab-bar hit region.

**Test gap:** `LibraryUITests/testDiscoverEntryFromLibrary` switches tabs only with **no** mini player. `testTapEpisodeShowsMiniPlayerAndPlays` never asserts tab hittability. Optional `testMiniPlayerPersistsAcrossTabSwitch` from slice-23-ux was never implemented.

## Acceptance criteria

- [ ] 1. UI test (`-UITestFixtureLibrary`): play `libraryCell_0` → `episodeCell_0` → `miniPlayer` exists within **5 s**; then `tabDiscover` exists, `isHittable == true`, tap succeeds → `discoverRoot` exists within **5 s**.
- [ ] 2. UI test (same fixture, continuing from AC1 or fresh): with `miniPlayer` still visible, `tabLibrary` is `isHittable == true`; tap → `libraryRoot` exists within **5 s** (user may still be on pushed detail — tab switch must still land on Library tab root or equivalent reachable library chrome).
- [ ] 3. UI test: with `miniPlayer` visible, `tabDiscover.frame` and `tabLibrary.frame` do **not** intersect `miniPlayer.frame` (vertical separation ≥ **0 pt** — tabs sit below the mini-player bar).

## Surgical test scope

| AC# | Test id | New? |
|-----|---------|------|
| 1–2 | `PodWashUITests/LibraryUITests/testTabsRemainHittableWithMiniPlayerVisible()` | yes |
| 3 | `PodWashUITests/LibraryUITests/testMiniPlayerDoesNotOverlapTabBarFrames()` | yes |

## Authorized test changes

- (none — bug fix; new tests only)

## Depends on

- None

## Out of scope

- Redesigning mini-player content (timeline, play button, expand sheet)
- Hiding tab bar on pushed detail screens (tabs should stay available per slice-23)
- CarPlay tab templates

## Human checklist

- [ ] iPhone: play any episode so `miniPlayer` shows.
- [ ] Tap **Discover** tab → Discover screen appears.
- [ ] Tap **Library** tab → Library screen appears.
- [ ] Mini player remains above tabs, not covering them.

## Verification record

> Loop writes `VERIFY RESULT:` here. For tasks, `tier=2` and `filtered=1` are valid for Done.

```
VERIFY RESULT: exit=0 total=2 passed=2 failed=0 skipped=0 filtered=1 bundle=build/test-results/verify-20260713-172013.xcresult tier=2 class=tests
```
