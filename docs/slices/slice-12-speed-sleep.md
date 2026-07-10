# Slice 12 — Variable speed + sleep timer

| Field | Value |
|-------|-------|
| **ID** | 12 |
| **Title** | Variable speed + sleep timer |
| **Status** | Ready |
| **Crux** | Discrete playback-rate changes apply to `AVPlayer.rate` without remapping media-timeline mute ramp boundaries, and a sleep timer with an injectable `Clock` pauses playback exactly once on deadline — all assertable without wall-clock waits. |

## PRD / spec references

- PRD §2 — Variable speed (0.75x–3x), sleep timer
- PRD §3 — Playback behaves normally through native controls (scrub, speed) with cleaning active
- `docs/adr/000-foundations.md` §1–§2 — AVPlayer; offline-render RMS verification
- `docs/adr/001-playback-engine.md` — `PlaybackEngine` surface extended here (supersede via ADR if public API changes)
- `docs/adr/002-interval-scheduler.md` — ramp boundary geometry reused for AC2
- `docs/adr/006-playback-integration.md` — cached intervals → `audioMix` (unchanged)

## Goal

Deliver table-stakes variable speed and sleep timer on the existing player shell so listeners can speed up episodes and stop playback after a preset duration without breaking interval-driven mute.

## Deliverables

- `PlaybackEngine` rate API — discrete supported rates **`[0.75, 1.0, 1.25, 1.5, 2.0, 3.0]`**; `setRate(_:)` and/or `cycleRate()`; persists selected rate across play/pause within the session (no cross-launch persistence — Slice 13)
- `SleepTimer` (or equivalent) — injectable **`Clock`** / scheduler; presets **`[900, 1800, 3600]`** s (15 / 30 / 60 min); `arm(seconds:)`, `extend(by:)`, `cancel()`; on fire calls `PlaybackEngine.pause()` exactly once
- `Clock` protocol + `TestClock` double (monotonic `now`, `advance(by:)` for unit tests)
- Player UI controls on `PlaybackControlsView` (or shared playback chrome) with accessibility identifiers:
  - `speedButton` — cycles supported rates; `accessibilityValue` is rate as decimal string (`"0.75"` … `"3.0"`)
  - `sleepTimerButton` — cycles timer presets; `accessibilityValue` is `"off"` or armed preset seconds (`"900"`, `"1800"`, `"3600"`)
- Reuse Slice 08 helpers: `AudioMixRampInspector`, `OfflineRenderRMS`, `sine-300hz-5s.wav`
- `PodWash/PodWashTests/PlaybackRateTests.swift`
- `PodWash/PodWashTests/SleepTimerTests.swift`
- Extend `PodWash/PodWashUITests/PlaybackControlsUITests.swift` (fixture mode `-UITestFixtureAudio`, parallelization off per Slice 03)

## Fixture strategy (pinned)

| Asset | Path | Role |
|-------|------|------|
| Sine tone | `PodWash/PodWashTests/Fixtures/audio/sine-300hz-5s.wav` | AC2 offline render (Slice 04 provenance) |
| Mute interval | `[(1.0, 1.5)]` on the sine fixture | AC2 ramp-boundary + RMS windows |
| Unit-test clip | `PodWash/PodWashTests/Fixtures/audio/test-clip.m4a` | AC1 rate asserts on real `AVPlayer` |
| UI fixture | Launch arg `-UITestFixtureAudio` | AC4–AC5 UI tests (Slice 03) |

## Depends on

- Slice 03 — `PlaybackEngine`, `PlaybackControlsView`, fixture-mode launch arg
- Slice 08 — interval → `audioMix` wiring; `AudioMixRampInspector` ±0.001 s boundary asserts

**Parallelizable:** Yes — with Slices 10, 11 (parallel group B after Slice 08). No queue, download, or persistence behavior changes.

## Out-of-scope

- Persisting default or last-selected speed across launches (Slice 13 settings)
- Lock screen / `MPRemoteCommandCenter` speed or sleep surfacing (Slice 14)
- End-of-episode sleep mode, custom minute entry, or slider-based speed scrub (discrete controls only — Slice 03 UX precedent)
- Trim-silence / voice boost / beep-quack overlay (Slices 16+)
- Changing `IntervalScheduler` ramp math or re-running analysis on rate change
- Wall-clock `Task.sleep` / `XCTestExpectation` waits for timer fire in unit tests (injected clock only)
- Subjective “sounds natural at 2x” listening sessions

## Acceptance criteria

Automatable only. **XCTSkip is not allowed on core ACs** — a mapped test that cannot run must fail.

- [ ] 1. Unit test (`PlaybackEngine`, `test-clip.m4a`): for each rate in **`[0.75, 1.0, 1.25, 1.5, 2.0, 3.0]`**, after `play()` and `setRate(r)`, `abs(avPlayer.rate - r) <= 0.001` while `timeControlStatus == .playing`.
- [ ] 2. Unit test (`PlaybackEngine` + `IntervalScheduler`): apply mute schedule **`[(1.0, 1.5)]`** on `sine-300hz-5s.wav`, set rate **`2.0`**, play; `AudioMixRampInspector` onset/release boundaries match **`1.0`** and **`1.5`** each within **±0.001 s**; offline render at rate **1.0** (mix unchanged) satisfies Slice 04 thresholds — interior windows (inset **0.030 s**) RMS **< 0.01**, exterior windows (≥ **0.030 s** from boundaries) RMS **> 0.25**.
- [ ] 3. Unit test (`SleepTimer`, injected `TestClock`): arm **`60.0`** s at **`T = 0`** while engine spy reports playing — advance to **`T = 59.9`** → pause call count **`0`**; advance to **`T = 60.0`** → pause call count **`1`**; fresh arm, extend **`+120.0`** s at **`T = 30.0`** → no pause through **`T = 149.9`**, exactly **`1`** pause at **`T = 150.0`**; fresh arm, **`cancel()`** at **`T = 30.0`** → pause count **`0`** through **`T = 300.0`**.
- [ ] 4. UI test (`-UITestFixtureAudio`): starting from default rate **`1.0`** (`speedButton` `accessibilityValue == "1.0"`), **6** consecutive taps cycle values **`"1.25"` → `"1.5"` → `"2.0"` → `"3.0"` → `"0.75"` → `"1.0"`** in order (wrap after `"3.0"`).
- [ ] 5. UI test (`-UITestFixtureAudio`): `sleepTimerButton` `accessibilityValue == "off"` at launch; **3** consecutive taps assert values **`"900"` → `"1800"` → `"3600"`** in order (preset cycle **`off → 900 → 1800 → 3600 → off`**).
- [ ] 6. Full suite green via `scripts/verify.sh` (**exit 0, failed 0, skipped 0**).

## Verification mapping

| AC# | Test file | Test method | Notes |
|-----|-----------|-------------|-------|
| 1 | `PodWash/PodWashTests/PlaybackRateTests.swift` | `testSupportedRatesMatchAVPlayer` | Loop 6 rates; ±0.001 while `.playing` |
| 2 | `PodWash/PodWashTests/PlaybackRateTests.swift` | `testRateDoesNotShiftMuteIntervals` | Boundaries ±0.001 s at 2.0x; `OfflineRenderRMS` Slice 04 thresholds |
| 3 | `PodWash/PodWashTests/SleepTimerTests.swift` | `testTimerFireExtendCancel` | `TestClock` + pause spy; pinned 60.0 / 120.0 / 300.0 s |
| 4 | `PodWash/PodWashUITests/PlaybackControlsUITests.swift` | `testSpeedButtonCyclesRates` | 6 taps; assert accessibilityValue sequence |
| 5 | `PodWash/PodWashUITests/PlaybackControlsUITests.swift` | `testSleepTimerButtonCyclesPresets` | 3 taps from off; assert 900 → 1800 → 3600 |
| 6 | — | — | Command-level: unfiltered `scripts/verify.sh` exit 0, failed 0, skipped 0 |

## Verification commands

```bash
# Fast inner loop (NOT sufficient for Done):
scripts/verify.sh -only-testing:PodWashTests/PlaybackRateTests -only-testing:PodWashTests/SleepTimerTests -only-testing:PodWashUITests/PlaybackControlsUITests

# Done gate — FULL suite, zero failures, zero skips:
scripts/verify.sh
```

## Verification record (QA fills at Verify)

> Paste the `VERIFY RESULT:` line from the full-suite `scripts/verify.sh` run here.
> A slice without a recorded full-suite green artifact is not Done.

```
VERIFY RESULT: (pending)
```

## Plan review record (coordinator fills before downstream roles)

> Record readonly review outcomes before QA writes tests (ADR review) and before
> Engineer starts (test spec review). No record = next role must not spawn.
> See [`multitask-workflow.md`](../multitask-workflow.md) § Plan review gates.

```
ADR review: waived (extends ADR-001 engine API; no new modules — coordinator records rationale)
Test spec review (2026-07-10): Architect cleared — pipeline worker finished
```

## Done gate

- [ ] Every AC mapped to a test; all rows in the mapping table filled
- [ ] **Full suite green:** unfiltered `scripts/verify.sh` exit 0, failed 0, skipped 0
- [ ] Verification record pasted above (exit code + counts + `.xcresult` path)
- [ ] Auto-commit made on green: `slice-12: <short description>` (push only when the user asks)

## Role artifacts

| Role | Gate | Artifact path |
|------|------|---------------|
| PM | Required | `docs/slices/slice-12-speed-sleep.md` (this file) |
| Architect | Waived | — (extends existing `PlaybackEngine`; supersede ADR-001 only if public API contract changes materially) |
| UX | Waived | — (identifiers + cycle contracts inline in Deliverables; optional ux.md not required) |
| QA | Required | `PlaybackRateTests.swift`, `SleepTimerTests.swift`, `PlaybackControlsUITests` extensions |
| Engineer | Required | `PlaybackEngine` rate API, `SleepTimer` + `Clock`, player UI controls |
