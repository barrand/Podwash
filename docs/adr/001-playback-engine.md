# ADR-001 — Playback engine module boundaries

| Field | Value |
|-------|-------|
| **Status** | Accepted |
| **Date** | 2026-07-08 |
| **Supersedes** | — |
| **Builds on** | [ADR-000](000-foundations.md) §1 (AVPlayer), §3 (local files only) |

## Context

Slice 03 needs a minimal player shell that is fully assertable in CI: play/pause/seek
state, Now Playing metadata writes, and a UI-test fixture mode. ADR-000 mandates
`AVPlayer` for playback and injected doubles for system frameworks. This ADR defines
module boundaries so Slice 04 (interval mute) can attach `AVMutableAudioMix` to the
same engine without redesign.

## Decision

### Module layout

| File | Responsibility |
|------|----------------|
| `PodWash/PlaybackEngine.swift` | Wraps `AVPlayer` + `AVPlayerItem`; exposes `@Observable` playback state derived from `timeControlStatus`; play/pause/seek API; optional `NowPlayingInfoUpdating` injection |
| `PodWash/NowPlayingInfoUpdating.swift` | Protocol + production `MPNowPlayingInfoCenter` adapter |
| `PodWash/PlaybackControlsView.swift` | Minimal SwiftUI chrome: play/pause, ±15 s seek buttons, elapsed label |
| `PodWash/FixtureAudio.swift` | Launch-argument detection (`-UITestFixtureAudio`) and bundled fixture URL resolution |
| `PodWash/Fixtures/audio/test-clip.m4a` | App-bundle copy of the test clip (UI tests cannot read the unit-test bundle) |
| `PodWashTests/Fixtures/audio/test-clip.m4a` | Unit-test bundle copy of the same clip |
| `PodWashTests/PlaybackEngineTests.swift` | KVO expectation, seek accuracy, Now Playing double |
| `PodWashUITests/PlaybackControlsUITests.swift` | Fixture-mode UI flow |

### `PlaybackEngine` public API (sketch)

```swift
@MainActor @Observable
final class PlaybackEngine {
    var isPlaying: Bool          // derived from timeControlStatus == .playing
    var currentTime: TimeInterval
    var duration: TimeInterval

    init(
        url: URL,
        title: String,
        artist: String,
        nowPlayingUpdater: NowPlayingInfoUpdating = MPNowPlayingInfoCenterUpdater()
    )

    func play()
    func pause()
    func seek(to seconds: TimeInterval)
    func seek(by delta: TimeInterval)   // ±15 s buttons
}
```

- State observation uses KVO on `AVPlayer.timeControlStatus` (and periodic time observer for `currentTime` in UI only).
- `play()` calls `player.play()` then pushes title/artist/duration to the injected `NowPlayingInfoUpdating`.
- Local file URLs only (ADR-000 §3); no remote/stream loading in this slice.

### `NowPlayingInfoUpdating`

```swift
protocol NowPlayingInfoUpdating: AnyObject {
    func updateNowPlayingInfo(
        title: String,
        artist: String,
        duration: TimeInterval,
        elapsed: TimeInterval
    )
}
```

Production: `MPNowPlayingInfoCenterUpdater` writes `[String: Any]` to `MPNowPlayingInfoCenter.default()`.
Tests: `NowPlayingInfoRecorder` (in test target) captures the last call — **never assert on the real center**.

### Fixture mode

When `ProcessInfo.processInfo.arguments` contains `-UITestFixtureAudio`:

1. App resolves `Bundle.main.url(forResource: "test-clip", withExtension: "m4a", subdirectory: "Fixtures/audio")`.
2. App creates a `PlaybackEngine` with fixed metadata (`title: "Fixture Clip"`, `artist: "PodWash Tests"`).
3. `PlaybackControlsView` is shown as the root content (replacing the template list for UI tests).

Unit tests load the clip from `Bundle(for: PlaybackEngineTests.self)` instead.

### Scheme: parallel UI tests off

`PodWash.xcscheme` sets `parallelizable = "NO"` on the `PodWashUITests` testable reference.
Audio playback and shared simulator audio session do not tolerate parallel clones.

### Out of scope (this ADR)

- `AVMutableAudioMix` attachment (Slice 04)
- Remote command handlers / lock-screen transport (Slice 14)
- Queue, variable speed, sleep timer (Slices 11–12)

## Consequences

- Slice 04 adds `audioMix` to `PlaybackEngine` without changing the play/pause/seek surface.
- Any change to `PlaybackEngine`'s public API blocks Slices 04, 08, 14 — coordinate via superseding ADR.
- UI tests depend on launch argument + app-bundle fixture; the test-bundle copy is for unit tests only.
- Verification remains KVO/expectation and accessibility asserts — no realtime audio listening.
