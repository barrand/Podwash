# ADR-024 — Device Whisper base.en (lean dual-SDK pin)

| Field | Value |
|-------|-------|
| **Status** | Accepted |
| **Date** | 2026-07-15 |
| **Supersedes** | — (extends [ADR-003](003-asr-stack-choice.md) §3.6 / [ADR-020](020-production-analysis-composition.md) §2–§3 / §9; does **not** rewrite them. Does **not** change matching-spec or add ASR aliases.) |
| **Builds on** | [ADR-000](000-foundations.md) §6 (`verify.sh` simulator Done); [ADR-003](003-asr-stack-choice.md) (`tiny.en` + `cpuOnly` sim verifiability; `base.en`+ empty on CPU-only sim); [ADR-005](005-analysis-pipeline.md) / [ADR-013](013-segmentation-integration.md) (`IntervalCache` fingerprint tokens); [ADR-020](020-production-analysis-composition.md) (build-phase copy + `WhisperModelLocator` + factory); [ADR-022](022-transcript-cache.md) (episode-keyed transcript files — wipe target) |
| **Slice** | [slice-28-device-whisper-base-en.md](../slices/slice-28-device-whisper-base-en.md) |
| **Numbering** | Slice intake said “ADR-023”; **023 is already** [mute markers](023-super-seek-bar-mute-markers.md). This decision is **ADR-024**. |

## Context

Production always bundles `openai_whisper-tiny.en` and forces `cpuOnly`
([ADR-020](020-production-analysis-composition.md) §9). On device, `tiny.en`
misheard TAL 981’s F-word as **`Buck`** (task-019) → zero profanity intervals →
audible swear. ADR-003 already proved `base.en`+ is **simulator-incompatible**
(empty output under CPU-only), so the Done gate cannot ship `base.en` into the
simulator `.app`.

Slice 28 product pins (intake — do not re-litigate):

| Pin | Choice |
|-----|--------|
| Device (`iphoneos`) model | `openai_whisper-base.en` |
| Simulator model | `openai_whisper-tiny.en` |
| Bundle policy | **Exactly one** model per built `.app` |
| Bundle layout | Fixed folder `openai_whisper-bundled/` + sibling `asr-model-pin.txt` |
| HF pin | Same repo/revision as ADR-003 unless proven missing |
| Matching | **No** `"buck"`→fuck alias |
| Interval cache | Fingerprint token `asr-model:<logical-pin>` |
| Transcript + interval wipe | One-shot when stored pin ≠ bundled pin |
| Device compute | Non-`cpuOnly` (WhisperKit defaults / ANE-capable) |
| Simulator compute | `cpuOnly` + `tiny` (ADR-003) |
| Done gate | Full simulator `scripts/verify.sh` only — no live TAL / device listening |

**Gap this ADR closes:** dual-SDK model selection at **build copy** time, stable
runtime locator + logical pin, compute split, and cache invalidation so a pin
upgrade cannot reuse pre-upgrade `tiny` intervals/transcripts — all assertable
on simulator via injection (no live `base.en` inference in verify).

## Empirical validation

| Claim | Evidence | Spike? |
|-------|----------|--------|
| `openai_whisper-base.en` exists at ADR-003 HF revision | **Measured 2026-07-15:** local `Models/whisperkit-coreml/openai_whisper-base.en/` has the three `.mlmodelc` dirs; HF API tree for `argmaxinc/whisperkit-coreml` @ `97a5bf9bbc74c7d9c12c755d04dea59e672e3808` lists `openai_whisper-base.en/{AudioEncoder,TextDecoder,MelSpectrogram}.mlmodelc` | **No** — presence check only |
| `base.en` empty / unusable on CPU-only simulator | ADR-003 § Empirical validation (maintainer issues #131 / #302) | **No** — reuse |
| Device ANE / default compute improves TAL 981 recall | **Not simulator-verifiable**; human dogfood checklist only (slice) | **No** — out of Done gate |
| Bundled copy size (`base.en` `.mlmodelc` + configs) | **Measured 2026-07-15:** ≈ **140 MB** (AudioEncoder ~40, TextDecoder ~100, Mel ~0.4) vs ADR-020’s ~73 MB for `tiny.en` `.mlmodelc` | **No** |
| Fingerprint miss / pin wipe | Pure file + string logic | **No** |
| WhisperKit `ModelComputeOptions()` defaults | **Read from WhisperKit 1.0.0 source:** device → mel `.cpuAndGPU`, encoder `.cpuAndNeuralEngine` (iOS 17+), decoder `.cpuAndNeuralEngine`; **simulator auto-forces all `.cpuOnly`** inside the same init | **No** |

**No throwaway spike file required** for this gate. Framework uncertainty that
matters for Done is already recorded in ADR-003; device recall is explicitly
**not** a Done criterion.

## Decision

### 1. Dual-SDK model pin (extends ADR-003 / ADR-020 — does not rewrite)

| SDK / platform | Logical pin (one line in `asr-model-pin.txt`) | Source under `Models/whisperkit-coreml/` | Compute |
|----------------|-----------------------------------------------|------------------------------------------|---------|
| `iphoneos` (device) | `openai_whisper-base.en` | `openai_whisper-base.en/` | WhisperKit **defaults** (`ModelComputeOptions()`) — ANE-capable on device |
| `iphonesimulator` | `openai_whisper-tiny.en` | `openai_whisper-tiny.en/` | **Explicit** `.cpuOnly` for mel / audioEncoder / textDecoder (ADR-003) |

**HF pin (unchanged from ADR-003):**

| Field | Value |
|-------|-------|
| Repo | `argmaxinc/whisperkit-coreml` |
| Revision | `97a5bf9bbc74c7d9c12c755d04dea59e672e3808` |
| Models fetched | **Both** `openai_whisper-tiny.en` and `openai_whisper-base.en` |

Exactly **one** model lands in each built `.app`. Shipping both in one IPA is OOS.

### 2. Module layout / file boundaries

| File | Target | Status | Responsibility |
|------|--------|--------|----------------|
| `scripts/setup-asr-models.sh` | repo | **changed** | Idempotent fetch of **both** models at the pinned revision; early-exit only when **both** trees have the three `.mlmodelc` dirs (must not skip `base` when only `tiny` is present) |
| `scripts/copy-bundled-whisper-model.sh` | repo | **changed** | Branch on `PLATFORM_NAME`: select source model; install into **stable** `openai_whisper-bundled/`; write sibling `asr-model-pin.txt` (one line = logical id); fail build if selected source’s three `.mlmodelc` dirs missing |
| `PodWash/PodWash/WhisperModelLocator.swift` | app | **changed** | Resolve `openai_whisper-bundled` + read logical pin; completeness check unchanged (three `.mlmodelc`); injectable bundle / pin for tests |
| `PodWash/PodWash/WhisperKitASRTranscriber.swift` | app | **changed** | Injectable compute preference (`cpuOnly` vs WhisperKit defaults); still the only WhisperKit import |
| `PodWash/PodWash/ProductionAnalyzerFactory.swift` | app | **changed** | Wire locator pin → cache fingerprint + wipe; pass environment-appropriate compute; keep Instant / fixture branching |
| `PodWash/PodWash/IntervalCache.swift` | app | **changed** | Require `asrModelPin`; append `asr-model:<pin>` to fingerprint material alongside `interval-format:v2` / `segmenter:heuristic-cue-v5` |
| `PodWash/PodWash/ASRModelPinStore.swift` (name flexible) | app | **new** | Persist last-applied pin under Application Support; on mismatch wipe interval + transcript dirs then write pin |
| `PodWash/PodWash/TranscriptCache.swift` | app | **unchanged API** | Wipe target via `clear()` / directory remove — no key-schema change |
| Tests (QA) | test | **new / extend** | Locator pin inject; fingerprint miss; wipe; factory structural — **no** live `base.en` ASR |

**Unchanged:** `ASRTranscribing` / `[TimedWord]`, matching-spec, segmenter revision
token, progressive chunk contract, fixture Instant path, slow-suite goldens
(still `tiny.en`).

### 3. Bundle layout + copy contract

**Stable runtime names** (same for every SDK — locator does not branch on platform):

```
App.bundle/
  openai_whisper-bundled/          # selected model’s .mlmodelc + configs
    AudioEncoder.mlmodelc/
    TextDecoder.mlmodelc/
    MelSpectrogram.mlmodelc/
    config.json
    generation_config.json
  asr-model-pin.txt                # sibling; one line, e.g. openai_whisper-tiny.en
```

**Copy script algorithm:**

1. `PLATFORM_NAME=iphoneos` → `SOURCE_MODEL=openai_whisper-base.en`
2. Else (simulator / other) → `SOURCE_MODEL=openai_whisper-tiny.en`
3. Assert `$SRCROOT/../Models/whisperkit-coreml/$SOURCE_MODEL/{AudioEncoder,TextDecoder,MelSpectrogram}.mlmodelc` exist — else **fail the build** citing `scripts/setup-asr-models.sh` + this ADR.
4. `rm -rf` dest `openai_whisper-bundled/`; copy the five artifacts (same omit-`.mlpackage` policy as ADR-020).
5. Write `asr-model-pin.txt` with exactly `SOURCE_MODEL` + newline.

**Setup script algorithm:**

1. For each of `openai_whisper-tiny.en`, `openai_whisper-base.en`: if any of the three `.mlmodelc` dirs is missing, download that model from the pinned HF revision into `Models/whisperkit-coreml/`.
2. Early-exit **0** only when **both** models are complete.
3. Fail non-zero if a download finishes without the three dirs.

### 4. Key API sketch

```swift
enum WhisperModelLocator {
    static let modelFolderResourceName = "openai_whisper-bundled"
    static let pinResourceName = "asr-model-pin.txt"
    static let requiredMLModelcNames = [
        "AudioEncoder.mlmodelc",
        "TextDecoder.mlmodelc",
        "MelSpectrogram.mlmodelc",
    ]

    /// Throws if folder incomplete or pin file missing/blank.
    static func resolvedModelFolder(in bundle: Bundle = .main) throws -> URL

    /// Logical pin string from sibling `asr-model-pin.txt` (trimmed, single line).
    /// Test seam: `logicalPin(in:)` / override via temp bundle with injected pin file.
    static func logicalPin(in bundle: Bundle = .main) throws -> String

    static func requiredSubdirectories(in modelFolder: URL) -> [String: Bool]
}

/// Compute preference — WhisperKit types stay inside WhisperKitASRTranscriber.
enum ASRComputePreference: Equatable, Sendable {
    /// Force mel / encoder / decoder `.cpuOnly` (simulator Done path).
    case cpuOnly
    /// `ModelComputeOptions()` — ANE-capable on device; WhisperKit itself
    /// auto-forces cpuOnly when `isRunningOnSimulator` (defense in depth).
    case whisperKitDefault
}

final class WhisperKitASRTranscriber: ASRTranscribing {
    init(modelFolder: URL, compute: ASRComputePreference)
    // cpuOnly → explicit ModelComputeOptions(...cpuOnly)
    // whisperKitDefault → ModelComputeOptions()
}

struct IntervalCache: Sendable {
    let baseDirectory: URL
    /// Logical ASR pin included in fingerprint material as `asr-model:<pin>`.
    let asrModelPin: String

    init(baseDirectory: URL, asrModelPin: String)

    static func applicationSupport(asrModelPin: String) -> IntervalCache

    static func fingerprint(for targetWords: Set<String>) -> String  // unchanged word-list part

    func load(episodeID: String, targetWords: Set<String>) -> [CensorInterval]?
    func store(_ intervals: [CensorInterval], episodeID: String, targetWords: Set<String>) throws
    func clear() throws
}

/// One-shot pin reconciliation before analyze / transcriptExists.
enum ASRModelPinStore {
    /// Application Support file holding the last-applied logical pin.
    static func storedPinURL(applicationSupport: URL) -> URL

    /// If stored pin ≠ `bundledPin` (or stored missing): delete
    /// `intervalCacheDirectory` and `transcriptCacheDirectory` (if present),
    /// then write `bundledPin`. If equal: no-op (do not wipe).
    static func reconcile(
        bundledPin: String,
        storedPinURL: URL,
        intervalCacheDirectory: URL,
        transcriptCacheDirectory: URL,
        fileManager: FileManager = .default
    ) throws
}

enum ProductionAnalyzerFactory {
    static func makeAnalyzer(
        bundle: Bundle = .main,
        cacheBaseDirectory: URL? = nil,
        fixtureLibraryMode: Bool? = nil,
        compute: ASRComputePreference? = nil  // nil → platform default (§5)
    ) -> any EpisodeAnalyzing

    static func makeProductionPipeline(
        bundle: Bundle = .main,
        cacheBaseDirectory: URL? = nil,
        compute: ASRComputePreference? = nil
    ) throws -> AnalysisPipeline
}
```

**Fingerprint material** (`IntervalCache` private `cacheFileURL`):

```text
{sorted-normalized-targets}
interval-format:v2
segmenter:heuristic-cue-v5
asr-model:{asrModelPin}
```

→ `sha256` → `{safeStem}__{hash}.json` (same path shape as today). A file written
under a prior pin (or pre-slice fingerprint without the token) **misses**.

### 5. Factory + compute wiring

`makeProductionPipeline` algorithm:

1. `let pin = try WhisperModelLocator.logicalPin(in: bundle)`.
2. `let folder = try WhisperModelLocator.resolvedModelFolder(in: bundle)`.
3. Resolve cache dirs (Application Support or injected base).
4. `try ASRModelPinStore.reconcile(bundledPin: pin, …)` **before** constructing
   pipeline consumers that read caches.
5. `let compute = compute ?? Self.defaultComputePreference()` where
   `defaultComputePreference()` is:
   - **Simulator** (`#if targetEnvironment(simulator)`): `.cpuOnly`
   - **Device**: `.whisperKitDefault`
6. `WhisperKitASRTranscriber(modelFolder: folder, compute: compute)`.
7. `IntervalCache(…, asrModelPin: pin)` + `TranscriptCache` as today.
8. Return `AnalysisPipeline(…)`.

Call reconcile from the production factory path used by
`AppShellModel.makeDefaultAnalyzer` so wipe runs before first
`transcriptExists` / `analyze` in a session. Fixture Instant paths **skip**
reconcile (no bundled-model dependency).

### 6. Verification architecture (slice ACs)

| AC | Assert without live `base.en` / TAL |
|----|-------------------------------------|
| 1 | Setup/copy contract documented; copy fails when selected source incomplete; setup ensures both models under `Models/` |
| 2 | Temp bundle / injected pin file → `logicalPin` is `openai_whisper-base.en` vs `openai_whisper-tiny.en` |
| 3 | `IntervalCache` store under pin A; load under pin B (same episode + targets) → `nil` |
| 4 | Temp dirs: mismatch wipe clears both cache dirs; matching pin leaves files |
| 5 | `makeDefaultAnalyzer(fixtureLibraryMode: false)` still not Instant; still composes pipeline + locator-backed transcriber |
| 6 | Full `scripts/verify.sh` exit 0, failed 0, skipped 0 |

**Binding:** no live WhisperKit `base.en` inference in the fast suite; no device
listening Done gate; no matching-spec alias for `buck`.

### 7. Cross-cutting impact

| Area | Impact |
|------|--------|
| `WhisperModelLocator` / copy script / setup script | Shared with any ASR bundle work — serialize vs concurrent editors |
| `IntervalCache` init | **Breaking additive:** all production + test constructors pass `asrModelPin` |
| `ProductionAnalyzerFactory` / `AppShellModel` | Wipe + compute wiring at composition root |
| IPA size (device) | ~**140 MB** ASR payload (was ~73 MB `tiny.en`); simulator stays ~73 MB |
| CI | `setup-asr-models.sh` must fetch **both** models before `verify.sh` / device archive |
| Matcher / transcript schema / seek bar | Unchanged |
| Slow ASR goldens | Remain `tiny.en` — do **not** regenerate from `base.en` |

### 8. Out of scope (binding)

- Shipping both models in one IPA
- `small.en` / larger models / Settings ASR quality UI
- First-run network model download
- Fuzzy matching or `buck`→fuck alias
- SpeechAnalyzer
- Guaranteeing TAL 981 becomes `fuck` (human checklist only)
- Regenerating slow-suite goldens from `base.en`
- Slice 27 mute-marker chrome

## Consequences

- Device dogfood can use `base.en` + ANE-capable defaults while dark-factory
  verify continues on `tiny.en` + `cpuOnly` in the simulator `.app`.
- Stable bundle folder + pin file keeps runtime code SDK-agnostic; only the
  **copy script** branches on `PLATFORM_NAME`.
- Cache correctness on upgrade: fingerprint miss **and** one-shot wipe so
  episode-keyed transcripts cannot outlive a pin change.
- ADR-003’s simulator pin and ADR-020’s build-phase-copy policy remain; this ADR
  **narrows** ADR-020 §9 (“always cpuOnly”) to **simulator only** and selects
  `base.en` for `iphoneos`.
- QA maps ACs to injection/structural tests only; Engineer must not add live
  `base.en` to `scripts/verify.sh` Done path.
