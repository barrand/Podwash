# Task 018 — Silence UITest host audio during full verify

| Field | Value |
|-------|-------|
| **ID** | 018 |
| **Title** | Silence UITest host audio during full verify |
| **Status** | Done |
| **Done at** | 2026-07-15T14:47:00Z |
| **Kind** | bug |
| **Priority** | P0 |
| **Area** | `PodWash/PodWash/HostAudioSilence.swift`, `PodWash/PodWash/PlaybackEngine.swift`, `PodWash/PodWash/OverlayEngine.swift`, `PodWash/PodWashTests/HostAudioSilenceTests.swift`, `PodWash/PodWashTests/PlaybackEngineTests.swift` |
| **Crux** | Tier-3 `scripts/verify.sh` (including UITests) produces **no host-audible** episode or overlay audio through Mac speakers while existing playback/overlay ACs still pass. |

## Outcome

**Observed:** Task-004/017 only silence when `XCTestConfigurationFilePath` is set (unit-test host). FULL-VERIFY UITests launch the real app process **without** that env var, so `-UITestFixtureAudio`, SkipOverride auto-play, Library play, etc. still blast tones/beeps through host speakers (blocker on day-job / video calls).

**Expected:** Any launch with a `-UITest*` argument (or `PODWASH_SILENCE_HOST_AUDIO=1`, or XCTest host) mutes episode `AVPlayer` (`isMuted` + volume 0) and overlay `AVAudioPlayer` (volume 0). Production launches without those signals stay audible.

**Framing:** If detection covers UITest args, idle FULL-VERIFY never needs Mac mute or Floor Pause for audio.

## Acceptance criteria

- [ ] 1. `HostAudioSilence.shouldSilence` returns **true** for XCTest env, any `-UITest*` argument, and `PODWASH_SILENCE_HOST_AUDIO=1`; **false** for a normal app argv with empty silence signals.
- [ ] 2. Under XCTest, `PlaybackEngine`’s `AVPlayer` has `isMuted == true` and `volume == 0` before and after `play()` on the sine fixture.
- [ ] 3. Existing `PodWashTests/OverlaySyncTests/testOverlayPlayerSilentUnderXCTest()` still passes (overlay volume 0 under silence).
- [ ] 4. Production path: `shouldSilence(environment: [:], arguments: ["PodWash"])` is **false** (no accidental mute of shipping builds).

## Surgical test scope

| AC# | Test id | New? |
|-----|---------|------|
| 1, 4 | `PodWashTests/HostAudioSilenceTests` (class suite) | yes |
| 2 | `PodWashTests/PlaybackEngineTests/testPlayerMutedUnderXCTest()` | extend |
| 3 | `PodWashTests/OverlaySyncTests/testOverlayPlayerSilentUnderXCTest()` | no |

## Authorized test changes

- `PodWashTests/HostAudioSilenceTests.swift` — **add** class with AC1/AC4 cases.
- `PodWashTests/PlaybackEngineTests.swift` — **extend** `testPlayerMutedUnderXCTest` to assert `volume == 0`.
- Do **not** weaken overlay sync tolerances, event counts, or offline RMS thresholds.

## Depends on

- None

## Out of scope

- Forge Floor mute UI.
- Muting Mac system volume from `verify.sh`.
- Changing production default `muteOverlayMode`.
- Task-004/017 unit-host silence (already Done; this ticket covers the UITest gap).

## Human checklist

- (none — automatable)

## Verification record

> Loop writes `VERIFY RESULT:` here. For tasks, `tier=2` and `filtered=1` are valid for Done.

```
VERIFY RESULT: exit=0 total=6 passed=6 failed=0 skipped=0 filtered=1 bundle=build/test-results/verify-20260715-084602.xcresult tier=3 class=tests
```
