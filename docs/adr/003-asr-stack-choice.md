# ADR-003 — On-device ASR stack choice: WhisperKit (Core ML) tiny.en

| Field | Value |
|-------|-------|
| **Status** | Accepted |
| **Date** | 2026-07-08 |
| **Supersedes** | — |
| **Builds on** | [ADR-000](000-foundations.md) §4 (transcript schema — ASR **produces** `[TimedWord]`), §5 (iOS floor policy — raising tolerated, lowering is a user decision), §6 (`scripts/verify.sh`-only; Done requires the full **simulator** suite green) |
| **Resolves** | PRD §11 open decision — "On-device ASR choice" (SpeechAnalyzer vs WhisperKit) and the associated minimum-iOS-version question |

## Context

Slice 05 picks the on-device ASR stack with data. The choice drives PRD §6 ("analyze
once": transcribe an episode a single time to word-level timestamps, feed the Slice 02
matcher, cache the result) and the ADR-000 §5 iOS floor. The candidates are Apple's
`SpeechAnalyzer`/`SpeechTranscriber` (iOS 26+) and WhisperKit (Core ML).

The binding constraint is **dark-factory verifiability**, not raw accuracy. ADR-000 §6
defines Done as a full **iOS Simulator** suite green via `scripts/verify.sh` — every gate
runs in the simulator runtime, with no real-device step and no human listening. An ASR
stack that cannot run and produce correct word timestamps **in the simulator** cannot gate
CI, regardless of how good it is on hardware.

The slice's acceptance criteria shape every decision below:

- **AC1** — fast test transcribes the bundled clip → every word boundary within **±200 ms**
  of the golden transcript; word error count **≤ 2** for the fixture.
- **AC2** — **execution evidence**: the test **FAILS** (never `XCTSkip`) if
  `benchmark-results.json` is missing, unparsable, or has `wordCount == 0`. A missing model
  is a setup failure, surfaced by pointing at `scripts/setup-asr-models.sh`.
- **AC3** — `scripts/setup-asr-models.sh` exists, pins an **exact** model version, and is
  documented in the fixture README.
- **AC4** — `PodWashSlowTests` target exists and is a member of the `PodWash` scheme test
  action (structural assert / `xcodebuild -list`).
- **AC5** — this ADR committed with benchmark numbers; PRD §11 ASR/iOS-floor items updated.
- **AC6** — full **fast** suite green via `scripts/verify.sh` with **skipped = 0**.

The crux is: **which stack produces correct `[TimedWord]` (ADR-000 §4) deterministically
in the simulator, with recorded execution evidence, so a fast CI test can assert accuracy
without re-running inference?** That single question (§3.1, §3.4) drives the module layout,
the fast/slow test split, and the model pin.

## Decision

### 3.1 Stack choice — WhisperKit (Core ML), model `openai_whisper-tiny.en`

PodWash uses **WhisperKit** (Argmax) with the **`openai_whisper-tiny.en`** Core ML model,
run **CPU-only** in the simulator. The decision is driven by the verifiability constraint,
supported by the spike measurements in § "Empirical validation":

1. **Apple `SpeechAnalyzer`/`SpeechTranscriber` cannot run on the iOS Simulator.** Measured
   on iPhone 17 Pro Simulator / iOS 26.1: `SpeechTranscriber.supportedLocales` returns an
   **empty set** and `AssetInventory.status(forModules:)` returns `.unsupported` for en-US;
   attempting to install the assets throws `SFSpeechErrorDomain Code=1 "... not subscribed
   to transcription.en"`. Apple's on-device speech models are **not provisioned in the
   simulator runtime**. Since Done is a full **simulator** suite (ADR-000 §6),
   SpeechAnalyzer is **unverifiable** in the automated pipeline. It is **deferred to a
   documented future real-device evaluation** — not deleted — but it **cannot gate CI**.

2. **WhisperKit runs in the simulator (CPU-only) and produces correct word-level
   timestamps — but only for `tiny`/`tiny.en`.** Measured: `base.en` (and larger) produce
   **empty output** on the simulator because WhisperKit's exported Core ML models target
   ANE/GPU and the simulator is CPU-only → indeterminate results for base+ (confirmed by
   the WhisperKit maintainer, GitHub issues #131 / #302). `tiny.en` with `ModelComputeOptions`
   set to `.cpuOnly` for the mel/audioEncoder/textDecoder components transcribes **correctly
   and deterministically** in the simulator. Therefore `tiny.en` is the pinned simulator
   model; larger models are a real-device concern (§3.6).

3. **iOS floor stays 26.1 — not lowered.** WhisperKit supports iOS 16+, so adopting it does
   **not** require the 26.1 floor; but PodWash keeps its Xcode project deployment target of
   **26.1**. No floor change, and therefore **no halt-and-ask** is triggered — ADR-000 §5
   only requires halting to **lower** the floor to widen device support. (Choosing WhisperKit
   makes a future floor drop *possible* as a product decision, but this ADR does not make it.)

### 3.2 Module layout / file boundaries

| File | Target | Status | Responsibility |
|------|--------|--------|----------------|
| `PodWash/PodWash/ASRTranscribing.swift` | app | **new** | Protocol `ASRTranscribing` producing `[TimedWord]` (ADR-000 §4) from an audio file `URL`, plus the Codable `ASRBenchmark` result struct. **No WhisperKit types on this public surface** — WhisperKit is wrapped, so test targets need not import it. |
| `PodWash/PodWash/WhisperKitASRTranscriber.swift` | app | **new** | WhisperKit-backed `ASRTranscribing`. Loads the pinned local model folder with `ModelComputeOptions(.cpuOnly)`; runs `DecodingOptions(wordTimestamps: true)`; maps WhisperKit `WordTiming` → `TimedWord`. The only file that imports `WhisperKit`. |
| `PodWash/PodWashTests/ASRSpikeFixtureTests.swift` | PodWashTests (**FAST**) | **new (QA)** | AC1/AC2. Validates the **committed** `benchmark-results.json` artifact against the independent golden — **no live ASR, no model needed** → deterministic + CI-safe. Fails (never skips) on missing/unparsable/`wordCount==0` artifact. |
| `PodWash/PodWashSlowTests/ASRBenchmarkTests.swift` | **PodWashSlowTests (new target)** | **new (QA)** | Runs WhisperKit **live**, regenerates `benchmark-results.json`, asserts drift/error thresholds. **Nightly only; NOT a Done gate.** Member of the `PodWash` scheme test action (AC4). |
| `PodWash/PodWashTests/Fixtures/asr/speech-pangram.wav` | test | **new** | 4.56 s, 16 kHz mono clip (see § "Empirical validation" / fixture README). |
| `PodWash/PodWashTests/Fixtures/asr/asr_fixture_expected.json` | test | **new** | Golden `[TimedWord]` — word boundaries hand-computed from the known concatenation layout (independent provenance; **not** ASR output). |
| `PodWash/PodWashTests/Fixtures/asr/benchmark-results.json` | test | **new (execution evidence)** | The `ASRBenchmark` artifact. **Written by the slow test** to the source `Fixtures/asr/` path via a `#filePath`-relative URL, then committed. The fast test reads the committed copy. |
| `PodWash/PodWashTests/Fixtures/asr/asr-README.md` | test | **new** | Model pin (repo + exact revision), fixture provenance, golden convention, regeneration instructions. Named uniquely (not `README.md`) because the PodWashTests synchronized group flattens resource basenames into the `.xctest` bundle, so two `README.md`s would collide at build time. |
| `scripts/setup-asr-models.sh` | repo | **new** | Pinned model download into gitignored `Models/` (AC3). |

The `ASRTranscribing` **protocol** and `ASRBenchmark` struct live in the **app target** so
both the app (future Slice 07 pipeline) and the slow benchmark test share the exact
production transcriber — the slow test regenerates the artifact through the *same* code path
the app will use, so the committed evidence is not a test-only fabrication. WhisperKit is
confined to `WhisperKitASRTranscriber.swift`; nothing else imports it, keeping the fast test
target free of the SPM dependency and the gitignored model.

### 3.3 Key API sketch

```swift
import Foundation

// TimedWord is the ADR-000 §4 shared schema:
// struct TimedWord: Codable, Equatable { let word: String; let start: Double; let end: Double }

/// Produces word-level timestamps from an audio file. Implementations wrap a concrete
/// engine (WhisperKit today); WhisperKit types never appear on this surface so test
/// targets and the Slice 07 pipeline depend only on `[TimedWord]` (ADR-000 §4).
protocol ASRTranscribing {
    /// Transcribe a local audio file to timed words. Throws on load/transcription failure;
    /// callers treat a thrown error or an empty result as a setup/measurement failure
    /// (AC2 — never silently skipped).
    func transcribe(fileURL: URL) async throws -> [TimedWord]
}

/// Execution-evidence + accuracy record for one benchmark run. Codable → the artifact
/// committed at Fixtures/asr/benchmark-results.json (§3.5). The fast test decodes and
/// asserts against the golden; the slow test encodes it after a live run.
struct ASRBenchmark: Codable, Equatable {
    let engine: String              // "WhisperKit"
    let engineVersion: String       // "1.0.0"
    let model: String               // "openai_whisper-tiny.en"
    let modelRevision: String       // pinned HuggingFace revision (§3.6)
    let computeUnits: String        // "cpuOnly"
    let device: String              // "iPhone 17 Pro Simulator / iOS 26.1"
    let audioSeconds: Double        // fixture length (4.56)
    let loadSeconds: Double         // cold model load incl. Core ML compile
    let transcriptionSeconds: Double
    let realTimeFactor: Double      // transcriptionSeconds / audioSeconds
    let wordCount: Int
    let words: [TimedWord]          // the transcribed timing, ADR-000 §4
    let driftMaxMs: Double          // max |boundary − golden| over all boundaries
    let driftMeanMs: Double         // mean |boundary − golden|
    let wordErrorCount: Int         // normalized word mismatches vs golden
}

import WhisperKit   // imported ONLY in this file

/// WhisperKit-backed transcriber. Loads the pinned local model folder CPU-only (the
/// simulator has no ANE/GPU; base+ models render empty there — §3.1 reason 2).
final class WhisperKitASRTranscriber: ASRTranscribing {

    private let modelFolder: URL          // pinned local folder under Models/ (gitignored)

    init(modelFolder: URL) { self.modelFolder = modelFolder }

    func transcribe(fileURL: URL) async throws -> [TimedWord] {
        // NOTE: WhisperKit 1.0.0 ModelComputeOptions has NO `prefillCompute` argument, and
        // the enum values require the explicit `MLComputeUnits.` base (verified empirically).
        let compute = ModelComputeOptions(
            melCompute: MLComputeUnits.cpuOnly,
            audioEncoderCompute: MLComputeUnits.cpuOnly,
            textDecoderCompute: MLComputeUnits.cpuOnly
        )
        let config = WhisperKitConfig(modelFolder: modelFolder.path,
                                      computeOptions: compute)
        let pipe = try await WhisperKit(config)

        let results = try await pipe.transcribe(
            audioPath: fileURL.path,
            decodeOptions: DecodingOptions(wordTimestamps: true)
        )

        return results
            .flatMap { $0.allWords }                       // WhisperKit WordTiming
            .map { TimedWord(word: $0.word, start: Double($0.start), end: Double($0.end)) }
    }
}
```

`allWords`/`WordTiming` names track the WhisperKit 1.0.0 API; the Engineer maps whatever
concrete accessor 1.0.0 exposes into `TimedWord` — the invariant is that **only this file**
knows WhisperKit exists.

### 3.4 Verification architecture (crux)

The design splits verification into a **fast** deterministic gate and a **slow** live
regeneration, mirroring ADR-002's "measure once, assert against fixture" pattern:

- **FAST (`ASRSpikeFixtureTests`, Done gate).** Reads the **committed**
  `benchmark-results.json`, decodes it, and asserts AC1/AC2 against the independent golden
  `asr_fixture_expected.json`:
  - `testBenchmarkArtifactExistsAndNonEmpty` (AC2) — the artifact exists, parses as
    `ASRBenchmark`, and has `wordCount > 0`. If any of these fail, the test **FAILS** with a
    message pointing at `scripts/setup-asr-models.sh` + the slow test — **never `XCTSkip`**
    (ADR-000 §6 / slice AC2: a missing artifact is a setup failure, not a skip).
  - `testTranscriptionWithinDriftTolerance` (AC1) — every word boundary in
    `benchmark.words` is within **±200 ms** of the golden boundary, and
    `benchmark.wordErrorCount ≤ 2`.

  The spike's transcription is **real** — recorded once by the slow test — and the fast test
  re-verifies its accuracy **without re-running inference**. This is the same "record once,
  assert against fixture" discipline ADR-002 used for the rendered mute mix.

  **Why the fast test must not run live ASR:** (a) the model is **gitignored** (`Models/`)
  and is not present in the fast CI checkout, so live inference cannot run there;
  (b) CPU-only simulator inference is **slow** (≈ 1.2–2.4 s per run for a 4.56 s clip — see
  §"Empirical validation") and would drag the fast suite; (c) determinism — asserting a
  committed artifact removes model-download/runtime variance from the Done gate.

- **SLOW (`ASRBenchmarkTests`, nightly only — NOT a Done gate).** Instantiates the real
  `WhisperKitASRTranscriber` against the pinned local model, transcribes
  `speech-pangram.wav` live, computes drift/error stats, and **regenerates**
  `benchmark-results.json` by writing to the **source** `Fixtures/asr/` path via a
  `#filePath`-relative URL (so the regenerated artifact can be committed). It asserts the
  live run still meets the drift/error thresholds. Because the model is gitignored, this
  target may skip only under the nightly `VERIFY_ALLOW_SKIPS=1` job (slice verification
  commands) — it is never part of the fast Done gate.

`benchmark-results.json` is therefore the **AC2 execution evidence** that the spike actually
ran; the slow test is the mechanism that produces/refreshes it, and the fast test is the gate
that proves accuracy deterministically.

**Slow-target isolation (resolves AC4 ∩ AC6).** `PodWashSlowTests` is added to the
`PodWash.xcscheme` test action as a `TestableReference` **with `skipped = "YES"`**. This
satisfies AC4 (the target **is a member** of the scheme's test action — present in
`<Testables>`, assertable structurally / via `xcodebuild -list`) while keeping the default
unfiltered `scripts/verify.sh` run from executing it — so the fast Done gate reports
**skipped = 0** (a scheme-disabled testable is *not run*, so it contributes **zero** executed
or skipped test cases; `verify.sh`'s skip count comes only from runtime `XCTSkip`, which this
slice forbids on core ACs).

Running the slow target for nightly/regeneration uses a **dedicated shared scheme**
`PodWashSlowTests.xcscheme` (the slow target as the only testable, `skipped = "NO"`, hosted on
`PodWash.app`). A `TestableReference` disabled with `skipped = "YES"` **cannot** be forced to
run via `-only-testing:` — xcodebuild rejects it as "not a member of the specified test plan
or scheme" (verified empirically). The dedicated scheme is therefore the sanctioned run path.
`scripts/verify.sh` gains a single backward-compatible env override, `PODWASH_SCHEME`
(default `PodWash`); the nightly job runs
`PODWASH_SCHEME=PodWashSlowTests VERIFY_ALLOW_SKIPS=1 scripts/verify.sh`. `verify.sh` is
otherwise unchanged and still never excludes targets from the default `PodWash` scheme.

**Fast-test assertion discipline (anti-circularity).** `testTranscriptionWithinDriftTolerance`
**recomputes** boundary drift and word-error count itself from `benchmark.words` versus the
independent golden — it does **not** trust the embedded `driftMaxMs` / `driftMeanMs` /
`wordErrorCount` fields (those are informational only). It also asserts the artifact's
`engine` / `model` / `modelRevision` / `computeUnits` match the pinned values (§3.6), so a
hand-faked artifact with the wrong provenance fails. Word comparison normalizes to lowercase
and strips non-alphanumerics (the pinned rule documented in the fixture README); alignment is
positional against the 9-word golden, and `wordCount != 9` counts toward the error budget.

### 3.5 Benchmark artifact schema

`PodWash/PodWashTests/Fixtures/asr/benchmark-results.json` — one encoded `ASRBenchmark`:

```json
{
  "engine": "WhisperKit",
  "engineVersion": "1.0.0",
  "model": "openai_whisper-tiny.en",
  "modelRevision": "97a5bf9bbc74c7d9c12c755d04dea59e672e3808",
  "computeUnits": "cpuOnly",
  "device": "iPhone 17 Pro Simulator / iOS 26.1",
  "audioSeconds": 4.56,
  "loadSeconds": 0,
  "transcriptionSeconds": 6.594,
  "realTimeFactor": 1.445,
  "wordCount": 9,
  "words": [ { "word": " The", "start": 0.2, "end": 0.56 } ],
  "driftMaxMs": 134,
  "driftMeanMs": 54,
  "wordErrorCount": 1
}
```

(`words` shown truncated to one entry — the committed artifact holds all 9, verbatim from
WhisperKit including leading spaces/casing; the scoring normalizes them.) The slow test
loads the model lazily inside `transcribe()`, so the committed `transcriptionSeconds` is the
**end-to-end cold** wall time (Core ML compile + model load + decode) and `loadSeconds` is
left `0`; `realTimeFactor` is therefore > 1 on the CPU-only simulator. The separately-measured
spike figures (≈ 4.0 s cold load, 1.2–2.4 s decode) are in the § "Empirical validation" table.
These timing fields are **informational only** — the fast test decodes this artifact and
asserts AC1/AC2 by **recomputing** drift/errors from `words`, ignoring the timing/stat fields;
the slow test re-encodes it after a live run.

### 3.6 Model pinning + setup

- **WhisperKit SPM dependency** pinned `exactVersion` **1.0.0** (no range) in the Xcode
  project's package resolution.
- **Model** `openai_whisper-tiny.en` from HuggingFace repo **`argmaxinc/whisperkit-coreml`**
  pinned at **exact revision `97a5bf9bbc74c7d9c12c755d04dea59e672e3808`**.
- **Compute** `.cpuOnly` for all components (mel / audioEncoder / textDecoder / prefill) —
  required for correct simulator output (§3.1 reason 2).
- `scripts/setup-asr-models.sh` downloads the pinned model folder into a **gitignored
  `Models/`** directory (AC3); it must fail loudly (non-zero exit) if the pinned revision is
  unavailable, and is documented in the fixture `README.md`.
- **`base.en` and larger models are simulator-incompatible** (empty output on CPU-only —
  §3.1 reason 2). `tiny.en` is therefore the **pinned simulator model**; evaluating larger
  models for production accuracy is a **real-device** concern (Consequences), not a
  simulator gate.

## Empirical validation (spike, 2026-07-08)

A throwaway probe (`PodWash/PodWashTests/_SpikeProbe.swift`, since deleted — **no spike code
remains**) ran both candidate stacks in the simulator and measured word-timing accuracy
against the hand-computed golden.

**Environment.** iPhone 17 Pro Simulator, iOS 26.1, Xcode 26.1.1, WhisperKit 1.0.0 (SPM,
`exactVersion`), Core ML compute `.cpuOnly` (all components). Model
`openai_whisper-tiny.en`, repo `argmaxinc/whisperkit-coreml`, revision
`97a5bf9bbc74c7d9c12c755d04dea59e672e3808`, downloaded into gitignored `Models/`.

**Fixture.** `speech-pangram.wav` — 4.56 s, 16 kHz mono, "the quick brown fox jumps over the
lazy dog" (9 words). Synthesized **word-by-word** via macOS `say` (voice Samantha), each word
silence-trimmed, concatenated with **0.05 s inter-word gaps** + **0.2 s lead/tail**. Golden
`asr_fixture_expected.json` word boundaries were computed from the **known concatenation
layout** (external-tool / hand-computed provenance — **not** from any ASR), with the
convention that each inter-word boundary sits at the **midpoint of the synthesized silent
gap** (the true boundary lies within that silence).

**SpeechAnalyzer probe (why it cannot gate CI).**

| Probe | Measured (iPhone 17 Pro Sim / iOS 26.1) | Consequence |
|-------|------------------------------------------|-------------|
| `SpeechTranscriber.supportedLocales` | **empty set (count = 0)** | no locale installable |
| `AssetInventory.status(forModules:)` for en-US | **`.unsupported`** | assets not provisioned |
| Attempted asset install | throws `SFSpeechErrorDomain Code=1 "... not subscribed to transcription.en"` | unverifiable in simulator → cannot gate CI |

**WhisperKit results** (deterministic across repeated runs; drift measured over all **18**
word boundaries = start+end of 9 words):

| Quantity | Measured | Target (AC) | Pass |
|----------|----------|-------------|------|
| Model | `tiny.en`, `.cpuOnly` | simulator-runnable | ✅ |
| Word count | **9** | = golden (9) | ✅ |
| Word error count | **1** (heard "fox" as "fock"; normalization strips punctuation) | ≤ 2 (AC1) | ✅ |
| Max boundary drift | **134 ms** | ≤ 200 ms (AC1) | ✅ |
| Mean boundary drift | **54 ms** | ≤ 200 ms (AC1) | ✅ |
| Boundaries within ±200 ms | **18 / 18** | all | ✅ |
| Model load (cold, incl. Core ML compile) | **≈ 4.0 s** | — | — |
| Transcription time (4.56 s clip) | **1.2–2.4 s** (RTF ≈ 0.26–0.52) | faster than real time | ✅ |
| `base.en` and larger (`.cpuOnly` sim) | **empty output** | — | ✗ (sim-incompatible; §3.1) |

The spike confirms `tiny.en` is the only WhisperKit model that transcribes correctly on the
CPU-only simulator, and that SpeechAnalyzer has no provisioned speech assets there. Both
findings are the basis for §3.1.

## Consequences

- **Resolves PRD §11 "On-device ASR choice"** in favor of WhisperKit `tiny.en` for the
  automated (simulator) pipeline; SpeechAnalyzer is **deferred to a documented future
  real-device evaluation**, not deleted.
- **iOS floor unchanged at 26.1** (ADR-000 §5). WhisperKit supports iOS 16+, so a future
  floor **lowering** to widen device support becomes *possible* — but that is a product
  decision to surface to the user (halt-and-ask), **not** made here.
- **Slice 07 (analyze-episode pipeline)** consumes `ASRTranscribing` → `[TimedWord]`,
  feeding the Slice 02 matcher. The wrapped protocol means Slice 07 depends only on the
  ADR-000 §4 schema, never on WhisperKit types.
- **Verification is a fast/slow split** (§3.4): the fast Done-gate test asserts the committed
  benchmark artifact against the independent golden (deterministic, no model needed); the
  slow nightly test regenerates the artifact via live WhisperKit. The fast suite stays green
  with **skipped = 0** (AC6); the slow target is a nightly job (AC4), never a Done gate.
- **Real-device accuracy/latency and SpeechAnalyzer** are **documented future automation
  targets**, explicitly **NOT dark-factory gates** — they cannot run in the simulator suite
  today.
- The **tiny.en 1-word error** on synthetic TTS reflects the **smallest** Whisper model on a
  synthetic voice; accuracy is expected to improve with larger models on real devices (a
  real-device concern per §3.6), and the ±200 ms / ≤2-error thresholds hold with margin
  (measured 134 ms max drift, 1 error) on the fixture.
- **New cross-cutting artifact:** the `PodWashSlowTests` target and the `benchmark-results.json`
  evidence convention are introduced here; later ASR/model slices reuse this
  record-once/assert-against-fixture pattern rather than gating on live inference.
