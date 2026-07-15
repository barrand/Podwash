# Task 017 — Silence episode audio during unit tests

| Field | Value |
|-------|-------|
| **ID** | 017 |
| **Title** | Silence episode audio during unit tests |
| **Status** | In Progress |
| **Kind** | tweak |
| **Priority** | P1 |
| **Area** | `PodWash/PodWash/PlaybackEngine.swift`, `PodWash/PodWashTests/PlaybackEngineTests.swift`, `PodWash/PodWashTests/_OverlaySyncSpike.swift` |
| **Crux** | `scripts/verify.sh` (full or filtered) produces **no host-audible** episode sine / spike beep through Mac speakers while existing playback sync and offline RMS ACs still pass. |

## Outcome

**Current:** Task-004 silenced overlay `AVAudioPlayer` (beep/quack) under XCTest. Episode playback still uses a real `AVPlayer` on fixtures such as `sine-300hz-5s.wav` (`PlaybackEngine.play()`), and leftover `_OverlaySyncSpike` plays a full-volume 1 kHz beep via raw `AVAudioPlayer`. Full-suite / idle FULL-VERIFY therefore blasts loud tones through the host speakers (blocker on video calls). App Settings “Mute overlay sound” does not affect these tests.

**Desired:** Under XCTest (`XCTestConfigurationFilePath` set, same pattern as `OverlayEngine.silenceOverlayForTests`), `PlaybackEngine`’s `AVPlayer` is muted (`isMuted == true` and/or volume 0) before any `play()`. Delete or silence `_OverlaySyncSpike` so it cannot emit host audio. Offline render / RMS paths stay offline (already silent). Existing transport, overlay-sync, and energy asserts remain unchanged.

**Framing:** If verify can run with zero host-audible episode or spike audio, we never need to mute the Mac or Pause the Floor during calls.

## Acceptance criteria

- [ ] 1. When `PlaybackEngine` is constructed / plays under XCTest, the underlying `AVPlayer.isMuted` is **true** (or equivalent zero host output — no audible sine through speakers).
- [ ] 2. New surgical test `PodWashTests/PlaybackEngineTests/testPlayerMutedUnderXCTest()` asserts AC1 (muted before/after `play()` on the sine fixture).
- [ ] 3. Existing `PodWashTests/PlaybackEngineTests` transport/time asserts and `PodWashTests/OverlaySyncTests/testOverlayPlayerSilentUnderXCTest()` still pass with unchanged tolerances / counts.
- [ ] 4. `_OverlaySyncSpike` is **removed** from the test target (delete the throwaway file, or exclude it so it is not compiled) — no remaining full-volume `AVAudioPlayer` spike path in `PodWashTests`.
- [ ] 5. Offline RMS / energy tests that do not use host `AVPlayer` playback remain offline-only (no speaker path regression).

## Surgical test scope

| AC# | Test id | New? |
|-----|---------|------|
| 1–2 | `PodWashTests/PlaybackEngineTests/testPlayerMutedUnderXCTest()` | yes |
| 3 | `PodWashTests/PlaybackEngineTests` (existing class suite) | no |
| 3 | `PodWashTests/OverlaySyncTests/testOverlayPlayerSilentUnderXCTest()` | no |
| 4 | (file removal / target exclusion — verified by spike file absent from compiled sources) | yes |
| 5 | `PodWashTests/OverlaySyncTests/testOfflineRenderOverlayEnergy()` | no |

## Authorized test changes

- `PodWashTests/PlaybackEngineTests.swift` — **add** `testPlayerMutedUnderXCTest`; do **not** weaken existing transport/time asserts.
- `PodWashTests/_OverlaySyncSpike.swift` — **delete** (or remove from the PodWashTests synchronized group) — throwaway spike marked for deletion after ADR-017 measurement.
- Do **not** weaken OverlaySync sync tolerances, event counts, or offline RMS thresholds.

## Depends on

- None

## Out of scope

- Forge Floor mute UI / `controls.json` sound toggle.
- Production Settings `muteOverlayMode` defaults or UX.
- Path-filtering / skipping audio tests when fixtures are untouched.
- Changing offline RMS numeric thresholds.
- Overlay beep/quack silence (already Done as task-004).

## Human checklist

- (none — automatable tweak)

## Verification record

> Loop writes `VERIFY RESULT:` here. For tasks, `tier=2` and `filtered=1` are valid for Done.

```
VERIFY RESULT: exit=0 total=12 passed=12 failed=0 skipped=0 filtered=1 bundle=build/test-results/verify-20260715-083038.xcresult tier=2 class=tests
```
