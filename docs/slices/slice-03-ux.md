# Slice 03 — UX spec: Player shell

| Field | Value |
|-------|-------|
| **Slice** | 03 — Player shell |
| **Screen** | `PlaybackControlsView` (fixture mode root; future: playback chrome overlay) |

## Layout

Vertical stack, centered:

1. **Elapsed time** — monospaced label, `mm:ss` format
2. **Transport row** — three buttons: Seek back 15 s | Play/Pause | Seek forward 15 s

No scrub slider in this slice (sliders are flaky in XCUITest).

## States

| State | Elapsed label | Play/Pause button | accessibilityValue |
|-------|---------------|-------------------|--------------------|
| Paused at 0:00 | `0:00` | Play icon | `paused` |
| Playing | updates each second | Pause icon | `playing` |
| Paused mid-clip | frozen at last second | Play icon | `paused` |

## Accessibility identifiers

| Control | `accessibilityIdentifier` | `accessibilityLabel` | `accessibilityValue` |
|---------|---------------------------|----------------------|----------------------|
| Play/Pause | `playback.playPause` | `Play` or `Pause` (matches action) | `playing` or `paused` |
| Seek back 15 s | `playback.seekBack15` | `Seek back 15 seconds` | — |
| Seek forward 15 s | `playback.seekForward15` | `Seek forward 15 seconds` | — |
| Elapsed time | `playback.elapsed` | `Elapsed time` | elapsed seconds as decimal string (e.g. `0`, `15`, `30`) |

The elapsed `accessibilityValue` is a plain numeric string of whole seconds so UI tests can compare before/after seek without parsing `mm:ss`.

## Fixture mode

Launch argument: `-UITestFixtureAudio`

App loads bundled `test-clip.m4a`, shows `PlaybackControlsView` immediately (no navigation required).

## UI test scenarios

1. **Launch with fixture** — `XCUIApplication` launched with `-UITestFixtureAudio`; wait for `playback.playPause` to exist.
2. **Play** — tap `playback.playPause`; assert `accessibilityValue == "playing"`.
3. **Pause** — tap `playback.playPause` again; assert `accessibilityValue == "paused"`.
4. **Seek forward** — note `playback.elapsed` `accessibilityValue` as `before`; tap `playback.seekForward15`; assert `accessibilityValue` as `Int` is ≥ `before + 15` (or exactly `before + 15` when clip length allows).

Mapped test: `PlaybackControlsUITests.testPlayPauseSeekButtons`.
