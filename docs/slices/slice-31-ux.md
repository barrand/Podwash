# Slice 31 — UX spec: Restore now-playing session on relaunch

| Field | Value |
|-------|-------|
| **Slice** | 31 — Restore now-playing session on relaunch |
| **Screens** | `AppShellView` / `LibraryView` (cold launch); existing `MiniPlayerBar`, expanded `PlaybackControlsView`, `PodcastDetailView` queue chrome |
| **ADR** | [ADR-027](../adr/027-restore-now-playing-session.md) (active-session store, bootstrap pause-not-play, position flush, preserve fixture) |
| **Builds on** | [slice-23-ux.md](slice-23-ux.md) (`miniPlayer`, `miniPlayerPlayPause`, Library navigation), [slice-03-ux.md](slice-03-ux.md) (`playback.elapsed`, `playback.seekForward15`, play/pause values), [slice-11-queue-resume-ux.md](slice-11-queue-resume-ux.md) (`queueList`, `queueCell_*`, preserve relaunch pattern) |
| **Slice story** | [slice-31-restore-now-playing-session.md](slice-31-restore-now-playing-session.md) |

## Scope note

**No new SwiftUI chrome** — this slice restores existing mini-player, full-player, and up-next queue state after process death. UX pins **cold-start behavior**, **paused-not-playing** contract, **fixture launch args**, and **XCUITest flows**.

**In scope:** mini player visible on cold launch when a durable active session exists; transport **paused** at saved position (± **1** whole second on `playback.elapsed`); up-next queue unchanged across relaunch; discrete seek/pause steps for UI tests.

**Out of scope:** auto-play on restore; clearing session via mini dismiss / stop; CarPlay / lock screen; new player chrome or identifier renames; cross-device sync.

**No slider scrub** — establish pinned position with `playback.seekForward15` (Slice 03 discrete control).

## Layout (unchanged chrome)

Cold launch with a restored session shows the **same** shell as Slice 23:

```text
TabView (Library selected by default)
MiniPlayerBar (above tab bar — visible without episode-row tap)
```

User lands on **Library** (`libraryRoot`). `miniPlayer` is present **above** the tab bar. No modal, banner, or “resume listening?” prompt — restore is silent.

### Z-order (bottom → top)

Unchanged from Slice 23: `TabView` → `MiniPlayerBar` (when `isMiniPlayerVisible`) → full-player sheet (only after user expands).

## States

### App shell — cold launch

| State | Visible UI | `miniPlayer` | `miniPlayerPlayPause` `accessibilityValue` | Notes |
|-------|------------|--------------|---------------------------------------------|-------|
| **No durable session** | Tab bar + active tab only | **Absent** | — | Default first launch / after finish + empty queue clear |
| **Restored session (AC#5)** | Tab bar + `miniPlayer` + `miniPlayerPlayPause` | **Present within 10.0 s** of relaunch | **`paused`** | **No** auto-play; user did **not** tap an episode row on this launch |
| **Restored session — full player closed** | Same as above | Present | `paused` | Expand optional; sheet not shown until user taps `miniPlayer` |

### Mini-player play state on restore (binding)

| Condition | Icon | `accessibilityLabel` | `accessibilityValue` |
|-----------|------|----------------------|----------------------|
| Restored, not playing (normative) | Play | `Play` | **`paused`** |
| User taps play after restore | Pause | `Pause` | `playing` |

Restore bootstrap **must not** leave `miniPlayerPlayPause` on `playing` or `analyzing` without a user tap. If `isPreparingPlayback` is true while paused, value remains **`paused`** once `engine.isPlaying == false` (Slice 30 / ADR-021).

### Full player — elapsed on restore

| Control | Expected after expand |
|---------|----------------------|
| `playback.elapsed` `accessibilityValue` | Whole-second decimal string within **±1** of pinned restore position (see Fixture constants) |
| `playback.playPause` `accessibilityValue` | **`paused`** (matches mini) |

### Up-next queue (episode list only)

Queue chrome lives on `PodcastDetailView` (Slice 11). After relaunch, queue state is **not** visible until the user opens the show (`libraryCell_0` → `episodeList`). Persisted values must match the pre-terminate snapshot (AC#6).

| State | `queueList` `accessibilityValue` | `queueCell_0` `accessibilityValue` |
|-------|----------------------------------|-------------------------------------|
| **Seeded (AC#6)** | `1` (minimum one queued episode) | Episode ID string (pinned: `lib-0-fixture-ep-002`) |
| **Empty** | `0` + `queueEmpty` visible | — (not this slice’s AC path) |

### Dismiss vs durable session (intake — optional smoke, not slice AC)

| User action | Same-process UI | After next cold launch |
|-------------|-----------------|------------------------|
| `stopAndDismissPlayer` / swipe-dismiss mini | `miniPlayer` hidden | `miniPlayer` **returns**, **paused** at flushed position (session id **not** cleared) |

Engineer wires dismiss per ADR-027 §5; QA may add optional smoke — not mapped to AC#1–#7.

## Interaction

### Cold launch with durable session

1. App finishes bootstrap → `restoreNowPlayingSessionIfNeeded()` runs **once** (no episode-row tap).
2. User sees Library tab with `miniPlayer` showing the saved episode title (label substring from store).
3. Audio is **silent** (`miniPlayerPlayPause` → `paused`).
4. User may tap **Play** to resume, **expand** for full controls, or browse Library — mini stays until finish+empty-queue clear or a future explicit clear feature.

### Establishing position before terminate (UI test seed path)

Prefer **discrete** controls (no scrub):

1. Start playback (`episodeCell_0` tap → `miniPlayerPlayPause` if needed → `playing`).
2. Expand (`miniPlayer` tap) → wait for `playback.playPause`.
3. Tap `playback.seekForward15` **once** from start → pinned **15** s elapsed.
4. Tap `playback.playPause` → `paused` (flushes position to `ResumePositionStore`).
5. Dismiss full player (swipe sheet down) — `miniPlayer` remains, `paused`.

### Background return (no process death)

No new UI. In-memory session stays visible; position flush on background is invisible to the user.

## Accessibility identifiers

**No new identifiers** for this slice. Reuse:

| Control | `accessibilityIdentifier` | Restore-relevant contract |
|---------|---------------------------|---------------------------|
| Library root | `libraryRoot` | Cold-launch wait target |
| Show row | `libraryCell_0` | Navigate to queue chrome (AC#6) |
| Episode list | `episodeList` | Queue section host |
| Episode row | `episodeCell_0` | Seed play only on **first** launch |
| Mini expand | `miniPlayer` | AC#5 expand for `playback.elapsed` |
| Mini transport | `miniPlayerPlayPause` | **`paused`** within 10 s after relaunch |
| Full play/pause | `playback.playPause` | `paused` after restore expand |
| Elapsed | `playback.elapsed` | Int value ± **1** s of pinned position |
| Seek +15 s | `playback.seekForward15` | Seed path only |
| Queue list | `queueList` | Count string persists (AC#6) |
| Queue row 0 | `queueCell_0` | `accessibilityValue` = episode ID |
| Add to queue (episode row 1) | `queueAddButton_1` | Seed path only |

**Global query:** `app.descendants(matching: .any)["<identifier>"]`.

## Fixture modes

New family — fixed persistence identifier so terminate + relaunch shares SQLite (ADR-027 §8). Mirrors Slice 11 `-UITestFixtureQueuePreserve` pattern.

### Constants (binding for QA / Engineer)

| Constant | Value |
|----------|-------|
| `FixtureNowPlayingSession.launchArgument` | `-UITestFixtureNowPlayingSession` |
| `FixtureNowPlayingSession.preserveLaunchArgument` | `-UITestFixtureNowPlayingSessionPreserve` |
| `FixtureNowPlayingSession.persistenceIdentifier` | `uitest-now-playing-session` |
| `FixtureNowPlayingSession.pinnedRestorePositionSeconds` | **15.0** |
| Active episode ID (Library show 0, row 0) | `lib-0-fixture-ep-001` |
| First queued episode ID (add via `queueAddButton_1`) | `lib-0-fixture-ep-002` |
| Bundled audio | `test-clip.m4a` (**30.0** s — Slice 03 / Library play path) |

### Persistence binding (`PodWashApp`)

| Launch arguments | Store |
|------------------|--------|
| `-UITestFixtureLibrary` + `-UITestFixtureNowPlayingSession` | `PersistenceController.inMemory(identifier: "uitest-now-playing-session")` — **fixed** |
| `-UITestFixtureLibrary` + `-UITestFixtureNowPlayingSessionPreserve` | Same fixed identifier — **no** store wipe / reseed |
| `-UITestFixtureLibrary` alone (other Library UITests) | Unchanged: fresh `uitest-library-<uuid>` per launch |
| Production | Unchanged |

### Seed launch (step 1 of relaunch tests)

**Arguments:** `-UITestFixtureLibrary`, `-UITestFixtureNowPlayingSession`

| Concern | Behavior |
|---------|----------|
| Library seed | `FixtureLibrary.prepareSeededStore` (may clear + reseed on first launch) |
| Network | None — Library fixture path |
| Session establishment | UI test plays `episodeCell_0`, seeks to **15.0** s, pauses, adds queue (see scenarios) |
| Active session + position + queue | Persisted to fixed in-memory SQLite before `terminate()` |

Do **not** combine with `-UITestFixtureFeed`, `-UITestFixtureAudio`, `-UITestFixtureDiscover`, or other exclusive fixtures.

### Preserve relaunch (step 2)

**Arguments:** `-UITestFixtureLibrary`, `-UITestFixtureNowPlayingSessionPreserve`

| Concern | Behavior |
|---------|----------|
| Store wipe | **Skipped** — queue, resume position, and active session id survive |
| Bootstrap | `restoreNowPlayingSessionIfNeeded()` on shell appear |
| User steps before assert | **None** — do not tap `episodeCell_0` before AC#5 mini assert |

## UI test scenarios

Mapped tests: `PodWash/PodWashUITests/NowPlayingSessionUITests.swift`. AC#1–#4 are unit tests (`NowPlayingSessionTests`); AC#7 is `scripts/verify.sh`.

### Shared helpers (recommended)

```swift
private let nowPlayingSessionArgs = ["-UITestFixtureLibrary", "-UITestFixtureNowPlayingSession"]
private let nowPlayingSessionPreserveArgs = ["-UITestFixtureLibrary", "-UITestFixtureNowPlayingSessionPreserve"]
private let pinnedPositionSeconds = 15
private let relaunchMiniTimeout: TimeInterval = 10
private let expandTimeout: TimeInterval = 5
```

### `establishPausedSessionWithQueue` (seed helper — both AC#5 and AC#6)

1. **Launch** — `XCUIApplication` with `nowPlayingSessionArgs`; wait for `libraryRoot` (**5 s**).
2. **Open show** — tap `libraryCell_0`; wait for `episodeList` (**5 s**).
3. **Start session** — tap `episodeCell_0`; within **5 s** assert `miniPlayer` exists.
4. **Play** — tap `miniPlayerPlayPause`; within **5 s** assert `accessibilityValue == "playing"`.
5. **Seek + pause** — tap `miniPlayer` (expand, **not** `miniPlayerPlayPause`); within **5 s** assert `playback.playPause` exists; tap `playback.seekForward15` once; tap `playback.playPause`; within **5 s** assert `playback.playPause` `accessibilityValue == "paused"`; optionally assert `playback.elapsed` as `Int` is **≥ 14** and **≤ 16** before dismiss.
6. **Queue** — dismiss full player (swipe down); assert `miniPlayer` still exists; tap `queueAddButton_1`; within **2 s** assert `queueList` `accessibilityValue == "1"`; assert `queueCell_0` `accessibilityValue == "lib-0-fixture-ep-002"`; **record** `queueList` value and `queueCell_0` value.
7. **Snapshot mini state** — assert `miniPlayerPlayPause` `accessibilityValue == "paused"`.

### `testMiniPlayerRestoresPausedAfterRelaunch` (AC#5)

1. Run `establishPausedSessionWithQueue` through step 7 (queue optional for this AC but harmless).
2. **Terminate** — `app.terminate()`.
3. **Relaunch** — new `XCUIApplication` with `nowPlayingSessionPreserveArgs`; launch; wait for `libraryRoot` (**5 s**).
4. **Restore assert** — within **10.0 s** assert `miniPlayer` exists **without** tapping `episodeCell_0`.
5. **Paused** — assert `miniPlayerPlayPause` `accessibilityValue == "paused"`.
6. **Position** — tap `miniPlayer`; within **5 s** assert `playback.elapsed` exists; read `accessibilityValue` as `Int` → assert **≥ `pinnedPositionSeconds - 1`** and **≤ `pinnedPositionSeconds + 1`** (i.e. **14…16** for pin **15**).
7. **Not playing** — assert `playback.playPause` `accessibilityValue == "paused"`.

### `testQueuePersistsWithRestoredSessionAfterRelaunch` (AC#6)

1. Run `establishPausedSessionWithQueue` through step 6; **record** `queueList` and `queueCell_0` `accessibilityValue` strings.
2. **Terminate** — `app.terminate()`.
3. **Relaunch** — `nowPlayingSessionPreserveArgs`; wait for `libraryRoot` (**5 s**).
4. **Mini restored** — within **10.0 s** assert `miniPlayer` exists; assert `miniPlayerPlayPause` `accessibilityValue == "paused"`.
5. **Queue chrome** — tap `libraryCell_0`; wait for `episodeList` (**5 s**).
6. **Persisted queue** — assert `queueList` `accessibilityValue` equals recorded value; assert `queueCell_0` exists and `accessibilityValue` equals recorded value (pinned seed: count **`1`**, id **`lib-0-fixture-ep-002`**).

## Verification mapping

| AC# | UX artifact | Test file / method | Notes |
|-----|-------------|-------------------|-------|
| 1 | — | `NowPlayingSessionTests.testActiveSessionPersistsAcrossReload` | Unit; feed fixture ids |
| 2 | — | `NowPlayingSessionTests.testBootstrapRestoresMiniPlayerPausedAtPosition` | Unit; `127.5 ± 1.0` s |
| 3 | — | `NowPlayingSessionTests.testSessionClearsWhenEpisodeEndsWithEmptyQueue` | Unit |
| 4 | — | `NowPlayingSessionTests.testSessionSurvivesAdvanceWhenQueueNonEmpty` | Unit |
| 5 | `testMiniPlayerRestoresPausedAfterRelaunch` | `NowPlayingSessionUITests.testMiniPlayerRestoresPausedAfterRelaunch` | Preserve arg; mini **10 s**; elapsed ± **1** s |
| 6 | `testQueuePersistsWithRestoredSessionAfterRelaunch` | `NowPlayingSessionUITests.testQueuePersistsWithRestoredSessionAfterRelaunch` | `queueList` + `queueCell_0` match snapshot |
| 7 | — | `scripts/verify.sh` | Full suite |

## UX regression scenarios (optional QA — not slice ACs)

### `testNoMiniPlayerOnColdLaunchWithoutSession`

1. Launch `-UITestFixtureLibrary` only (no Now Playing Session args); wait for `libraryRoot`.
2. Assert `miniPlayer` does **not** exist within **2 s** (negative wait).

### `testDismissedMiniRestoresAfterRelaunch`

1. Run seed helper through paused session (steps 1–5 of `establishPausedSessionWithQueue`; queue optional).
2. If production exposes a dismiss/stop control in a later slice, invoke `stopAndDismissPlayer` equivalent; else skip until control exists.
3. `terminate()` → relaunch with `nowPlayingSessionPreserveArgs`.
4. Within **10 s** assert `miniPlayer` exists and `miniPlayerPlayPause` `accessibilityValue == "paused"`.

### `testRestoredMiniDoesNotAutoPlay`

1. After preserve relaunch (AC#5 step 3), wait **2 s** without interaction.
2. Assert `miniPlayerPlayPause` `accessibilityValue` remains **`paused`** (never transitions to `playing` without tap).
