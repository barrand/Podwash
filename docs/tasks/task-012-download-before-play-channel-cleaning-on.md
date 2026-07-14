# Task 012 — Download-before-play when channel cleaning on

| Field | Value |
|-------|-------|
| **ID** | 012 |
| **Title** | Download-before-play when channel cleaning on |
| **Status** | Done |
| **Done at** | 2026-07-14T18:09:11Z |
| **Kind** | tweak |
| **Priority** | P1 |
| **Area** | `PodWash/PodWash/AppShellModel.swift`, `PodWash/PodWash/EpisodeListView.swift`, `PodWash/PodWash/DownloadManager.swift`, `PodWash/PodWash/PlaybackSourceResolver.swift`, `PodWash/PodWashTests/ProductionAnalysisWiringTests.swift`, `PodWash/PodWashTests/DownloadManagerTests.swift`, `PodWash/PodWashUITests/LibraryUITests.swift` |
| **Crux** | With **channel cleaning on**, tapping an episode that is not yet downloaded **starts a download and waits for a local file** before playback/analysis — it does **not** stream the enclosure URL. With **channel cleaning off**, tap-to-play may still stream immediately (uncleaned preview). |

## Outcome

**Product (user-confirmed, aligns with PRD §11 / ADR-000):** PodWash is a cleaning-first app. Default happy path = downloaded local audio → analysis → cleaned playback with timeline chrome. Streaming is for **uncleaned** listening or when download fails — not the silent default when cleaning is enabled.

**Current:** `playEpisode` → `PlaybackSourceResolver.playbackURL` returns remote `episode.audioURL` when no sandbox `.m4a` exists → immediate stream. Analysis/cleaning gates require `isLocalFile` and are skipped. User experience: tap feels like “stream podcast app,” not “download and clean.”

**Desired (option A at intake):**

| Channel cleaning | Not downloaded | Tap episode row |
|------------------|----------------|-----------------|
| **On** | yes | Start download; show row download progress; on success play **local** file and run analysis pipeline; on hard failure allow stream fallback **or** surface failed state (prefer explicit failed UX over silent stream — see AC3) |
| **Off** | yes | Stream remote URL immediately (unchanged uncleaned behavior) |
| Either | already downloaded | Play local file (unchanged) |

**Relation:** Unblocks **task-011** (analysis timeline in player) — timeline needs local file + analysis snapshot. Orthogonal to **task-009** (channel-only toggle). **task-007** (device download reliability) should be Done or Halted with known root cause before human sign-off on this flow.

**Test gap:** `ProductionAnalysisWiringTests` inject local files directly; no test asserts “cleaning on + no local → no stream URL in engine.” `LibraryUITests/testTapEpisodeShowsMiniPlayerAndPlays` uses fixture library with bundled audio — does not model remote-only + cleaning-on tap.

## Acceptance criteria

- [ ] 1. Unit test (`AppShellModel` + spy/injected `DownloadManager`): channel cleaning **on**, episode has remote `audioURL` only, no sandbox file → `playEpisode` invokes download for that `episodeID` and does **not** assign a remote `http(s)` URL to `PlaybackEngine` before download completes.
- [ ] 2. Unit test (same setup): channel cleaning **off**, no local file → `playEpisode` assigns remote enclosure URL to engine (stream path) without calling download.
- [ ] 3. Unit test: channel cleaning **on**, download completes successfully → engine plays **file://** local path; `PlaybackCoordinator.preparePlayback` / analyzer spy `analyze` count **== 1** (local-file gate satisfied).
- [ ] 4. UI test (`-UITestFixtureLibrary` + channel cleaning forced **on** + stub download): tap `episodeCell_0` when `downloadButton_0` is `notDownloaded` → within **2 s** `downloadProgress_0` exists **or** `downloadButton_0` `accessibilityValue == "downloading"`; engine does not report `playing` from stream until `downloaded` (then `miniPlayer` + play path per existing AC4).

## Surgical test scope

| AC# | Test id | New? |
|-----|---------|------|
| 1 | `PodWashTests/ProductionAnalysisWiringTests/testPlayEpisodeDownloadsInsteadOfStreamingWhenChannelCleaningOn()` | yes |
| 2 | `PodWashTests/ProductionAnalysisWiringTests/testPlayEpisodeStreamsWhenChannelCleaningOffAndNoLocalFile()` | yes |
| 3 | `PodWashTests/ProductionAnalysisWiringTests/testPlayEpisodeAnalyzesAfterDownloadCompletesWhenChannelCleaningOn()` | yes |
| 4 | `PodWashUITests/LibraryUITests/testTapEpisodeDownloadsBeforePlayWhenChannelCleaningOn()` | yes |

## Authorized test changes

- `PodWashUITests/LibraryUITests/testTapEpisodeShowsMiniPlayerAndPlays()` — may require channel cleaning **off** or pre-seeded download in setup so it continues to test mini-player play contract without conflating download gate (document in test comment).
- `PodWashUITests/LibraryUITests/testTapEpisodeDownloadsBeforePlayWhenChannelCleaningOn()` — new; do not weaken existing download-button ACs from Slice 10.

## Depends on

- Task 007 (Done) — device download reliability; human sign-off may still be needed on device

## Out of scope

- Flipping `SettingsStore.autoDownloadEnabled` default to **on** (separate settings tweak)
- Auto-download on RSS refresh (Slice 13 policy)
- Changing manual `downloadButton_*` tap behavior when cleaning off
- Analyze-on-download-complete vs analyze-on-first-play (keep PRD Slice 13 policy: analysis on first play **with cleaning enabled** once local file exists — this task only ensures local file exists first)
- HLS / segment streaming architecture

## Human checklist

- [ ] iPhone, channel cleaning **on**, episode **not** downloaded: tap episode row → see downloading state → completes → plays cleaned (muted words if present in episode).
- [ ] Same show, turn channel cleaning **off**, delete download, tap episode → streams without forcing download first.
- [ ] Channel cleaning **on**, airplane mode / bad URL → failed download UX (not infinite silent stream).

## Verification record

> Loop writes `VERIFY RESULT:` here. For tasks, `tier=2` and `filtered=1` are valid for Done.

```
VERIFY RESULT: exit=0 total=4 passed=4 failed=0 skipped=0 filtered=1 bundle=build/test-results/verify-20260714-120804.xcresult tier=2 class=tests
```
