# Slice 14 — Lock screen / Control Center / background audio

| Field | Value |
|-------|-------|
| **ID** | 14 |
| **Title** | Lock screen / Control Center / background audio |
| **Status** | Done |
| **Crux** | `MPRemoteCommandCenter` transport handlers (play/pause/seek/±15 s skip) forward to `PlaybackEngine` through injectable doubles, Now Playing elapsed/duration stay within **±0.25 s** of engine state after each transport change, and the app declares `.playback` / `.spokenAudio` session plus `UIBackgroundModes` audio. |

## PRD / spec references

- PRD §2 — Playback controls; native media controls (lock screen, Control Center, Bluetooth/headset)
- PRD §7 — `MPNowPlayingInfoCenter`, `MPRemoteCommandCenter`
- `docs/adr/000-foundations.md` §1 — AVPlayer; injected doubles for system frameworks
- `docs/adr/001-playback-engine.md` — `PlaybackEngine`, `NowPlayingInfoUpdating`

## Goal

PodWash exposes standard lock-screen and Control Center transport controls and keeps Now Playing metadata in sync so playback continues with the screen off, matching PRD §2 native-controls requirements.

## Deliverables

- `PodWash/RemoteCommandHandling.swift` — protocol wrapping `MPRemoteCommandCenter` command targets; production adapter + test double that programmatically fires each command handler
- `PodWash/AudioSessionConfiguring.swift` — protocol + production `AVAudioSession` adapter (refactor inline `AudioSessionConfigurator` from `PlaybackEngine.swift`); injectable test double recording category/mode/active calls
- `PodWash/RemoteCommandCoordinator.swift` — registers play/pause/skip-forward/skip-backward/change-playback-position handlers against a `PlaybackEngine` (or thin transport protocol); invoked from app bootstrap
- Extend `PlaybackEngine` — call `updateNowPlaying()` on **pause** and after **seek** completes (today only `play()` pushes metadata); optional injection of `AudioSessionConfiguring`
- Extend `NowPlayingInfoUpdating` / `NowPlayingInfoRecorder` if needed so tests can read the **last** elapsed/duration without asserting on real `MPNowPlayingInfoCenter`
- `PodWash/Info.plist` — add `audio` to `UIBackgroundModes` (currently only `remote-notification`)
- `PodWash/PodWashTests/RemoteCommandTests.swift`
- `PodWash/PodWashTests/BackgroundAudioTests.swift`
- Architect note: `docs/adr/011-remote-commands-background-audio.md` (light ADR — module boundaries + double contract)

## Fixture strategy (pinned)

| Asset | Path | Role |
|-------|------|------|
| Unit-test clip | `PodWash/PodWashTests/Fixtures/audio/test-clip.m4a` | **30.0 s** AAC sine (provenance: `test-clip.provenance.md`); duration + seek/skip asserts |
| Now Playing double | `NowPlayingInfoRecorder` in `PlaybackEngineTests.swift` (reuse or extend) | AC3 elapsed/duration capture |
| Transport spy | New `PlaybackTransportSpy` conforming to play/pause/seek surface under test | AC1 handler invocation counts |
| Info.plist | Built `PodWash.app` bundle inside test host | AC4 structural `UIBackgroundModes` read |

## Depends on

- Slice 03 — `PlaybackEngine`, `NowPlayingInfoUpdating`, ±15 s `seek(by:)` buttons
- Slice 08 — `PlaybackCoordinator` / interval playback unchanged; remote commands must not re-run analysis

**Parallelizable:** Yes — with Slices 12, 13 (parallel group B/C boundary; no shared SwiftUI chrome files with 13).

**Implicit (kanban, not parsed as deps):** Slice 11 queue exists in production wiring; this slice does **not** add queue next/previous remote commands (see out-of-scope).

## Out-of-scope

- CarPlay templates and entitlements (Slice 15)
- Queue **nextTrack** / **previousTrack** remote commands and lock-screen queue UI (follow-up; Slice 11 deferral — transport + metadata only here)
- Variable speed / sleep timer on `MPRemoteCommandCenter` (Slice 12 controls stay in-app only)
- Artwork / `MPMediaItemPropertyArtwork` (no PRD gate; title/artist/duration/elapsed only)
- Bluetooth/route-change / phone-call interruption polish beyond activating `.playback` once on play
- Live lock-screen UI screenshots or physical headset button tests (simulator doubles only)
- Subjective “controls feel native” review

## Acceptance criteria

Automatable only. **XCTSkip is not allowed on core ACs** — a mapped test that cannot run must fail.

- [ ] 1. Unit test (`RemoteCommandCoordinator`, injected command-center double + `PlaybackTransportSpy`, fixture duration **30.0 s**, starting `currentTime` **20.0 s**): programmatically fire each handler — **play**, **pause**, **skipForward** (+15 s), **skipBackward** (−15 s), **changePlaybackPosition** (target **10.0 s**) — and assert the spy records exactly **1** matching call per fire (`play` count +1, `pause` count +1, `seek(to:)` target **10.0 ± 0.25 s**, `seek(by:)` delta **+15.0 ± 0.25 s** effective target **30.0 ± 0.25 s**, `seek(by:)` delta **−15.0 ± 0.25 s** effective target **5.0 ± 0.25 s**).
- [ ] 2. Unit test (`AudioSessionConfiguring` double): after coordinator bootstrap + first `play()`, recorded category is **`.playback`**, mode is **`.spokenAudio`**, and `setActive(true)` call count is **≥ 1**.
- [ ] 3. Unit test (`PlaybackEngine` + `NowPlayingInfoRecorder`, `test-clip.m4a`): after `play()` → `pause()` → `seek(to: 10.0)`, the recorder captures **≥ 3** updates and, after each step, `abs(lastElapsed - engine.currentTime) <= 0.25` and `abs(lastDuration - 30.0) <= 0.25`.
- [ ] 4. Unit test (bundle structural): read the test-host app `Info.plist`; `UIBackgroundModes` array contains the string **`audio`** (exactly **1** occurrence).
- [ ] 5. Full suite green via `scripts/verify.sh` (**exit 0, failed 0, skipped 0**).

## Verification mapping

| AC# | Test file | Test method | Notes |
|-----|-----------|-------------|-------|
| 1 | `PodWash/PodWashTests/RemoteCommandTests.swift` | `testRemoteHandlersInvokeTransportSpy` | Five handler fires; spy counts **1** each; pinned 20.0 s → 30.0 / 5.0 / 10.0 s targets ±0.25 s |
| 2 | `PodWash/PodWashTests/BackgroundAudioTests.swift` | `testSessionCategoryPlaybackSpokenAudio` | Injected session double; `.playback` + `.spokenAudio`; active ≥ 1 |
| 3 | `PodWash/PodWashTests/RemoteCommandTests.swift` | `testNowPlayingElapsedTracksTransport` | `test-clip.m4a` 30.0 s; ≥ 3 updates; ±0.25 s elapsed/duration |
| 4 | `PodWash/PodWashTests/BackgroundAudioTests.swift` | `testBackgroundModeDeclared` | Parse built app plist; `audio` present once |
| 5 | — | — | Command-level: unfiltered `scripts/verify.sh` |

## Verification commands

```bash
# Fast inner loop (NOT sufficient for Done):
scripts/verify.sh -only-testing:PodWashTests/RemoteCommandTests -only-testing:PodWashTests/BackgroundAudioTests

# Done gate — FULL suite, zero failures, zero skips:
scripts/verify.sh
```

## Verification record (QA fills at Verify)

```
VERIFY RESULT: exit=0 total=65 passed=65 failed=0 skipped=0 filtered=0 bundle=build/test-results/verify-20260710-151904.xcresult tier=3 class=tests
```

## Plan review record (coordinator fills before downstream roles)

```
ADR review (2026-07-10): (pending) QA cleared — pipeline worker finished PM cleared — pipeline worker finished
Test spec review (2026-07-10): Architect cleared — pipeline worker finished
```

## Done gate

- [ ] Every AC mapped to a test; all rows in the mapping table filled
- [ ] **Full suite green:** unfiltered `scripts/verify.sh` exit 0, failed 0, skipped 0
- [ ] Verification record pasted above (exit code + counts + `.xcresult` path)
- [ ] Auto-commit made on green: `slice-14: <short description>` (push only when the user asks)

## Role artifacts

| Role | Gate | Artifact path |
|------|------|---------------|
| Architect | Light | `docs/adr/011-remote-commands-background-audio.md` — module boundaries + double contract |
| UX | Waived | — (system UI; no new SwiftUI screens) |
