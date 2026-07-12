# Slice 24 — Production analysis wiring (phone dogfood)

| Field | Value |
|-------|-------|
| **ID** | 24 |
| **Title** | Production analysis wiring (phone dogfood) |
| **Status** | Done |
| **Crux** | When the production composition root plays a downloaded episode with cleaning enabled, it runs the real `AnalysisPipeline` (not `InstantEpisodeAnalyzer`) with the Settings active target-word set, so `preparePlayback` yields non-empty censor intervals for a fixture transcript that contains known targets — and applies them to `PlaybackEngine`. |

> **Placement:** MVP closure slice — wires the verified cleaning engine into the installable app shell so physical-device dogfood can mute profanity on downloaded episodes. Blocks meaningful phone testing until **Done**.

## Product decisions (resolved — do not re-litigate)

| Decision | Choice |
|----------|--------|
| Analysis timing | **First play with cleaning enabled** → one-time ASR/match → cache until episode deleted (PRD §11 / Slice 13) |
| Default word profile | Profanity F/S/D + racial/hate slurs **ON** (`SettingsStore.activeNormalizedTargetSet()`) |
| Default action | **Mute** (`SettingsStore.censorAction()`) |
| ASR stack | WhisperKit `openai_whisper-tiny.en` @ pinned HF revision (ADR-003) |
| Mute guarantee | **Downloaded local files only** (ADR-000 §3 / ADR-008) — no cleaned playback on streaming-only URL |
| Model provisioning (this slice) | Ship pinned `tiny.en` as **app-bundle resource** (or one-time copy from bundled archive into Application Support) — **offline after install**; no first-run HuggingFace download UX |
| UITest fixture modes | Keep `InstantEpisodeAnalyzer` / stepped analyzers for launch-argument fixtures only |

## PRD / spec references

- PRD §6 — Analyze once → interval list; cache until episode deleted
- PRD §11 — Analysis timing, default word profile, default mute action (resolved 2026-07-10)
- `docs/adr/000-foundations.md` §3 — download-before-clean-listen; §6 — simulator Done gate
- `docs/adr/003-asr-stack-choice.md` — WhisperKit tiny.en pin, cpuOnly simulator path
- `docs/adr/005-analysis-pipeline.md` — `AnalysisPipeline`, `IntervalCache`, injection seam
- `docs/adr/006-playback-integration.md` — `PlaybackCoordinator.preparePlayback`
- `docs/adr/008-episode-downloads.md` — local file required for cleaned playback
- `docs/adr/010-settings-word-lists.md` — `activeNormalizedTargetSet()`, settings → playback seam
- `docs/adr/015-app-shell-navigation.md` — `AppShellModel.playEpisode`, fixture vs production analyzer
- `docs/specs/matching-spec.md` §8 — hand-computed golden intervals for injected-transcript tests

## Goal

Wire the production app composition root to the real analyze → cache → `preparePlayback` stack with Settings-derived target words and a bundled on-device WhisperKit model, so downloaded episodes with cleaning enabled produce and apply censor intervals — verifiable in XCTest without manual device listening.

## Deliverables

- **ADR-020** — `docs/adr/020-production-analysis-composition.md`: production analyzer factory, model-in-bundle policy, IPA size note, fixture vs production branching, injectable test seam (Architect authors)
- **Model availability for installable app:**
  - Pinned `openai_whisper-tiny.en` (same HF revision as `scripts/setup-asr-models.sh`: `97a5bf9bbc74c7d9c12c755d04dea59e672e3808`) available at runtime on device and simulator
  - App-target resolver (e.g. `WhisperModelLocator.swift` or ADR-named equivalent) returning a folder URL with all **3** required Core ML bundles (`AudioEncoder.mlmodelc`, `TextDecoder.mlmodelc`, `MelSpectrogram.mlmodelc`)
  - Bundle resource and/or documented build copy step (Architect decides: committed bundle subset vs build-phase copy from gitignored `Models/` after `setup-asr-models.sh`)
- **Production composition wiring:**
  - Replace production `InstantEpisodeAnalyzer()` in `AppShellModel.playEpisode` with real `AnalysisPipeline(transcriber: WhisperKitASRTranscriber(...), cache: IntervalCache(...))` when **not** in UITest fixture modes
  - Pass `settingsStore.activeNormalizedTargetSet()`, `settingsStore.censorAction()`, and settings-derived `UnrelatedContentOptions` into `preparePlayback`
  - Honor `CleaningToggleStore`: run analysis/`preparePlayback` only when **episode cleaning OR channel cleaning** is enabled **and** resolved audio is a **local downloaded file** (per ADR-008)
  - Share the same production analyzer instance (or factory) with `LibraryPodcastDetailView` / `AnalysisUIViewModel` so episode-row analysis is not left on the Slice 09 stub
  - Keep `InstantEpisodeAnalyzer` / stepped analyzers for `-UITestFixture*` launch paths (`RootView`, fixture feed/analysis/timeline modes)
- **Tests (QA):**
  - `PodWash/PodWashTests/ProductionAnalysisWiringTests.swift` (or ADR-named equivalent) — composition-root wiring with injectable `EpisodeAnalyzing` spy / injected transcript (no live ASR in fast suite)
  - Optional slow coverage: bundled-model smoke in `PodWashSlowTests` (nightly; **not** a Done gate)
- **Docs:** this slice file; row in `docs/slices/README.md` index

## Fixture strategy (pinned — QA / Engineer)

| Asset | Path | Role |
|-------|------|------|
| Injected transcript | `PodWash/PodWashTests/Fixtures/transcripts/spec-section8.input.json` | Known targets `{ "shit", "damn" }` — reuse Slice 07 provenance |
| Golden intervals | `PodWash/PodWashTests/Fixtures/analysis/e2e_intervals.json` | **Exactly 2** intervals; ±0.0005 s tolerance (hand-computed, not pipeline output) |
| Target word set (test pin) | `{ "shit", "damn" }` | Subset of default profile; explicit in spy assert |
| Sine audio fixture | `PodWash/PodWashTests/Fixtures/audio/sine-300hz-5s.wav` | Offline `audioMix` boundary asserts (Slice 08 pattern) |
| Downloaded-file stand-in | Temp copy of bundled `.wav` under injectable downloads directory | Satisfies local-file gate without network |
| ASR spy / pipeline spy | Test target only | Records `analyze` call count and `targetWords` argument — **no** live WhisperKit in fast ACs |

## Depends on

- Slice 07 — `AnalysisPipeline`, `IntervalCache`, injection seam
- Slice 08 — `PlaybackCoordinator.preparePlayback`, offline mix asserts
- Slice 13 — `SettingsStore.activeNormalizedTargetSet()`, default profile + actions
- Slice 23 — `AppShellModel`, production shell play path
- Slice 05 (indirect) — `WhisperKitASRTranscriber`, model pin in `scripts/setup-asr-models.sh`

**Parallelizable:** No — central composition-root change; must follow Slice 23 **Done**. Unblocks phone dogfood; does not block deferred Slice 17.

## Out-of-scope

- Larger Whisper models / ANE compute tuning beyond ADR-003
- SpeechAnalyzer real-device evaluation
- StoreKit / paywall
- First-run HuggingFace model download UX or progress UI for model fetch
- Streaming cleaned playback (still download-first)
- Changing matching algorithm or word lists
- CarPlay-specific analysis UX
- New analysis progress / timeline UI polish (Slices 09/20 views already exist — reuse when wired)
- Manual listening or physical-device verification as a Done gate
- Live WhisperKit on full episodes in the **fast** Done suite

## Open product questions

None — PRD §11 analysis timing, default profile, mute action, and model-in-bundle policy for phone dogfood are resolved above. Coordinator halt-and-ask only if user overrides first-run download UX.

## Acceptance criteria

Automatable only. **XCTSkip is not allowed on core ACs** — a mapped test that cannot run must fail with a clear setup message.

- [ ] 1. Unit test (`WhisperModelLocator` or ADR equivalent): resolved bundled model folder contains **exactly 3** required subdirectories (`AudioEncoder.mlmodelc`, `TextDecoder.mlmodelc`, `MelSpectrogram.mlmodelc`); test **FAILS** (not skip) if any is missing, citing `scripts/setup-asr-models.sh` / ADR-020 setup steps.
- [ ] 2. Unit test (production factory, non-fixture mode): composition root returns an analyzer that is **not** `InstantEpisodeAnalyzer` (type or behavior assert per ADR-020 seam).
- [ ] 3. Unit test (`AppShellModel` + injectable pipeline spy, cleaning **disabled**): after `playEpisode`, spy `analyze` call count **== 0** and `playbackCoordinator?.cachedIntervals.count == 0`.
- [ ] 4. Unit test (`AppShellModel` + spy, episode cleaning **enabled**, **local** audio file, injected §8 transcript): after `playEpisode` + await prepare task, spy records **exactly 1** `analyze` call with `targetWords` **set-equal** to `settingsStore.activeNormalizedTargetSet()`; `cachedIntervals.count == 2`; each interval `start`/`end` equals `e2e_intervals.json` within **±0.0005 s**.
- [ ] 5. Unit test (same as AC4 + offline mix): after prepare, `PlaybackEngine` mute ramp boundaries match cached interval bounds each within **±0.001 s** (Slice 08 / `AudioMixRampInspector` pattern).
- [ ] 6. Unit test (`AppShellModel` + spy, **channel** cleaning enabled, episode cleaning **disabled**, local file): spy `analyze` call count **== 1** (cleaning applies at channel scope).
- [ ] 7. Unit test (`AppShellModel` + spy, cleaning enabled, **streaming-only** URL — no local download): spy `analyze` call count **== 0** (ADR-008 local-file gate).
- [ ] 8. Unit test (fixture mode `-UITestFixtureLibrary` / `FixtureLibrary.isEnabled`): `playEpisode` path uses stub analyzer — spy or type assert shows **no** production `AnalysisPipeline` invocation; `cachedIntervals.count == 0`.
- [ ] 9. Full suite green via `scripts/verify.sh` with **exit 0, failed 0, skipped 0**.

## Verification mapping

| AC# | Test file | Test method | Notes |
|-----|-----------|-------------|-------|
| 1 | `PodWash/PodWashTests/ProductionAnalysisWiringTests.swift` | `testBundledWhisperModelFolderIsComplete` | WhisperModelLocator vs app bundle; fails until build-phase model copy |
| 2 | `PodWash/PodWashTests/ProductionAnalysisWiringTests.swift` | `testProductionAnalyzerIsNotInstantStub` | `ProductionAnalyzerFactory` + `makeDefaultAnalyzer(fixtureLibraryMode: false)` |
| 3 | `PodWash/PodWashTests/ProductionAnalysisWiringTests.swift` | `testPlayEpisodeSkipsAnalysisWhenCleaningOff` | Episode + channel cleaning off; spy count 0 |
| 4 | `PodWash/PodWashTests/ProductionAnalysisWiringTests.swift` | `testPlayEpisodePreparesIntervalsWithSettingsTargetSet` | Pinned `{shit, damn}` settings; §8 transcript; ±0.0005 s |
| 5 | `PodWash/PodWashTests/ProductionAnalysisWiringTests.swift` | `testPlayEpisodeAppliesMuteScheduleToEngine` | `AudioMixRampInspector` ramp boundaries ±0.001 s |
| 6 | `PodWash/PodWashTests/ProductionAnalysisWiringTests.swift` | `testChannelCleaningTriggersAnalysisOnPlay` | Channel on via `feedURL`; episode off |
| 7 | `PodWash/PodWashTests/ProductionAnalysisWiringTests.swift` | `testStreamingURLSkipsAnalysisEvenWhenCleaningOn` | Remote enclosure only; local-file gate |
| 8 | `PodWash/PodWashTests/ProductionAnalysisWiringTests.swift` | `testFixtureLibraryModeKeepsInstantAnalyzer` | Injected spy + `fixtureLibraryModeForTesting = true`; factory Instant assert |
| 9 | — | — | Command-level: unfiltered `scripts/verify.sh` exit 0, failed 0, skipped 0 |

## Verification commands

```bash
# Fast inner loop (NOT sufficient for Done):
scripts/verify.sh \
  -only-testing:PodWashTests/ProductionAnalysisWiringTests

# Slow optional — bundled model live transcribe smoke (NOT a Done gate):
scripts/setup-asr-models.sh
PODWASH_SCHEME=PodWashSlowTests VERIFY_ALLOW_SKIPS=1 scripts/verify.sh \
  -only-testing:PodWashSlowTests/ProductionAnalysisSlowTests

# Done gate — FULL suite, zero failures, zero skips:
scripts/verify.sh
```

## Verification record (QA fills at Verify)

> Paste the `VERIFY RESULT:` line from the full-suite `scripts/verify.sh` run here.
> A slice without a recorded full-suite green artifact is not Done.

```
VERIFY RESULT: exit=0 total=127 passed=127 failed=0 skipped=0 filtered=0 bundle=build/test-results/verify-20260711-180941.xcresult tier=3 class=tests
```

AC mapping (AC1–AC8 → `ProductionAnalysisWiringTests`) unchanged; AC9 satisfied by this run.

## Plan review record (coordinator fills before downstream roles)

> Record readonly review outcomes before QA writes tests (ADR review) and before
> Engineer starts (test spec review). No record = next role must not spawn.
> See [`multitask-workflow.md`](../multitask-workflow.md) § Plan review gates.

```
ADR review: 2026-07-11 — QA + PM readonly on ADR-020.
  PM: Clear (recommendations only — Product-table / AC wording hygiene; ADR binding).
  QA: initially Blocked on AC8; Architect added `fixtureLibraryModeForTesting` /
  `isFixtureLibraryMode` + CI `setup-asr-models.sh` note. QA re-check: **Clear**.
  UX: waived (reuse Slice 09/20 UI).
Test spec review: 2026-07-11 — Architect readonly.
  Initially Blocked: AC8 vacuous spy (`useInjectedSpy: false`). QA rewrote
  `testFixtureLibraryModeKeepsInstantAnalyzer` (inject spy + fixture mode + cleaning on
  → analyzeCallCount == 0; separate Instant factory assert). Architect re-check: **Clear for Engineer**.
```

## Done gate

- [x] Every AC mapped to a test; all rows in the mapping table filled
- [ ] **Full suite green:** unfiltered `scripts/verify.sh` exit 0, failed 0, skipped 0
- [ ] Verification record pasted above (exit code + counts + `.xcresult` path)
- [ ] Split commits: `slice-24: test spec` (tests only) then `slice-24: implement` (app + ADR) — `scripts/check-test-isolation.sh --staged` before each commit
- [ ] Auto-commit made on green: `slice-24: production analysis wiring` (push only when the user asks)

## Role artifacts

| Role | Gate | Artifact path |
|------|------|---------------|
| PM | Required | `docs/slices/slice-24-production-analysis-wiring.md` (this file) |
| Architect | Required | `docs/adr/020-production-analysis-composition.md` |
| UX | Waived | — (reuse Slice 09/20 analysis UI; no new screens) |
| QA | Required | `PodWash/PodWashTests/ProductionAnalysisWiringTests.swift` (+ optional slow test) |
| Engineer | Required | `AppShellModel.swift`, `AppShellView.swift`, model locator + bundle resources, production analyzer factory |
