# Task 004 — Silence overlay audio during unit tests

| Field | Value |
|-------|-------|
| **ID** | 004 |
| **Title** | Silence overlay audio during unit tests |
| **Status** | Queued |
| **Kind** | tweak |
| **Priority** | P2 |
| **Area** | `PodWash/PodWash/OverlayEngine.swift`, `PodWash/PodWashTests/OverlaySyncTests.swift` |
| **Crux** | `scripts/verify.sh` (full or filtered) produces **no audible** beep/quack/episode overlay through Mac speakers while overlay sync ACs still pass. |

## Outcome

**Current:** `OverlaySyncTests` drive production `OverlayEngine`, which plays bundled `beep.wav` / `quack.wav` via `AVAudioPlayer` at full volume. Every full-suite / Mechanic verify emits loud beeps through the host speakers (distracting on video calls even when the change under test is unrelated to audio).

**Desired:** Under XCTest, overlay playback is silent (player volume **0**, or a silent injectable player double) while event/timing/RMS asserts remain unchanged. Offline energy path stays offline (already silent).

**Framing:** If overlay tests pass with zero host-audible output, we never need to mute the Mac or skip verify during calls.

## Acceptance criteria

- [ ] 1. When `OverlayEngine` starts overlay under XCTest (mode `.beep` or `.quack`), the active `AVAudioPlayer.volume` is **0.0** (or no real `AVAudioPlayer` is used — silent double only).
- [ ] 2. `PodWashTests/OverlaySyncTests/testOverlayStartSync()` still passes with existing sync tolerances (±0.050 s) and start counts.
- [ ] 3. `PodWashTests/OverlaySyncTests/testOverlayEndAndExteriorSilence()`, `testOverlaySettingRespected()`, and `testSeekResync()` still pass with existing event/count asserts unchanged.
- [ ] 4. `PodWashTests/OverlaySyncTests/testOfflineRenderOverlayEnergy()` remains offline (software mix only) — no speaker path.

## Surgical test scope

| AC# | Test id | New? |
|-----|---------|------|
| 1 | `PodWashTests/OverlaySyncTests/testOverlayPlayerSilentUnderXCTest()` | yes |
| 2 | `PodWashTests/OverlaySyncTests/testOverlayStartSync()` | no |
| 3 | `PodWashTests/OverlaySyncTests/testOverlayEndAndExteriorSilence()` | no |
| 3 | `PodWashTests/OverlaySyncTests/testOverlaySettingRespected()` | no |
| 3 | `PodWashTests/OverlaySyncTests/testSeekResync()` | no |
| 4 | `PodWashTests/OverlaySyncTests/testOfflineRenderOverlayEnergy()` | no |

## Authorized test changes

- `PodWashTests/OverlaySyncTests.swift` — **add** `testOverlayPlayerSilentUnderXCTest` asserting overlay output is silent under XCTest; **do not** weaken sync tolerances, event counts, asset IDs, or RMS thresholds on existing ACs.

## Depends on

- None

## Out of scope

- Path-filtering / skipping overlay tests when audio files are untouched (separate ticket if desired).
- Muting non-overlay `AVPlayer` sine fixtures beyond what is required for overlay silence.
- Changing production default `muteOverlayMode` or Settings UX.
- Forge Floor pause/stop behavior (see task 005).

## Human checklist

- (none — automatable tweak)

## Verification record

> Loop writes `VERIFY RESULT:` here. For tasks, `tier=2` and `filtered=1` are valid for Done.

```
VERIFY RESULT: (pending)
```
