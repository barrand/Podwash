# ADR-027 — Restore now-playing session on relaunch

| Field | Value |
|-------|-------|
| **Status** | Accepted |
| **Date** | 2026-07-15 |
| **Supersedes** | — (does **not** replace [ADR-009](009-queue-resume.md) queue/position stores or [ADR-015](015-app-shell-navigation.md) mini chrome; **extends** them with a durable active-session id + shell bootstrap) |
| **Builds on** | [ADR-000](000-foundations.md) §2/§6 (AX / offline verify); [ADR-007](007-persistence-core-data.md) (Core Data); [ADR-009](009-queue-resume.md) (`QueueStore`, `ResumePositionStore`, `QueueCoordinator`, reload pattern); [ADR-015](015-app-shell-navigation.md) (`AppShellModel`, `isMiniPlayerVisible`, `stopAndDismissPlayer`, Library fixtures) |
| **Slice** | [slice-31-restore-now-playing-session.md](../slices/slice-31-restore-now-playing-session.md) |

## Context

Slice 11 made **up-next order** and **per-episode playback position** durable
(`QueueStore`, `ResumePositionStore`). Slice 23 made the production shell show a
**mini player** when `AppShellModel` has an in-memory session
(`nowPlayingEpisodeID`, `isMiniPlayerVisible`, `PlaybackEngine`).

Gap: after process death, queue + position reload, but the shell does **not** know
which episode was “now playing,” so cold start never shows `miniPlayer` until the
user taps an episode row again.

Intake pins (locked — do not re-litigate):

| Pin | Choice |
|-----|--------|
| Cold-relaunch audio | Show `miniPlayer` **paused** at saved position — **do not** auto-play |
| What clears durable active session | **Only** when the current episode **finishes** and the up-next queue is **empty** |
| Explicit mini dismiss / `stopAndDismissPlayer` | Must **not** clear the durable active-session id (hide chrome vs keep session) |
| Background return (no process death) | Same in-memory session; ensure position is flushed so a later kill still restores |
| CarPlay / lock screen | Out of scope |

Acceptance is unit reload + bootstrap (ACs 1–4) and UITest relaunch preserve
(ACs 5–6). No device listening.

## Empirical validation

**No throwaway spike required.** Claims are:

| Claim | Already proven / how verified |
|-------|-------------------------------|
| Core Data survives “relaunch” | ADR-009 reload pattern (`PersistenceController.inMemory(identifier:)`) |
| Position ±1.0 s | `ResumePositionStore` Double + `PlaybackEngine.seek` (Slice 11 AC3) |
| Mini paused AX | Slice 03 / 23 `miniPlayerPlayPause` `"paused"` / `"playing"` |
| Queue chrome across terminate | Slice 11 `-UITestFixtureQueuePreserve` family (production SQLite) |
| Seek while not playing | Existing `PlaybackEngine.seek` + paused mini session in `beginPlaybackSession` |

No new AVFoundation mix, ASR, StoreKit, CarPlay, or networking behavior.

## Decision

### 1. Durable active session (schema)

Add a **singleton** Core Data entity (at most one row) holding the active
now-playing episode id. Queue order and position remain in existing stores —
do **not** duplicate them on the session row.

| Entity | Attributes | Notes |
|--------|------------|-------|
| `CDNowPlayingSession` | `activeEpisodeID: String` (required when row exists) | Absence of row **or** empty id ⇒ no durable session |

**Migration:** additive lightweight / inferred migration on the existing
`PodWash.xcdatamodeld` (same pattern as ADR-014 / ADR-013 attribute adds). New
entity only — no change to `CDEpisode` / `CDQueueEntry` / `CDPodcast`.

**Why Core Data (not UserDefaults):** AC1 asserts active id + position + queue
together after a new `PersistenceController` on the **same** store. Keep the
session in that store so one reload harness covers all three.

**Why not an attribute on `CDEpisode`:** “active” is global app state (one
now-playing), not a property of every episode row.

### 2. Module layout / file boundaries

| File | Target | Status | Responsibility |
|------|--------|--------|----------------|
| `PodWash/PodWash/PodWash.xcdatamodeld` | app | **changed** | Add `CDNowPlayingSession` |
| `PodWash/PodWash/NowPlayingSessionStore.swift` | app | **new** | Read / set / clear active episode id; save on mutate |
| `PodWash/PodWash/PodcastStore.swift` | app | **changed (minimal)** | Additive lookup: episode + hosting podcast by id (bootstrap resolve) |
| `PodWash/PodWash/AppShellModel.swift` | app | **changed** | Own session store; set on play session; `restoreNowPlayingSessionIfNeeded`; flush position; dismiss hides chrome without clearing store; wire end → clear/advance |
| `PodWash/PodWash/QueueCoordinator.swift` | app | **changed (minimal)** | On `handlePlaybackEnded`: clear session when queue empty; else set session to advanced episode id (inject store **or** return next/nil for shell to apply — see §4) |
| `PodWash/PodWash/AppShellView.swift` / scene host | app | **changed (minimal)** | Call restore once at shell appear; flush position on `scenePhase` → inactive/background |
| `PodWash/PodWash/PodWashApp.swift` | app | **changed (minimal)** | Fixed in-memory identifier when Now Playing Session UITest preserve family is active (§6) |
| `PodWash/PodWash/FixtureNowPlayingSession.swift` | app | **new** | Launch args + fixed persistence id + seed/preserve policy (§6) |
| `PodWash/PodWash/RootView.swift` | app | **changed (minimal)** | Route fixture seed vs preserve (do not `clear()` on preserve relaunch) |
| `PodWash/PodWashTests/NowPlayingSessionTests.swift` | test | **new (QA)** | ACs 1–4 |
| `PodWash/PodWashUITests/NowPlayingSessionUITests.swift` | test | **new (QA)** | ACs 5–6 |

**Unchanged public APIs:** `QueueStore`, `ResumePositionStore` position/played
math (95% threshold untouched), `PlaybackEngine` transport surface, mini/full
identifiers from ADR-015 / ADR-026, CarPlay.

### 3. `NowPlayingSessionStore` API

```swift
@MainActor
final class NowPlayingSessionStore {
    init(context: NSManagedObjectContext)

    /// `nil` when no durable session row (or empty id).
    func activeEpisodeID() -> String?

    /// Upserts the singleton row to `episodeID`. No-op if already set to the same id.
    func setActiveEpisodeID(_ episodeID: String) throws

    /// Deletes the singleton row (or clears id). After this, `activeEpisodeID() == nil`.
    func clear() throws
}
```

**Binding:**

| Event | Store effect |
|-------|----------------|
| Successful play session start (`beginPlaybackSession` / equivalent when `nowPlayingEpisodeID` is assigned) | `setActiveEpisodeID(episode.id)` |
| User starts a **different** episode | `setActiveEpisodeID(newID)` |
| `handlePlaybackEnded` + queue **non-empty** (auto-advance) | `setActiveEpisodeID(nextID)` |
| `handlePlaybackEnded` + queue **empty** | `clear()` |
| `stopAndDismissPlayer` / swipe-dismiss / hide mini | **No** store change |
| Bootstrap finds id but `episodeLookup` misses | `clear()` then leave mini hidden (orphan cleanup) |

### 4. `QueueCoordinator` + clear / advance policy

Normative end handling (extends ADR-009 §5; session store is new):

Given `handlePlaybackEnded(episodeID:duration:)`:

1. Mark ended episode played / record progress (unchanged).
2. If `queueEpisodeIDs()` is **empty**:
   - `currentEpisodeID = nil`
   - **`NowPlayingSessionStore.clear()`**
   - Do not call `player.play`
3. If queue is **non-empty**:
   - Remove and advance to first id (unchanged)
   - **`NowPlayingSessionStore.setActiveEpisodeID(nextID)`**
   - `player.play(episodeID: nextID)` as today

**Injection preference:** pass `NowPlayingSessionStore` into `QueueCoordinator`
`init` alongside `queue` / `resume` / `player` so AC3–AC4 are assertable without
SwiftUI. Alternative (also ADR-compliant): `handlePlaybackEnded` returns
`advancedEpisodeID: String?` and `AppShellModel` applies set/clear — tests must
still observe the durable store after the production call path.

**Production AVPlayer end → `handlePlaybackEnded`:** wire if not already connected
so finish+empty-queue clears the session in real listens. Unit ACs call
`handlePlaybackEnded` directly (no live end-notification dependency) — same
posture as ADR-009 AC2.

**Shell UI sync on advance:** when the coordinator advances, `AppShellModel` must
update `nowPlayingEpisodeID` / titles / engine URL for the next episode when that
path runs in production. AC4 only requires the **durable** id to match the
advanced episode after the end handler; full engine URL swap for auto-advance
beyond that is not a new AC for this slice (slice OOS: mid-episode auto-advance
restore edge cases).

### 5. Shell bootstrap — pause, not play

```swift
@MainActor @Observable
final class AppShellModel {
    let nowPlayingSessionStore: NowPlayingSessionStore
    // …existing stores…

    /// Cold-start / post-relaunch: rebuild paused mini session from durable stores.
    /// Idempotent: no-op if already restored / no durable id / episode missing.
    func restoreNowPlayingSessionIfNeeded()

    /// Writes `ResumePositionStore` from the live engine clock for the active id.
    func flushPlaybackPosition()
}
```

**`restoreNowPlayingSessionIfNeeded` sequence (binding for AC2 / UI AC5):**

1. Read `id = nowPlayingSessionStore.activeEpisodeID()`; if `nil` → return
   (`isMiniPlayerVisible` stays `false`).
2. `episodeLookup(id)` via `PodcastStore`; on miss → `nowPlayingSessionStore.clear()`;
   return.
3. Resolve audio URL with the **same** rules as `playEpisode` / `beginPlaybackSession`
   (Library fixture → `FixtureAudio.bundledURL()`; else download/stream policy
   unchanged).
4. Build engine + coordinators as today (`beginPlaybackSession` shared path is
   preferred over a second paint path).
5. `seek` to `resumeStore.position(for: id)` (engine or `EpisodePlaying.seek`).
6. Set `nowPlayingEpisodeID = id`, `isMiniPlayerVisible = true`.
7. Leave transport **paused**: `engine.isPlaying == false`. **Forbidden:**
   `engine.play()`, `startPlaybackWhenReady()`, or `QueueCoordinator.playEpisode`
   on this path (those call `play`).
8. Optional: analysis `preparePlayback` may run while paused (existing
   prepare-without-auto-play). Must not flip to playing when prepare completes
   unless the user taps play.

**Assertable after restore (AC2):**

| Field | Expected |
|-------|----------|
| `isMiniPlayerVisible` | `true` |
| `nowPlayingEpisodeID` | `"fixture-ep-001"` (seeded) |
| `engine?.isPlaying` | `false` |
| Current / seek time | `127.5 ± 1.0` s |

**When to call:** once after `AppShellModel` is constructed and stores are ready
(e.g. `AppShellView.task` / `.onAppear`, or `RootView` immediately after model
init for production + Library fixture paths). Must run on cold launch **and**
UITest relaunch with preserve args. Must **not** require an episode-row tap.

**`stopAndDismissPlayer` (revised):**

1. `flushPlaybackPosition()` while engine still exists.
2. Tear down engine / coordinators; `isMiniPlayerVisible = false`;
   `isFullPlayerPresented = false`; clear in-memory `nowPlayingEpisodeID` /
   titles as needed for chrome.
3. **Do not** call `nowPlayingSessionStore.clear()`.

Same-process dismiss hides chrome; a later cold start restores mini from the
durable id (intake).

### 6. Position flush

`flushPlaybackPosition()`:

1. Resolve episode id from in-memory `nowPlayingEpisodeID`, else
   `nowPlayingSessionStore.activeEpisodeID()`.
2. If no id or no engine → return (or still persist last known if tests seed
   without engine — prefer writing only when `engine` has a readable
   `currentTime`).
3. `resumeStore.setPosition(seconds, for: id)` (tolerance budget for ACs is
   ±1.0 s after restore).

**Call sites (minimum):**

| Trigger | Notes |
|---------|--------|
| Pause via mini / full play-pause | When transitioning playing → paused |
| `stopAndDismissPlayer` | Before tearing down engine |
| Scene `inactive` / `background` | `AppShellView` / `WindowGroup` `scenePhase` |

Background return without process death needs no new product behavior beyond
flush so a subsequent kill still restores within ±1.0 s.

### 7. `PodcastStore` lookup (bootstrap)

Additive API (name may refine; semantics binding):

```swift
/// First match across subscriptions (`CDEpisode.id` is globally unique).
func episodeLookup(id: String) -> (episode: Episode, podcastTitle: String, feedURL: URL)?
```

Used only to rebuild titles + audio resolution for restore. Do not invent a
second episode identity scheme.

### 8. UITest preserve fixture

Library fixtures today use a **fresh** `uitest-library-<uuid>` per launch
(ADR-015 §6), so terminate + relaunch cannot share temp SQLite. Slice 31 needs
a **fixed-identifier** family analogous to `-UITestFixtureQueuePreserve`.

```swift
enum FixtureNowPlayingSession {
    static let launchArgument = "-UITestFixtureNowPlayingSession"
    static let preserveLaunchArgument = "-UITestFixtureNowPlayingSessionPreserve"
    /// Stable temp-SQLite key shared by both launches of the relaunch UITest.
    static let persistenceIdentifier = "uitest-now-playing-session"

    static var isEnabled: Bool { /* ProcessInfo */ }
    static var shouldPreserveOnLaunch: Bool { /* ProcessInfo */ }
}
```

**`PodWashApp` persistence binding:**

| Args | Store |
|------|--------|
| `NowPlayingSession` and/or `NowPlayingSessionPreserve` (typically with `-UITestFixtureLibrary`) | `PersistenceController.inMemory(identifier: FixtureNowPlayingSession.persistenceIdentifier)` — **fixed** |
| `-UITestFixtureLibrary` alone (other Library UITests) | Unchanged: fresh UUID per launch |
| Production | `production()` unchanged |

**Seed vs preserve:**

| Launch | Behavior |
|--------|----------|
| `-UITestFixtureLibrary` + `-UITestFixtureNowPlayingSession` | Fixed id; seed library (may `clear` + `prepareSeededStore`); test establishes session (play + position or store seed) |
| Relaunch: `-UITestFixtureLibrary` + `-UITestFixtureNowPlayingSessionPreserve` | Same fixed id; **skip** `store.clear()` / reseed; run `restoreNowPlayingSessionIfNeeded` |

UX owns exact launch-arg strings and AX wait steps in `docs/slices/slice-31-ux.md`;
Architect requires the fixed-identifier + no-wipe-on-preserve behavior above.
Pinned UITest position (e.g. **30.0** s) is a UX/fixture constant; restore
tolerance remains **±1** whole second on `playback.elapsed` (AC5).

### 9. Cross-cutting impact

| Surface | Impact |
|---------|--------|
| `AppShellModel` | Serialize with Slice 30 if both edit the same forge window |
| `QueueCoordinator` | Session clear/set on end; init signature may gain store |
| `PlaybackEngine` | **No** public API change |
| `ResumePositionStore` / 95% math | Unchanged |
| `QueueStore` | Unchanged |
| Mini / full seek chrome (ADR-026) | Unchanged; restore may show seek bar once mini is visible |
| CarPlay (ADR-016) | OOS — does not read this session yet |
| Persistence model | Additive entity; inferred migration |

### 10. Out of scope

- Auto-play on restore
- Clearing durable session via dismiss / stop
- Cross-device sync / CloudKit
- CarPlay / lock screen now-playing restore
- Changing 95% played-threshold math
- Redesigning mini / full player chrome
- Mid-episode auto-advance restore edge cases beyond: persisted queue + active id + position restore

## Consequences

- Cold start with a durable active id shows `miniPlayer` paused at the saved
  position without an episode-row tap.
- Finish + empty queue is the only product clear of the durable session;
  dismiss is chrome-only.
- QA maps ACs 1–6 to `NowPlayingSessionTests` /
  `NowPlayingSessionUITests` against the APIs above; do not invent alternate
  session keys or auto-play restore.
- Engineer must keep restore off the `QueueCoordinator.playEpisode` / `play()`
  path so AC2 / AC5 stay paused-by-default.
- Supersede this ADR (do not silently edit) if clear policy gains more triggers
  (e.g. explicit “clear now playing”) or if session state moves out of Core Data.

## Alternatives considered

| Option | Why not chosen |
|--------|----------------|
| **UserDefaults for active id only** | AC1 ties session + position + queue to one `PersistenceController` reload; splitting stores weakens the harness and invites drift. |
| **`isActive` on `CDEpisode`** | Global singleton state; multi-true risk; heavier migrations for a boolean flag. |
| **Auto-play on restore** | Explicitly locked off by intake. |
| **Clear session on `stopAndDismissPlayer`** | Intake: hide chrome vs keep session for relaunch. |
| **Reuse fresh Library UUID + production SQLite** | Library path must stay isolated; fixed temp-SQLite id matches ADR-009 reload without polluting production. |
| **Encode position on the session row** | Duplicates `ResumePositionStore` / `CDEpisode.playbackPosition`; single source of truth stays ADR-009. |
