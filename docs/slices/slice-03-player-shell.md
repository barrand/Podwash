# Slice 03 — Player shell

| Field | Value |
|-------|-------|
| **ID** | 03 |
| **Title** | Player shell |
| **Status** | Done |
| **Crux** | `PlaybackEngine` (AVPlayer) plays a bundled local clip with play/pause/seek assertable deterministically: KVO/expectation on `timeControlStatus`, injected Now Playing double, and a launch-argument fixture mode for UI tests. |

## PRD / spec references

- PRD §2 — Core podcast features (playback controls — partial)
- PRD §6 — Act at playback (`AVPlayer`, native controls)
- `docs/adr/000-foundations.md` §1, §3 — AVPlayer architecture; local-file scope

## Goal

Play a bundled local test audio file with standard controls and fully testable playback state.

## Deliverables

- `PlaybackEngine` wrapping `AVPlayer`; exposes observable state derived from `timeControlStatus`
- `NowPlayingInfoUpdating` protocol wrapping `MPNowPlayingInfoCenter`; production conformance + injected test double
- Minimal play / pause / seek UI with **discrete seek buttons** (±15 s) — no slider scrub in UI tests (sliders are flaky in XCUITest)
- Small committed `.m4a` clip (< 1 MB) in `PodWash/PodWashTests/Fixtures/audio/`, with a copy or reference usable by the app's fixture mode
- **App-side launch-argument fixture mode** (e.g. `-UITestFixtureAudio`): app loads the bundled fixture clip into the player at launch. This is an explicit deliverable because UI tests cannot read the unit-test bundle.
- `PlaybackEngineTests`, `PlaybackControlsUITests`
- Test plan / scheme setting: **parallel testing disabled** for `PodWashUITests` (audio + fixture state don't tolerate parallel clones)

## Depends on

- Slice 01

**Parallelizable:** Yes — parallel with Slices 02, 05, 06 after Slice 01.

## Out-of-scope

- Interval mute/skip (Slice 04)
- Streaming/remote URLs (local files only — ADR-000 §3)
- Downloads, queue, variable speed, sleep timer (Slices 10–12)
- Lock screen / remote commands beyond the Now Playing title write (Slice 14)

## Acceptance criteria

- [x] 1. Unit test: given the bundled clip, `PlaybackEngine.play()` reaches `timeControlStatus == .playing` within 5 s, asserted via KVO-driven `XCTestExpectation` (no polling sleeps).
- [x] 2. Unit test: `seek(to:)` updates `currentTime` within ±0.25 s of the target.
- [x] 3. Unit test: after play starts, the **injected `NowPlayingInfoUpdating` double** receives title and artist (no assertion on the real `MPNowPlayingInfoCenter`).
- [x] 4. UI test (launched with the fixture-mode argument): tap play → assert play button `accessibilityValue` flips to "playing"; tap pause → flips back; tap +15 s seek button → elapsed-time label's accessibility value increases.
- [x] 5. UI tests run with parallelization disabled in the scheme/test plan (structural check: scheme file setting).
- [x] 6. Full suite green via `scripts/verify.sh`.

## Verification mapping

| AC# | Test file | Test method | Notes |
|-----|-----------|-------------|-------|
| 1 | `PodWash/PodWashTests/PlaybackEngineTests.swift` | `testPlayReachesPlayingViaKVOExpectation` | KVO on `avPlayer.timeControlStatus`, 5 s timeout |
| 2 | `PodWash/PodWashTests/PlaybackEngineTests.swift` | `testSeekUpdatesCurrentTime` | ±0.25 s tolerance |
| 3 | `PodWash/PodWashTests/PlaybackEngineTests.swift` | `testNowPlayingDoubleReceivesMetadata` | `NowPlayingInfoRecorder` double |
| 4 | `PodWash/PodWashUITests/PlaybackControlsUITests.swift` | `testPlayPauseSeekButtons` | `-UITestFixtureAudio` launch argument |
| 5 | `PodWash/PodWashTests/PlaybackEngineTests.swift` | `testUITestTargetParallelizationDisabledInScheme` | Regex on `PodWash.xcscheme` TestableReference |
| 6 | — | `scripts/verify.sh` (full suite) | Command-level |

## Verification commands

```bash
# Fast inner loop:
scripts/verify.sh -only-testing:PodWashTests/PlaybackEngineTests -only-testing:PodWashUITests/PlaybackControlsUITests

# Done gate — FULL suite:
scripts/verify.sh
```

## Verification record (QA fills at Verify)

```
VERIFY RESULT: exit=0 total=13 passed=13 failed=0 skipped=0 filtered=0 bundle=build/test-results/verify-20260708-202910.xcresult
```

## Done gate

- [x] Every AC mapped to a test; all rows filled
- [x] **Full suite green:** unfiltered `scripts/verify.sh` exit 0, failed 0, skipped 0
- [x] Verification record pasted above
- [x] Auto-commit on green: `slice-03: <short description>`

## Role artifacts

| Role | Gate | Artifact path |
|------|------|---------------|
| Architect | Required | [`docs/adr/001-playback-engine.md`](../adr/001-playback-engine.md) |
| UX | Required (minimal chrome) | [`docs/slices/slice-03-ux.md`](slice-03-ux.md) — play/pause/seek buttons only |
