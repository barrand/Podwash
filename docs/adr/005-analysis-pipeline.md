# ADR-005 — Analyze-episode pipeline: ASR → matcher → cache

| Field | Value |
|-------|-------|
| **Status** | Accepted |
| **Date** | 2026-07-09 |
| **Supersedes** | — |
| **Builds on** | [ADR-000](000-foundations.md) §4 (`TimedWord` schema), §6 (`scripts/verify.sh` full-suite gate); [ADR-003](003-asr-stack-choice.md) §3.2 (`ASRTranscribing` protocol, fast/slow split); Slice 02 `WordMatcher` / `IntervalBuilder` / `WordProfiles` |

## Context

Slice 07 wires the existing ASR stack (Slice 05) and matcher (Slice 02) into one
pipeline that produces and persists a censor interval list for an episode. The slice
must prove:

- **AC1** — injected transcript → persisted intervals match hand-computed golden
  within **±0.0005 s** (no live ASR).
- **AC2** — second analysis of the same episode + word list reuses cache; ASR spy
  records **0** additional `transcribe` calls.
- **AC3** — word-list change invalidates cache; spy records **1** additional call.
- **AC4** — slow nightly test: live WhisperKit → matcher → intervals cover golden
  boundaries within **±200 ms** (ADR-003 drift budget).
- **AC5/AC6** — full fast suite green, skipped = 0.

The crux is **one pipeline type** with a testable injection seam and a durable-enough
JSON cache keyed by episode identity + word-list fingerprint — without WhisperKit
types leaking into fast tests.

## Decision

### 1. Module layout / file boundaries

| File | Target | Status | Responsibility |
|------|--------|--------|----------------|
| `PodWash/PodWash/AnalysisPipeline.swift` | app | **new** | Orchestrates ASR → `IntervalBuilder.buildIntervals` → cache read/write. Public `analyze(...)` entry points. |
| `PodWash/PodWash/IntervalCache.swift` | app | **new** | On-disk JSON cache: read/write `[CensorInterval]` keyed by `(episodeID, targetFingerprint)`. Injectable `baseDirectory` for tests. |
| `PodWash/PodWashTests/AnalysisPipelineTests.swift` | PodWashTests (**FAST**) | **new (QA)** | AC1–AC3. Injected-transcript integration + ASR spy cache tests. |
| `PodWash/PodWashSlowTests/FullPipelineSlowTests.swift` | PodWashSlowTests | **new (QA)** | AC4. Live WhisperKit pipeline; nightly only (scheme `skipped="YES"`). |
| `PodWash/PodWashTests/Fixtures/analysis/e2e_intervals.json` | test | **new** | Golden intervals for fast AC1 — values identical to `spec-section8.expected.json`. |
| `PodWash/PodWashTests/Fixtures/analysis/slow_pipeline_intervals.json` | test | **new** | Hand-computed golden for slow AC4 (see §4). |
| `PodWash/PodWashTests/Fixtures/analysis/analysis-provenance.md` | test | **new** | Independent provenance for both goldens. |

No new WhisperKit files. The production pipeline uses `ASRTranscribing` (injected at
init); tests use a spy conforming to the same protocol.

### 2. Key API sketch

```swift
import Foundation

/// Stable episode identity for cache keys. Slice 11 may replace with persisted model IDs.
struct EpisodeIdentity: Hashable, Codable, Equatable {
    let id: String
}

/// On-disk JSON cache of merged censor intervals.
struct IntervalCache: Sendable {
    let baseDirectory: URL

    init(baseDirectory: URL)

    /// Deterministic fingerprint: sorted, normalized target words joined by `\n`.
    static func fingerprint(for targetWords: Set<String>) -> String

    func load(episodeID: String, targetWords: Set<String>) -> [CensorInterval]?
    func store(_ intervals: [CensorInterval], episodeID: String, targetWords: Set<String>) throws
    func clear() throws  // test helper — removes all cached files
}

/// ASR → matcher → cache pipeline.
final class AnalysisPipeline: @unchecked Sendable {
    private let transcriber: any ASRTranscribing
    private let cache: IntervalCache

    init(transcriber: any ASRTranscribing, cache: IntervalCache)

    /// Full path: check cache → ASR (if miss) → build intervals → persist → return.
    func analyze(
        episode: EpisodeIdentity,
        audioURL: URL,
        targetWords: Set<String>
    ) async throws -> [CensorInterval]

    /// Fast-test path: skip ASR when `injectedTranscript` is non-nil.
    func analyze(
        episode: EpisodeIdentity,
        audioURL: URL,
        targetWords: Set<String>,
        injectedTranscript: [TimedWord]?
    ) async throws -> [CensorInterval]
}
```

**Pipeline algorithm** (both overloads converge after transcript acquisition):

1. Compute `fingerprint = IntervalCache.fingerprint(for: targetWords)`.
2. If `cache.load(episodeID:episode.id, targetWords:)` returns intervals → return
   cached copy (**no ASR call**).
3. Obtain transcript: use `injectedTranscript` if non-nil; else
   `try await transcriber.transcribe(fileURL: audioURL)`.
4. `let intervals = IntervalBuilder.buildIntervals(from: transcript, targetSet: targetWords)`.
5. `try cache.store(intervals, episodeID:episode.id, targetWords:)`.
6. Return intervals.

`IntervalBuilder.buildIntervals` is the **only** matcher entry point — no duplicate
padding/merge logic (same discipline as ADR-002 AC1).

### 3. Cache key and on-disk format

**Cache key:** `(episodeID, targetFingerprint)` where `targetFingerprint` is the
sorted, newline-joined list of `WordMatcher.normalize(_:)` results for each word in
`targetWords` (empty strings dropped). Example:

```
episodeID = "fixture-spec-section8"
targetWords = { "shit", "damn" }
fingerprint = "damn\nshit"   // sorted normalized forms
```

**File path:** `{baseDirectory}/{episodeID}__{sha256(fingerprint)}.json`

Encoding: JSON array of `CensorInterval` (existing Codable type from Slice 02).

**Test isolation:** `IntervalCache(baseDirectory:)` accepts a per-test temp directory
created in `setUp` / torn down in `tearDown`. Production uses
`Application Support/IntervalCache/` (created on first write).

**Invalidation:** changing `targetWords` changes the fingerprint → different file →
cache miss → ASR runs again (AC3). No TTL or file-mtime invalidation in this slice.

### 4. Fixture strategy

#### Fast path (AC1 — injected transcript)

| Asset | Path | Notes |
|-------|------|-------|
| Transcript | `Fixtures/transcripts/spec-section8.input.json` | Reuse Slice 02 §8 fixture |
| Target set | `{ "shit", "damn" }` | Spec §8 example-local set |
| Golden | `Fixtures/analysis/e2e_intervals.json` | `[{0.92, 1.87}, {2.92, 3.32}]` — identical to `spec-section8.expected.json` |
| Episode ID | `"fixture-spec-section8"` | Stable cache key |

AC1 calls `analyze(..., injectedTranscript: words)` — ASR spy must record **0**
calls because injection bypasses transcription entirely.

#### Fast path (AC2 / AC3 — cache + spy)

Tests use `ASRSpyTranscriber` (defined in the test file) conforming to
`ASRTranscribing`:

```swift
final class ASRSpyTranscriber: ASRTranscribing {
    private(set) var transcribeCallCount = 0
    var wordsToReturn: [TimedWord] = []

    func transcribe(fileURL: URL) async throws -> [TimedWord] {
        transcribeCallCount += 1
        return wordsToReturn
    }
}
```

AC2: two identical `analyze(episode:audioURL:targetWords:)` calls (no injection).
First call: spy = 1, caches result. Second call: spy still 1 (cache hit).

AC3: after AC2, re-analyze with `targetWords = { "shit" }` only → spy = 2.

#### Slow path (AC4 — live ASR)

Reuse `speech-pangram.wav` (Slice 05). `WordProfiles` categories contain no pangram
tokens, so AC4 uses a **pinned slow target set** `{ "quick", "fox", "dog" }` — tokens
present in `asr_fixture_expected.json`.

Hand-computed golden `slow_pipeline_intervals.json` (matching-spec §3–§6 applied to
`asr_fixture_expected.json`):

| Token | Match? | Padded interval |
|-------|--------|-----------------|
| `quick` [0.603, 0.984] | yes | [0.523, 1.104] |
| `fox` [1.486, 1.954] | yes | [1.406, 2.074] |
| `dog` [3.983, 4.462] | yes | [3.903, 4.582] |

No merge (intervals disjoint). Golden count = **3**.

Slow assertion: for **every** golden interval, ∃ a pipeline interval whose `start`
and `end` are each within **±200 ms** of the golden values (pairwise min-distance
per field). Pipeline interval count ≥ 1. Live ASR drift is absorbed by the 200 ms
budget (ADR-003 measured max drift 134 ms on the same clip).

### 5. Verification architecture

Mirrors ADR-003 fast/slow split:

- **FAST (`AnalysisPipelineTests`)** — Done gate. No model, no live ASR. Uses
  injected transcript (AC1) and ASR spy (AC2/AC3). Temp cache directory per test.
- **SLOW (`FullPipelineSlowTests`)** — nightly only. Instantiates production
  `WhisperKitASRTranscriber` + `AnalysisPipeline`. Member of `PodWash` scheme with
  `skipped="YES"` (same pattern as ADR-003 §3.4). Run via
  `PODWASH_SCHEME=PodWashSlowTests VERIFY_ALLOW_SKIPS=1 scripts/verify.sh`.

### 6. ASR spy contract (test-only)

The spy lives in `AnalysisPipelineTests.swift` (test target), not the app target.
Engineer must **not** ship production spy types. The spy is the sanctioned way to
assert AC2/AC3 call counts without live inference.

## Consequences

- **Slice 08 (playback integration)** consumes `[CensorInterval]` from
  `AnalysisPipeline` / `IntervalCache` and wires them into `PlaybackEngine` via
  `IntervalScheduler`. The pipeline's public surface is `analyze(...) → [CensorInterval]`;
  Slice 08 does not re-run ASR.
- **Slice 11 (queue + resume)** may replace `IntervalCache`'s JSON files with Core Data
  (ADR-007); the `(episodeID, fingerprint)` key semantics carry forward.
- **Slice 09 (analysis UI)** triggers `analyze(...)` and observes progress; no UI in
  this slice.
- Fast suite stays **skipped = 0**; slow target remains scheme-disabled.
- PRD §11 "when to run analysis" remains undecided — this slice builds the pipeline
  only; trigger timing is out of scope.
