# Slice 28 — Device Whisper base.en (lean dual-SDK pin)

| Field | Value |
|-------|-------|
| **ID** | 28 |
| **Title** | Device Whisper base.en (lean dual-SDK pin) |
| **Status** | Implemented |
| **Crux** | Device (`iphoneos`) builds analyze with bundled `openai_whisper-base.en`; simulator builds keep `openai_whisper-tiny.en`; cache cannot reuse pre-upgrade `tiny` intervals/transcripts after pin change — all assertable on simulator via pin injection, fingerprint miss, and wipe tests without live TAL or device listening. |

## PRD / spec references

- PRD §6 / §11 — on-device ASR (ADR-003 pinned `tiny.en` for simulator verifiability; larger models deferred to real-device)
- `docs/adr/000-foundations.md` §6 — Done = simulator `scripts/verify.sh`
- `docs/adr/003-asr-stack-choice.md` — `tiny.en` + `cpuOnly` for simulator; `base.en`+ empty on CPU-only sim
- `docs/adr/020-production-analysis-composition.md` — bundled model copy + `WhisperModelLocator`
- `docs/adr/005-analysis-pipeline.md` — `IntervalCache` fingerprint tokens
- `docs/adr/022-transcript-cache.md` — episode-keyed transcript files
- Task-019 (Done) — TAL 981 @ ~2:07 ASR token **`Buck`** (escalate model, do not bend mute tests)

## Goal

Improve on-device swear recall by shipping WhisperKit **`base.en` on device** while keeping **`tiny.en` on simulator** so dark-factory verify stays green.

## Product decisions (resolved at intake — do not re-litigate)

| Decision | Choice |
|----------|--------|
| Device (`iphoneos`) model | `openai_whisper-base.en` |
| Simulator model | `openai_whisper-tiny.en` |
| Bundle policy | **Exactly one** model per built `.app` (copy script branches on `PLATFORM_NAME`) |
| Bundle layout | Fixed folder `openai_whisper-bundled/` + sibling `asr-model-pin.txt` (one line: logical id) |
| Setup script | Idempotent fetch of **both** models into gitignored `Models/` at existing HF revision; early-exit must not skip `base` when only `tiny` is present |
| HF pin | Same repo/revision as ADR-003 (`argmaxinc/whisperkit-coreml` @ `97a5bf9…`) unless Architect proves `base.en` missing there |
| Matching | **No** `"buck"`→fuck alias; matching-spec stays exact |
| Interval cache | Fingerprint token `asr-model:<logical-pin>` alongside existing `interval-format:v2` / segmenter tokens |
| Transcript cache | One-shot wipe of interval + transcript Application Support dirs when stored pin ≠ bundled pin (before analyze / `transcriptExists`) |
| Device compute | Non-`cpuOnly` (WhisperKit defaults / ANE-capable) for `base.en` |
| Simulator compute | `cpuOnly` + `tiny` (ADR-003) |
| Done gate | Full simulator `scripts/verify.sh` only — no live TAL, no device listening |
| TAL 981 mute | Human dogfood checklist after Done — **not** a Done gate |

## Background (current vs desired)

**Today:** App always bundles `openai_whisper-tiny.en`; [`WhisperKitASRTranscriber`](../../PodWash/PodWash/WhisperKitASRTranscriber.swift) forces `cpuOnly`. On device, `tiny.en` misheard TAL 981’s F-word as **`Buck`** → zero profanity intervals → audible swear (task-019).

**Desired:** Device builds copy `base.en` into a stable bundle folder; simulator builds still copy `tiny.en`. Locator reads one folder + pin file. Caches invalidate on pin change. Device ASR uses non-cpuOnly compute.

## Deliverables

- **ADR-024** — dual-SDK model pin, stable bundle folder + pin file, compute split, cache fingerprint + wipe; extends (does not rewrite) ADR-003/020 (intake said ADR-023; that number is mute markers)
- [`scripts/setup-asr-models.sh`](../../scripts/setup-asr-models.sh) — fetch both `tiny.en` and `base.en`
- [`scripts/copy-bundled-whisper-model.sh`](../../scripts/copy-bundled-whisper-model.sh) — `PLATFORM_NAME` selects source; installs into `openai_whisper-bundled/` + writes `asr-model-pin.txt`
- [`WhisperModelLocator.swift`](../../PodWash/PodWash/WhisperModelLocator.swift) — resolve `openai_whisper-bundled`; expose logical pin
- [`WhisperKitASRTranscriber.swift`](../../PodWash/PodWash/WhisperKitASRTranscriber.swift) — injectable compute (`cpuOnly` vs defaults)
- [`ProductionAnalyzerFactory.swift`](../../PodWash/PodWash/ProductionAnalyzerFactory.swift) — pass environment-appropriate compute
- [`IntervalCache.swift`](../../PodWash/PodWash/IntervalCache.swift) — `asr-model:` fingerprint token
- Pin-mismatch wipe (Application Support interval + transcript dirs) on launch / factory init before analyze
- Tests — locator/pin, fingerprint miss, wipe, factory structural (no live `base.en` inference in verify)

## Depends on

- Slice 24 (Done) — production analysis + bundled model
- Slice 26 (Done) — transcript cache (wipe target)
- Task 019 (Done) — documented ASR miss motivating upgrade

**Parallelizable:** Yes vs slice-27 (mute markers) if files don’t collide; serialize on shared locator/factory if both In Progress.

## Out-of-scope

- Shipping **both** models in one IPA
- `small.en` / larger models
- Fuzzy matching or ASR alias lexicon (`buck`→fuck)
- SpeechAnalyzer
- First-run network model download
- Settings UI for ASR quality
- Regenerating slow-suite ASR goldens from `base.en`
- Guaranteeing TAL 981 transcript becomes `fuck` (human checklist only)
- Slice 27 mute markers
- Weakening task-015 mute wiring tests

## Acceptance criteria

Automatable only. **XCTSkip is not allowed on core ACs.**

- [ ] 1. Setup/copy contract: documented pins; copy script fails the build if the **selected** source model’s three `.mlmodelc` dirs are missing; setup ensures **both** `tiny.en` and `base.en` exist under `Models/whisperkit-coreml/` (idempotent).
- [ ] 2. Unit test (injected pin / temp bundle): logical pin string is `openai_whisper-base.en` when device pin is injected; `openai_whisper-tiny.en` when simulator pin is injected — **no** live ASR.
- [ ] 3. Unit test (`IntervalCache`): after fingerprint gains `asr-model:<pin>` token, load with same episode + targets against a file written under the **previous** fingerprint returns **nil** (miss).
- [ ] 4. Unit test (temp dirs): pin-mismatch wipe clears transcript + interval cache directories; matching pin does **not** wipe.
- [ ] 5. Unit/structural: `makeDefaultAnalyzer(fixtureLibraryMode: false)` is still **not** `InstantEpisodeAnalyzer`; production path still composes `AnalysisPipeline` + locator-backed transcriber.
- [ ] 6. Full suite green via `scripts/verify.sh` (**exit 0, failed 0, skipped 0**).

## Verification mapping

| AC# | Test file | Test method | Notes |
|-----|-----------|-------------|-------|
| 1 | `PodWash/PodWashTests/ASRModelSetupCopyContractTests.swift` | `testSetupScriptEnsuresBothModelsAtPinnedRevision` | HF revision + both model ids |
| 1 | `PodWash/PodWashTests/ASRModelSetupCopyContractTests.swift` | `testCopyScriptDocumentsDualSDKSelectionAndStableBundleLayout` | PLATFORM_NAME, bundled folder, pin file |
| 1 | `PodWash/PodWashTests/ASRModelSetupCopyContractTests.swift` | `testCopyScriptFailsWhenSelectedModelIncomplete` | Subprocess; incomplete tiny tree → non-zero exit |
| 1 | `PodWash/PodWashTests/ASRModelSetupCopyContractTests.swift` | `testCopyScriptSucceedsWhenSelectedModelComplete` | Subprocess; complete tree → bundled + pin |
| 2 | `PodWash/PodWashTests/WhisperModelLocatorTests.swift` | `testLogicalPinDeviceVsSimulator` | Injected base.en vs tiny.en; no live ASR |
| 2 | `PodWash/PodWashTests/WhisperModelLocatorTests.swift` | `testLogicalPinTrimsWhitespaceAndIgnoresExtraLines` | Pin file parsing |
| 2 | `PodWash/PodWashTests/WhisperModelLocatorTests.swift` | `testResolvedModelFolderUsesStableBundledResourceName` | Stable folder name + mlmodelc completeness |
| 2 | `PodWash/PodWashTests/WhisperModelLocatorTests.swift` | `testMainBundleExposesSimulatorLogicalPin` | Main bundle integration (simulator only) |
| 3 | `PodWash/PodWashTests/IntervalCacheTests.swift` | `testAsrModelFingerprintMiss` | Store pin A; load pin B → nil |
| 3 | `PodWash/PodWashTests/IntervalCacheTests.swift` | `testLegacyFingerprintWithoutAsrModelTokenMisses` | Pre-slice hash file → nil |
| 3 | `PodWash/PodWashTests/IntervalCacheTests.swift` | `testSamePinStillHitsAfterStore` | Same pin still hits |
| 4 | `PodWash/PodWashTests/ASRModelPinWipeTests.swift` | `testPinMismatchWipesCaches` | Mismatch clears interval + transcript dirs |
| 4 | `PodWash/PodWashTests/ASRModelPinWipeTests.swift` | `testMatchingPinDoesNotWipeCaches` | Equal pin leaves seeded files |
| 4 | `PodWash/PodWashTests/ASRModelPinWipeTests.swift` | `testMissingStoredPinWipesCaches` | Missing stored pin → wipe + write bundled |
| 5 | `PodWash/PodWashTests/ProductionAnalysisWiringTests.swift` | `testProductionAnalyzerIsNotInstantStub` | Not Instant; pipeline path |
| 5 | `PodWash/PodWashTests/ProductionAnalysisWiringTests.swift` | `testProductionFactoryStillComposesLocatorBackedPipeline` | Locator pin + AnalysisPipeline + sim cpuOnly |
| 5 | `PodWash/PodWashTests/ProductionAnalysisWiringTests.swift` | `testBundledWhisperModelFolderIsComplete` | ADR-024 bundled folder + simulator pin |
| 6 | — | — | Unfiltered `scripts/verify.sh` exit 0, failed 0, skipped 0 |

## Verification commands

```bash
# Fast inner loop (NOT sufficient for Done):
scripts/verify.sh -only-testing:PodWashTests/ASRModelSetupCopyContractTests
scripts/verify.sh -only-testing:PodWashTests/WhisperModelLocatorTests
scripts/verify.sh -only-testing:PodWashTests/IntervalCacheTests
scripts/verify.sh -only-testing:PodWashTests/ASRModelPinWipeTests
scripts/verify.sh -only-testing:PodWashTests/ProductionAnalysisWiringTests/testProductionFactoryStillComposesLocatorBackedPipeline
scripts/verify.sh -only-testing:PodWashTests/ProductionAnalysisWiringTests/testBundledWhisperModelFolderIsComplete

# Done gate — FULL suite, zero failures, zero skips:
scripts/verify.sh
```

## Verification record (QA fills at Verify)

```
VERIFY RESULT: exit=0 total=17 passed=17 failed=0 skipped=0 filtered=1 bundle=build/test-results/verify-20260715-154813.xcresult tier=2 class=tests
```

## Plan review record (coordinator fills before downstream roles)

```
ADR review (2026-07-15): (pending) QA cleared — pipeline worker finished PM cleared — pipeline worker finished
Test spec review (2026-07-15): Architect cleared — pipeline worker finished
```

## Role artifacts

| Role | Required? | Artifact |
|------|-----------|----------|
| PM | **Required** | This story |
| Architect | **Required** | [`docs/adr/024-device-whisper-base-en.md`](../adr/024-device-whisper-base-en.md) |
| UX | **Waived** | No new screens — bundle/compute/cache only |
| QA | **Required** | `ASRModelSetupCopyContractTests`, `WhisperModelLocatorTests`, `IntervalCacheTests`, `ASRModelPinWipeTests`, `ProductionAnalysisWiringTests` (AC5 extension) |
| Engineer | **Required** | Scripts + app wiring |

## Human checklist (post-Done dogfood — not a Done gate)

- [ ] Install **device** build (iphoneos / `base.en`).
- [ ] Play or re-analyze TAL **981 The Test Case** (pin wipe should force cold analyze).
- [ ] Open transcript near **2:07**: token should **not** be `Buck` if upgrade helped (ideally a target F-word).
- [ ] Confirm mute follows when ASR emits a matching target word.
- [ ] If still `Buck` / no match → further ASR follow-up (do not bend mute tests).

## Done gate

- [ ] All AC checked; full suite green; `VERIFY RESULT` recorded
- [ ] Plan reviews recorded
- [ ] Auto-commit on green: `slice-28: device whisper base.en dual-SDK pin`
