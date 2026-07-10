# ADR-011 — Remote commands + background audio

| Field | Value |
|-------|-------|
| **Status** | Accepted |
| **Date** | 2026-07-10 |
| **Supersedes** | — |
| **Builds on** | [ADR-000](000-foundations.md) §1 (AVPlayer; injected doubles for system frameworks); [ADR-001](001-playback-engine.md) (`PlaybackEngine`, `NowPlayingInfoUpdating`); [ADR-002](002-interval-scheduler.md) (public seek surface unchanged; interval skip stays internal) |
| **Slice** | [slice-14-background-audio.md](../slices/slice-14-background-audio.md) |

## Context

Slice 14 delivers PRD §2 / §7 native media controls: lock screen, Control Center,
and headset transport via `MPRemoteCommandCenter`, with Now Playing elapsed/duration
kept in sync, plus an audio background mode so playback continues with the screen
off.

ADR-001 already injects `NowPlayingInfoUpdating` and pushes metadata on `play()`
only. Today `AudioSessionConfigurator` (private enum in `PlaybackEngine.swift`)
activates `.playback` with mode **`.default`** — Slice 14 AC2 requires
**`.spokenAudio`**. `Info.plist` declares `UIBackgroundModes` with only
`remote-notification`; AC4 requires `audio`.

Constraints:

- Never assert on live `MPRemoteCommandCenter` / `MPNowPlayingInfoCenter` /
  lock-screen UI — injectable doubles only (ADR-000 / ADR-001).
- Remote handlers must forward to the existing play/pause/seek surface; they must
  **not** re-run analysis or touch `PlaybackCoordinator` (Slice 08).
- Queue next/previous remote commands, artwork, rate/sleep remote commands, and
  CarPlay are out of scope (Slices 11 deferral, 12, 15).

**Numbering note:** Slice 14’s draft path said `010-…`; ADR-010 is already
Settings ([ADR-010](010-settings-word-lists.md)). This decision is **011**.

## Decision

### 1. Module layout

| File | Target | Status | Responsibility |
|------|--------|--------|----------------|
| `PodWash/PodWash/RemoteCommandHandling.swift` | app | **new** | Protocol wrapping remote-command registration; production `MPRemoteCommandCenter` adapter |
| `PodWash/PodWash/AudioSessionConfiguring.swift` | app | **new** | Protocol + production `AVAudioSession` adapter; replaces inline `AudioSessionConfigurator` |
| `PodWash/PodWash/RemoteCommandCoordinator.swift` | app | **new** | Registers play/pause/±15 s skip / change-position handlers; binds active transport |
| `PodWash/PodWash/PlaybackTransporting.swift` | app | **new** | Thin play/pause/seek protocol for remote → engine forwarding (test spy seam) |
| `PodWash/PodWash/PlaybackEngine.swift` | app | **changed (additive)** | Inject `AudioSessionConfiguring`; call `updateNowPlaying()` on **pause** and after **finished** public seek; delete inline `AudioSessionConfigurator` |
| `PodWash/PodWash/NowPlayingInfoUpdating.swift` | app | **unchanged API** | Protocol signature stays; production adapter unchanged |
| `PodWash/PodWash/Info.plist` | app | **changed** | Add `audio` to `UIBackgroundModes` (keep `remote-notification`) |
| App bootstrap (`PodWashApp` / `RootView`) | app | **changed (minimal)** | Construct coordinator, `activate()`, `bind` when an engine exists |
| `PodWash/PodWashTests/RemoteCommandTests.swift` | test | **new (QA)** | AC1, AC3 |
| `PodWash/PodWashTests/BackgroundAudioTests.swift` | test | **new (QA)** | AC2, AC4 |
| `NowPlayingInfoRecorder` in `PlaybackEngineTests.swift` | test | **extend** | Capture `lastElapsed` / `lastDuration` / update count (AC3) |

**Unchanged:** `PlaybackCoordinator`, analysis pipeline, interval schedule attachment,
`PlaybackPausing` (sleep timer), queue next/previous, SwiftUI chrome beyond bootstrap
wiring.

### 2. `PlaybackTransporting` (spy seam)

Separate from `PlaybackPausing` (Slice 12 — pause-only). Do **not** widen
`PlaybackPausing`.

```swift
@MainActor
protocol PlaybackTransporting: AnyObject {
    func play()
    func pause()
    func seek(to seconds: TimeInterval, completion: (() -> Void)?)
    func seek(by delta: TimeInterval)
}
```

- `PlaybackEngine` conforms (existing methods already match).
- Tests: `PlaybackTransportSpy` records call counts and last `seek(to:)` /
  `seek(by:)` arguments (and effective target = start + delta when the spy is
  seeded with `currentTime` **20.0** and duration **30.0** for AC1).

### 3. `RemoteCommandHandling` + production adapter

```swift
@MainActor
protocol RemoteCommandHandling: AnyObject {
    func installPlayHandler(_ handler: @escaping () -> MPRemoteCommandHandlerStatus)
    func installPauseHandler(_ handler: @escaping () -> MPRemoteCommandHandlerStatus)
    func installSkipForwardHandler(
        interval: TimeInterval,
        _ handler: @escaping () -> MPRemoteCommandHandlerStatus
    )
    func installSkipBackwardHandler(
        interval: TimeInterval,
        _ handler: @escaping () -> MPRemoteCommandHandlerStatus
    )
    func installChangePlaybackPositionHandler(
        _ handler: @escaping (_ position: TimeInterval) -> MPRemoteCommandHandlerStatus
    )
}
```

**Production** (`MPRemoteCommandCenterAdapter`):

- Targets `MPRemoteCommandCenter.shared()`.
- Enables play, pause, skipForward, skipBackward, changePlaybackPosition.
- Sets skip `preferredIntervals` to `[NSNumber(value: 15)]` (matches in-app ±15 s).
- Disables / leaves unset: nextTrack, previousTrack, changePlaybackRate, seek
  forward/backward continuous, rating, bookmark (out of scope).

**Test double** (`RemoteCommandCenterDouble` in test target):

- Stores the installed closures.
- Exposes `firePlay()`, `firePause()`, `fireSkipForward()`, `fireSkipBackward()`,
  `fireChangePlaybackPosition(to:)` that invoke those closures — **no** real
  `MPRemoteCommandCenter`.

### 4. `RemoteCommandCoordinator`

```swift
@MainActor
final class RemoteCommandCoordinator {
    init(commands: any RemoteCommandHandling)

    /// Registers handlers once on the command-center seam.
    func activate()

    /// Bind/rebind the active engine (or spy). Handlers no-op with
    /// `.noActionableNowPlayingItem` when unbound.
    func bind(_ transport: (any PlaybackTransporting)?)
}
```

**Handler → transport mapping (binding for AC1):**

| Remote command | Transport call |
|----------------|----------------|
| play | `play()` |
| pause | `pause()` |
| skipForward | `seek(by: +15)` |
| skipBackward | `seek(by: -15)` |
| changePlaybackPosition | `seek(to: position)` |

Return `.success` when a transport is bound; otherwise `.noActionableNowPlayingItem`.
Handlers must not call analysis, downloads, or queue APIs.

**Bootstrap:** `activate()` from app launch (e.g. `PodWashApp.init` or
`RootView` appear). Call `bind(engine)` whenever the active `PlaybackEngine` is
created or replaced (fixture player today; future episode player owner later).
Re-bind is cheap; do not require tearing down MediaPlayer targets.

### 5. `AudioSessionConfiguring`

```swift
protocol AudioSessionConfiguring: AnyObject {
    func activatePlaybackSession()
}
```

**Production** (`AVAudioSessionPlaybackConfigurator`):

```swift
session.setCategory(.playback, mode: .spokenAudio)
session.setActive(true)
```

Errors may be swallowed with `try?` (same posture as today’s configurator) —
AC2 asserts the **recorded** category/mode/active calls on the double, not
throwing behavior.

**Refactor:** Remove `enum AudioSessionConfigurator` from `PlaybackEngine.swift`.
`PlaybackEngine.play()` calls the injected `AudioSessionConfiguring` (default
production instance). Optional init parameter for tests.

**Test double:** records `category`, `mode`, `setActive(true)` call count.

### 6. Now Playing sync (PlaybackEngine additive)

Extend ADR-001 behavior without changing the `NowPlayingInfoUpdating` signature:

| Event | Push `updateNowPlaying()`? |
|-------|----------------------------|
| `play()` | **yes** (existing) |
| `pause()` | **yes** (new) — after `refreshCurrentTime()` |
| Public `seek(to:)` when `finished == true` | **yes** (new) — after `refreshCurrentTime()` |
| `seek(by:)` | covered via `seek(to:)` |
| Internal `skipSeek` (interval skip) | **yes** (recommended) for lock-screen elapsed; not required by AC3 |

`NowPlayingInfoRecorder` (test target) must retain **last** `elapsed` and
`duration` plus an update count so AC3 can assert
`abs(lastElapsed - engine.currentTime) <= 0.25` and
`abs(lastDuration - 30.0) <= 0.25` after play → pause → `seek(to: 10.0)`
(≥ 3 updates).

### 7. Background mode (`Info.plist`)

```xml
<key>UIBackgroundModes</key>
<array>
    <string>remote-notification</string>
    <string>audio</string>
</array>
```

AC4 reads the **built** test-host app bundle plist and asserts the string `audio`
appears **exactly once**.

### 8. Empirical validation

| Claim | How verified (no live lock screen) |
|-------|--------------------------------------|
| Remote handlers invoke transport | `RemoteCommandCenterDouble.fire*` + `PlaybackTransportSpy` counts/targets ±0.25 s (AC1) |
| Session category/mode | `AudioSessionConfiguring` double records `.playback` / `.spokenAudio` / active ≥ 1 (AC2) |
| Now Playing elapsed/duration | `NowPlayingInfoRecorder` vs engine state ±0.25 s (AC3); never real `MPNowPlayingInfoCenter` |
| Background audio entitlement | Structural plist read for `audio` (AC4) |

No spike step: MediaPlayer command registration and `AVAudioSession` category APIs
are deterministic under doubles; CI does not need a physical headset or Control
Center screenshot. If production adapter wiring fails at runtime, symptoms are
outside the automated gate — doubles remain the Done criterion.

## Cross-cutting impact

| Surface | Impact |
|---------|--------|
| `PlaybackEngine` | Additive init injection + Now Playing on pause/seek; **blocks** parallel edits to the same methods (serialize with any other engine slice) |
| `NowPlayingInfoUpdating` | API unchanged; recorder fields extended in **tests only** |
| `PlaybackCoordinator` / analysis | **None** |
| `PlaybackPausing` / sleep timer | **None** |
| SwiftUI chrome | Bootstrap bind only; no new screens (UX waived) |
| Slice 15 CarPlay | Will reuse Now Playing + remote command center; do not add CarPlay entitlements here |

## Consequences

- Lock-screen / Control Center transport is assertable without MediaPlayer UI.
- Spoken-audio session mode replaces `.default` for podcast-appropriate routing.
- Background `audio` mode is declared; interruption/route-change polish stays deferred.
- Slice 15 can attach CarPlay templates to the same Now Playing / command-center
  stack without redesigning `PlaybackEngine`’s transport surface.
