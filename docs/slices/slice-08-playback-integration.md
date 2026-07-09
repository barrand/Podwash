# Slice 08 — Playback integration (intervals → mute/skip)

| Field | Value |
|-------|-------|
| **ID** | 08 |
| **Title** | Playback integration |
| **Status** | Done |
| **Crux** | Cached intervals from the analysis pipeline drive `IntervalScheduler` during playback; switching mute ↔ skip reconfigures the player **without re-running analysis**. |

## PRD / spec references

- PRD §3 — Skip or mute (user choice); instant action switching
- `docs/adr/000-foundations.md` §1–§3 — audioMix, offline-render verification, local files
- `docs/adr/005-analysis-pipeline.md` — pipeline + cache consumed here
- `docs/adr/002-interval-scheduler.md` — ramp placement for AC1 boundary asserts

## Goal

Close the loop: analyzed episode plays with live mute/skip from its cached interval list.

## Deliverables

- `EpisodeAnalyzing` protocol + `PlaybackCoordinator` wiring: `IntervalCache` / `AnalysisPipeline` → `IntervalSchedule` → `PlaybackEngine.applySchedule` (ADR-006)
- Per-episode `CensorAction` applied at playback via `setAction` without re-analysis
- `PlaybackIntegrationTests` + `AudioMixRampInspector` test helper
- Decision recorded: `docs/adr/006-playback-integration.md`

## Fixture strategy (pinned)

| Asset | Path | Role |
|-------|------|------|
| Injected transcript | `PodWash/PodWashTests/Fixtures/transcripts/spec-section8.input.json` | Slice 02/07 §8 fixture — drives pipeline intervals |
| Golden bounds | `PodWash/PodWashTests/Fixtures/analysis/e2e_intervals.json` | `[{0.92, 1.87}, {2.92, 3.32}]` — cross-check pipeline output |
| Episode ID | `"fixture-spec-section8"` | Stable cache key (Slice 07) |
| Audio (engine tests) | `sine-300hz-5s.wav` copied to temp URL | Local file for `PlaybackEngine` + offline render (fits 5 s bounds) |
| Audio (pipeline shape) | `speech-pangram.wav` path as dummy URL | Ignored when transcript injected |
| Empty-interval target | `{ "nonexistenttoken" }` | AC4 — matcher returns `[]` |

## Depends on

- Slices 04, 07

**Parallelizable:** No.

## Out-of-scope

- Progress UI / toggles UI (Slice 09)
- Beep/quack overlay (Slice 16)
- Streamed assets (local files only — ADR-000 §3)
- Re-running ASR/matcher on action toggle

## Acceptance criteria

Automatable only. **XCTSkip is not allowed on core ACs.**

- [x] 1. Integration test: after `preparePlayback` with injected §8 transcript and `action: .mute`, the player's `audioMix` mute ramp boundaries match cached interval `start`/`end` each within **±0.001 s** (down-ramp ends at `start`, up-ramp starts at `end` per ADR-002 §4).
- [x] 2. Offline-render test: pipeline-produced intervals on `sine-300hz-5s.wav` satisfy Slice 04 RMS thresholds — interior windows (inset **0.030 s**) RMS **< 0.01**, exterior windows (≥ **0.030 s** from boundaries) RMS **> 0.25**.
- [x] 3. Unit test: after initial `preparePlayback`, toggling mute → skip → mute reconfigures `activeSchedule` actions; pipeline analyze spy and ASR spy record **0** additional calls during toggles.
- [x] 4. Unit test: episode with target set matching no tokens → `audioMix == nil`; `play()` then `pause()` does not crash.
- [x] 5. Full suite green via `scripts/verify.sh` (**exit 0, failed 0, skipped 0**).

## Verification mapping

| AC# | Test file | Test method | Notes |
|-----|-----------|-------------|-------|
| 1 | `PodWash/PodWashTests/PlaybackIntegrationTests.swift` | `testCachedIntervalsConfigureAudioMix` | `AudioMixRampInspector` extracts onset/release boundaries; compares vs pipeline intervals ±0.001 s |
| 2 | `PodWash/PodWashTests/PlaybackIntegrationTests.swift` | `testOfflineRenderMeetsRMSThresholds` | `OfflineRenderRMS` with pipeline-returned intervals on sine fixture; Slice 04 interior/exterior thresholds |
| 3 | `PodWash/PodWashTests/PlaybackIntegrationTests.swift` | `testActionToggleNoReanalysis` | `PipelineAnalyzeSpy` + `ASRSpyTranscriber`; counts frozen after initial prepare |
| 4 | `PodWash/PodWashTests/PlaybackIntegrationTests.swift` | `testNoIntervalsPlaysNormally` | Empty target set; asserts nil mix + play/pause survival |
| 5 | — | — | Command-level: unfiltered `scripts/verify.sh` |

## Verification commands

```bash
scripts/verify.sh -only-testing:PodWashTests/PlaybackIntegrationTests   # inner loop
scripts/verify.sh                                                       # Done gate
```

## Verification record (QA fills at Verify)

```
VERIFY RESULT: exit=0 total=35 passed=35 failed=0 skipped=0 filtered=0 bundle=build/test-results/verify-20260709-091801.xcresult
```

Full unfiltered `scripts/verify.sh` run 2026-07-09 (simulator resolved dynamically). All 35 tests
(4 new Slice-08 tests + prior suite) passed, 0 failed, 0 skipped.

## Plan review record (coordinator fills before downstream roles)

```
ADR review (2026-07-09): QA cleared — ACs offline via injection + spies; AC2 reuses OfflineRenderRMS + sine fixture (ADR-002 empirical backing); AC1 ramp inspector reads commanded mix geometry; no circular golden from coordinator code. PM cleared — scope matches deliverables/out-of-scope; AC thresholds numeric; crux single hypothesis; no PRD §11 halt.
Test spec review (2026-07-09): Architect cleared — tests exercise ADR-006 public API (`PlaybackCoordinator`, `EpisodeAnalyzing`, `PipelineAnalyzeSpy`); AC1 uses `AudioMixRampInspector`; AC2 reuses `OfflineRenderRMS`; spy counts match AC3; temp cache dirs per test.
```

## Done gate

- [x] Every AC mapped to a test; all rows filled
- [x] **Full suite green:** unfiltered `scripts/verify.sh` exit 0, failed 0, skipped 0
- [x] Verification record pasted above
- [x] Auto-commit on green: `slice-08: playback integration`

## Role artifacts

| Role | Gate | Artifact path |
|------|------|---------------|
| PM | Required | `docs/slices/slice-08-playback-integration.md` (this file) |
| Architect | Required | `docs/adr/006-playback-integration.md` — Accepted |
| UX | Waived | — (no new SwiftUI screens) |
| QA | Required | `PodWash/PodWashTests/PlaybackIntegrationTests.swift`, `AudioMixRampInspector.swift` |
| Engineer | Required | `PodWash/PodWash/PlaybackCoordinator.swift`, `EpisodeAnalyzing.swift` |
