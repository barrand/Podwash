# ADR-012 — Content segmentation approach: sentence-scored (`heuristic-cue-v6.1`)

| Field | Value |
|-------|-------|
| **Status** | Accepted (amended 2026-07-16 — production approach `heuristic-cue-v6.1`) |
| **Date** | 2026-07-10 |
| **Supersedes** | — |
| **Builds on** | [ADR-000](000-foundations.md) §4 (`TimedWord` schema — segmenter **consumes** `[TimedWord]`), §6 (`scripts/verify.sh` full-suite gate); [ADR-003](003-asr-stack-choice.md) §3.4 (fast committed-artifact / slow regeneration pattern); [ADR-005](005-analysis-pipeline.md) (transcript-injection seam — Slice 19 wires the segmenter into the pipeline) |
| **Resolves** | Slice 18 spike — pick an on-device, transcript-based segmenter that meets precision ≥ 0.7 / recall ≥ 0.5 on a hand-golden fixture before Slice 19 integration |

## Amendment (2026-07-16) — `heuristic-cue-v6.1` / block stay + show-open exit

Production pin moves from `heuristic-cue-v6` to `heuristic-cue-v6.1`:

1. **Enter only on opener** — score-alone enter caused story false positives
2. **Brand-carry soft interiors** — keep contiguous midrolls through low-cue copy while the sponsor name is recent
3. **Post-closer hard exit** — first non-brand sentence after a closer leaves the block; `"It's…"`, `"back to…"`, and show/act opens are content
4. **Show-open does not block sponsor openers** — `"Support for today's show comes from …"` still enters

**Pinned `approach` string (AC4 / artifact):** `heuristic-cue-v6.1`

**Interval cache fingerprint** includes `segmenter:heuristic-cue-v6.1` (invalidates v6 caches).

Committed spike artifact: precision **1.0** / recall **1.0** (IoU ≥ 0.5 vs `golden_segments.json`).

## Amendment (2026-07-16) — `heuristic-cue-v6` / sentence-score + hysteresis (historical)

Production `HeuristicContentSegmenter` **replaced** span-grow / density / gap-snap (`heuristic-cue-v5`) with:

1. **Sentence grouping** (ASR punctuation + speech-gap ≥ 0.6 s fallback)
2. **One scoring model** — fuzzy openers/closers, second-person, CTA, price, **brand-name carry** after openers
3. **Two-state hysteresis** — enter on opener (or strong enter score); stay through low-cue hook sentences; exit on resume starters / sustained low scores / post-closer low run

URL/closer features are **stay/exit** only — they do not alone enter ad state (prevents educational `.edu` / `.gov` false positives).

**Pinned `approach` string (historical):** `heuristic-cue-v6`

**Eval:** `scripts/build_segmenter_cli.sh` builds a CLI from the shipped Swift sources; `ad_eval_score.py --detector swift-cli` measures the same algorithm. The Python `ad_eval_detector.py` span-grow mirror is **historical** (v5), not the production path.

**Corpus gate (evidence):** worst-episode time-weighted precision ≥ **0.98**, recall ≥ **0.95**, median boundary error ≤ **2.0 s**, tuned leave-one-show-out. Committed fixture floors remain Slice 18 IoU ≥ 0.5 with P ≥ 0.700 / R ≥ 0.500 on `spike_transcript.json`.

## Amendment (2026-07-14) — `heuristic-cue-v5` / span-grow-v1 (historical)

Production `HeuristicContentSegmenter` was **precision-first span-grow**:
high-precision opener anchors → grow through ad copy → snap to silence gaps →
merge pods (plus a URL-density path for DAI cold opens). Superseded by v6 above.

**Pinned `approach` string (historical):** `heuristic-cue-v5`

Offline laptop eval (`tmp/ad-eval/`, Whisper `tiny.en`) macro P/R ≈ 0.90 / 0.95
across TAL, Darknet Diaries, AI Daily Brief, and Cougar Sports used a permissive
segment IoU metric that under-penalized boundary bleed.

## Context

PRD §4 (Differentiator 2) requires on-device detection of superfluous / tangential
spans (which can include ads), framed as content curation, **off by default**.
PRD §6 analyze-once produces an interval list from ASR timestamps **plus**
segmentation; Slice 07 already delivers `[TimedWord]` via `ASRTranscribing` and
the analysis pipeline. Slice 18 proves segmentation is **feasible** before
Slice 19 merges segment intervals with profanity intervals, settings toggles, and
skip-override UI.

Binding constraints from the slice:

- **AC1** — committed `benchmark-results.json` recomputed vs `golden_segments.json`
  with temporal IoU ≥ 0.5 matching → precision ≥ **0.700**, recall ≥ **0.500**;
  `approach` non-empty; `segments` ≥ 1.
- **AC2** — missing / unparsable / `segmentCount == 0` artifact → **FAIL** (never
  `XCTSkip`); message points at regeneration path when applicable.
- **AC3** — golden has ≥ 2 segments, each duration ≥ 5.0 s, total positive ≥ 15.0 s.
- **AC4** — this ADR cites committed precision/recall (±0.001) and the `approach`
  string matching the artifact.
- **AC5/AC6** — slow target scheme membership if used; full fast suite green,
  skipped = 0.

Threshold policy: if AC1 cannot be met after good-faith spike work → **halt-and-ask**
(do not silently lower thresholds).

The crux is: **which on-device approach, consuming only `[TimedWord]`, produces
segment ranges that pass the IoU metric on an independently labeled synthetic
fixture, with committed execution evidence and a stable public API for Slice 19?**

This is **algorithm / lexicon design**, not a framework-renderer claim (unlike
ADR-002 audio mix or ADR-003 ASR). Empirical validation is the spike harness
itself (§ Empirical validation), not a pre-QA framework probe.

## Decision

### 3.1 Approach choice — `heuristic-cue-v1` (`HeuristicContentSegmenter`)

PodWash uses a **deterministic heuristic cue scorer** over the timed transcript:

1. **Normalize** each `TimedWord.word` (lowercase; strip leading/trailing
   non-alphanumerics) and build a linear token stream with start/end times.
2. **Establish an on-topic anchor** from the opening window (first **~20 s** or
   first **~80** tokens, whichever ends first): bag of content tokens excluding a
   small English stop list. This is the “story” lexicon for the fixture episode.
3. **Score sliding windows** (~8–12 s, step ~2–3 s) with a weighted sum of:
   - **Sponsor / promo cues** (strong): e.g. `sponsor`, `sponsored`, `brought to
     you`, `use code`, `promo`, `discount`, `ad break`, `advertisement`,
     `our friends at`, `check out`, `link in the description` (multi-word phrases
     matched on the joined window text).
   - **Tangent / digression cues** (medium): e.g. `side note`, `tangent`,
     `unrelated`, `anyway`, `before we continue`, `speaking of`, `real quick`.
   - **Topic drift** (supporting): low overlap between window content tokens and
     the on-topic anchor (Jaccard or token-hit rate below a pinned threshold),
     only when at least one cue fired or drift is extreme.
4. **Binarize** windows above a pinned score threshold as positive; **merge**
   overlapping / adjacent positives into contiguous ranges; drop ranges shorter
   than **5.0 s** (aligns with golden integrity); snap range bounds to the
   enclosing `TimedWord` start/end so segments sit on word boundaries.
5. Return disjoint `[{start, end}]` positive-class ranges only (no action field —
   Slice 19 maps ranges → `CensorInterval` with user-chosen skip/mute).

**Why heuristic for the MVP spike**

| Criterion | Heuristic cue | Embedding drift | On-device LLM |
|-----------|---------------|-----------------|--------------|
| Simulator / CI determinism | Exact | Soft / model-dependent | Soft / availability-dependent |
| Fast Done gate (no model) | Yes | Often needs model assets | Heavy |
| Hits P≥0.7 / R≥0.5 on a *scripted* separable fixture | Yes (fixture authored with clear cues) | Possible but overkill | Overkill |
| On-device, no server | Yes | Yes (`NLEmbedding`) | Conditional |
| Slice 19 import surface | Stable protocol | Same protocol, swap impl | Same |

The fixture strategy (slice § Fixture strategy) **requires** clearly separable
on-topic vs tangential/ad-like passages. That is exactly the regime where a
transparent cue lexicon + light topic-drift check is the smallest verifiable
proof of Differentiator 2 feasibility. Quality iteration (embeddings, better
discourse models) is deferred — not deleted — see Rejected alternatives.

**Pinned `approach` string (AC4 / artifact):** `heuristic-cue-v6.1` (was `heuristic-cue-v6` / `heuristic-cue-v5` / `heuristic-cue-v1` earlier; see Amendments above)

### 3.2 Module layout / file boundaries

| File | Target | Status | Responsibility |
|------|--------|--------|----------------|
| `PodWash/PodWash/ContentSegmenting.swift` | app | **new** | Protocol `ContentSegmenting`, `ContentSegment` (start/end), `SegmentationBenchmark` (Codable artifact schema). **No** NaturalLanguage / ML types on this surface. |
| `PodWash/PodWash/HeuristicContentSegmenter.swift` | app | **new** | `heuristic-cue-v1` implementation. Cue tables + window/merge constants live here (or as `private` enums in the same file). Only concrete segmenter shipped by this spike. |
| `PodWash/PodWashTests/SegmentationSpikeTests.swift` | PodWashTests (**FAST**) | **new (QA)** | AC1–AC5. Loads committed artifact + golden; recomputes IoU P/R; never runs “creative” labeling. |
| `PodWash/PodWashSlowTests/SegmentationBenchmarkTests.swift` | PodWashSlowTests | **new (QA)** | Regenerates `benchmark-results.json` by running production `HeuristicContentSegmenter` on `spike_transcript.json`. Nightly / manual; **NOT** a Done gate. Reuses existing slow-target scheme pattern (ADR-003 §3.4). |
| `PodWash/PodWashTests/Fixtures/segmentation/spike_transcript.json` | test | **new** | `[TimedWord]` ≥ 60 s synthetic scripted episode. |
| `PodWash/PodWashTests/Fixtures/segmentation/golden_segments.json` | test | **new** | Hand-labeled positive ranges only. |
| `PodWash/PodWashTests/Fixtures/segmentation/benchmark-results.json` | test | **new (execution evidence)** | Written by slow regeneration (or implement-gate one-shot via the same code path); committed. |
| `PodWash/PodWashTests/Fixtures/segmentation/segmentation-provenance.md` | test | **new** | Who labeled what; script outline; **never** generated by the segmenter. |

IoU matching + precision/recall helpers used by fast tests live in the **test
target** (e.g. private helpers in `SegmentationSpikeTests` or a small test-only
`SegmentationMetrics.swift`). Production code returns segments only; it does not
score itself against the golden (anti-circularity).

**Out of this slice’s file set:** `AnalysisPipeline`, settings, playback,
`CensorInterval` merge — Slice 19.

### 3.3 Key API sketch

```swift
import Foundation

/// Positive-class superfluous / tangential span (seconds from episode start).
/// Slice 19 maps these to `CensorInterval` with the user-selected action.
struct ContentSegment: Codable, Equatable, Sendable {
    let start: Double
    let end: Double
}

/// On-device segmenter over an ASR transcript. Implementations must be
/// deterministic for a given `[TimedWord]` input (required for committed
/// execution evidence).
protocol ContentSegmenting: Sendable {
    /// Stable approach id written into `SegmentationBenchmark.approach`
    /// (e.g. `"heuristic-cue-v1"`).
    var approachIdentifier: String { get }

    /// Returns disjoint positive segments with `end > start`. Empty array is a
    /// valid algorithmic outcome but fails AC2 if written as the committed
    /// artifact (`segmentCount == 0`).
    func segments(in transcript: [TimedWord]) -> [ContentSegment]
}

/// Execution-evidence record for one benchmark run. Codable →
/// `Fixtures/segmentation/benchmark-results.json`.
struct SegmentationBenchmark: Codable, Equatable, Sendable {
    let approach: String              // must equal segmenter.approachIdentifier
    let precision: Double             // informational; fast test recomputes
    let recall: Double                // informational; fast test recomputes
    let segmentCount: Int             // == segments.count; AC2 requires > 0
    let segments: [ContentSegment]
    let durationSeconds: Double       // wall time for segments(in:)
    let inferenceSeconds: Double      // same as duration for heuristic; reserved for ML impls
}
```

Concrete type:

```swift
/// Deterministic cue + light topic-drift segmenter (§3.1).
struct HeuristicContentSegmenter: ContentSegmenting {
    var approachIdentifier: String { "heuristic-cue-v1" }

    func segments(in transcript: [TimedWord]) -> [ContentSegment] {
        // normalize → anchor → window scores → threshold → merge → min-duration
    }
}
```

**Invariants**

- Input schema is exactly ADR-000 §4 `TimedWord`; no audio URL on this surface.
- Output carries **no** `CensorAction` — keeps Differentiator 2 action choice in
  Settings / Slice 19.
- `HeuristicContentSegmenter` is a value type with no shared mutable state
  (safe to call from the analysis pipeline actor later).

### 3.4 Metric contract (pinned — AC1)

Treat each golden range as one positive instance. Match predictions to goldens
with **greedy one-to-one assignment by highest temporal IoU**, accepting a pair
iff IoU ≥ **0.5**:

\[
\mathrm{IoU}(a,b) = \frac{|a \cap b|}{|a \cup b|}
\]

- **TP** — matched pairs  
- **FP** — unmatched predictions  
- **FN** — unmatched goldens  
- **Precision** = TP / (TP + FP) (if TP+FP = 0 → precision 0 for AC purposes)  
- **Recall** = TP / (TP + FN)

Fast test **recomputes** precision/recall from `benchmark.segments` vs
`golden_segments.json`. Embedded `precision` / `recall` fields in the artifact
are informational only (same anti-circularity rule as ADR-003 drift fields).

### 3.5 Verification architecture

Mirrors ADR-003’s record-once / assert-against-fixture split:

- **FAST (`SegmentationSpikeTests`, Done gate).** Bundle-loads committed
  `benchmark-results.json` + `golden_segments.json` + asserts ADR-012 exists.
  - `testBenchmarkArtifactExistsAndNonEmpty` (AC2) — fail hard on missing /
    unparsable / `segmentCount == 0`; message cites
    `PodWashSlowTests/SegmentationBenchmarkTests` regeneration.
  - `testPrecisionRecallAgainstGolden` (AC1) — recompute IoU P/R; assert
    ≥ 0.700 / ≥ 0.500; `approach` non-empty; `segments.count ≥ 1`.
  - `testGoldenFixtureIntegrity` (AC3).
  - `testDecisionArtifactRecorded` (AC4) — ADR path exists; parse cited
    precision/recall/approach and match artifact ±0.001 / exact string.
  - `testSlowTestTargetInSchemeIfPresent` (AC5) — no-op if absent; else
    `PodWashSlowTests` TestableReference with `skipped="YES"`.

  Fast tests **must not** invent golden labels and **must not** depend on live
  “smart” inference beyond decoding JSON.

- **SLOW (`SegmentationBenchmarkTests`, nightly / manual — NOT Done gate).**
  Decode `spike_transcript.json`, run `HeuristicContentSegmenter().segments(in:)`,
  compute informational P/R vs golden, encode `SegmentationBenchmark`, write to
  the **source** `Fixtures/segmentation/benchmark-results.json` via a
  `#filePath`-relative URL (same write discipline as ADR-003). Assert live P/R
  still meet thresholds so regeneration cannot silently regress.

Heuristic runtime is negligible, but regeneration still lives in
`PodWashSlowTests` so the fast suite never writes fixtures and the evidence path
stays identical if a future embedding impl replaces the concrete type.

**Scheme:** existing `PodWashSlowTests` membership with `skipped="YES"` on the
default `PodWash` scheme (ADR-003). Regeneration:

```bash
PODWASH_SCHEME=PodWashSlowTests VERIFY_ALLOW_SKIPS=1 scripts/verify.sh \
  -only-testing:PodWashSlowTests/SegmentationBenchmarkTests
```

### 3.6 Fixture authoring contract (QA / Engineer)

| Asset | Rules |
|-------|-------|
| `spike_transcript.json` | Synthetic scripted dialogue as `[TimedWord]`; total span ≥ **60 s**; clearly separable on-topic body vs ≥ 2 tangential/ad-like passages that use the cue lexicon (so the hypothesis is testable, not mystical). |
| `golden_segments.json` | `[{ "start", "end" }]` only; ≥ **2** disjoint positives; each duration ≥ **5.0 s**; total positive duration ≥ **15.0 s**; labeled by a person from the script — **never** from segmenter output. |
| `segmentation-provenance.md` | Script outline, labeler identity/role, why each positive span is superfluous/tangential, confirmation labels are independent of the heuristic. |

**Anti-cheat:** do not tune the golden to the segmenter after seeing predictions.
If the first good-faith run misses AC1, adjust **cue tables / thresholds** or
**halt-and-ask** — do not rewrite goldens to match predictions.

### 3.7 Rejected alternatives

| Alternative | Why rejected for Slice 18 |
|-------------|---------------------------|
| **`NLEmbedding` / sentence-embedding topic drift** (`EmbeddingContentSegmenter`) | Viable future upgrade behind `ContentSegmenting`, but adds model/asset variance and weaker determinism for a scripted spike whose point is feasibility + API. Defer to a quality-iteration slice if heuristic plateaus on real episodes. |
| **On-device generative LLM / Foundation Models** | Non-uniform availability, slow, non-deterministic enough to fight the dark-factory gate; out of scope for proving the interval-list seam. |
| **Server-side segmentation** | Explicitly out of scope (slice + PRD serverless-first). |
| **Audio-only ad/jingle detectors** | Different input modality; spike is transcript-based per PRD §6 / ADR-000 §4. |
| **Merging with profanity intervals / settings / skip UI** | Slice 19. |

## Empirical validation (spike step — required before Done)

Unlike ADR-002/003, this decision does **not** claim opaque framework renderer
behavior that must be measured before QA writes tests. Validation **is** the
slice:

1. QA authors fixtures + provenance per §3.6 (independent labels first).
2. Engineer implements `ContentSegmenting` + `HeuristicContentSegmenter`.
3. Slow harness (or implement one-shot through the **same** production type)
   writes `benchmark-results.json`.
4. Fast tests recompute IoU P/R; implement gate updates § Benchmark results
   below so AC4 matches the artifact ±0.001.
5. If precision < 0.700 or recall < 0.500 after good-faith cue/threshold
   iteration → **halt-and-ask** (slice threshold policy).

Design-time expectation (not a substitute for the artifact): on a fixture whose
positive spans are authored around the §3.1 cue lexicon, greedy IoU matching
should clear the thresholds with margin. The committed JSON is the only
execution evidence that counts.

## Benchmark results

Filled from the committed
`PodWash/PodWashTests/Fixtures/segmentation/segmentation-benchmark-results.json`
(AC4). Values match the artifact / recomputed IoU score within ±0.001:

| Field | Value |
|-------|-------|
| **approach** | `heuristic-cue-v6.1` |
| **precision** | 1.000 |
| **recall** | 1.000 |
| **segmentCount** | 2 |
| **durationSeconds / inferenceSeconds** | 0.001 / 0.001 |

## Consequences

- **Slice 19** imports `ContentSegmenting` / `ContentSegment` only — injects the
  concrete segmenter into `AnalysisPipeline`, maps segments → `CensorInterval`
  with the unrelated-content action, honors **off by default**.
- **No change** this slice to `TimedWord`, `PlaybackEngine`, `IntervalScheduler`,
  or profanity `IntervalBuilder` math — parallel-safe with Slices 22–23 if those
  shared modules are untouched.
- **Verification** stays dark-factory: committed artifact + recomputed IoU
  metrics; no perceptual “sounds like an ad” gate.
- **Legal / product framing** unchanged: content curation, off by default
  (PRD §4/§8); attorney review remains a launch gate, not a factory gate.
- **Future quality work** may add `EmbeddingContentSegmenter` behind the same
  protocol without revising Slice 19’s integration surface; a superseding ADR
  would record a new `approach` string and fresh benchmark artifact.
