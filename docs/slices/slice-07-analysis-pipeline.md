# Slice 07 — Analyze-episode pipeline

| Field | Value |
|-------|-------|
| **ID** | 07 |
| **Title** | Analyze-episode pipeline |
| **Status** | Done |
| **Crux** | ASR → matcher → `IntervalBuilder` wired into one pipeline: a fixture episode with injected transcript produces a persisted interval list matching hand-computed golden JSON (±0.0005 s), a second run reuses the cache with **0** additional transcription calls, and the slow path proves live ASR output flows through the same stack (±200 ms on golden boundaries). |

## PRD / spec references

- PRD §6 — Analyze once → interval list (pipeline, caching; on-device ASR → matcher → cache)
- `docs/adr/000-foundations.md` §4 — `TimedWord` flows ASR → matcher; shared transcript schema
- `docs/specs/matching-spec.md` §3–§8 — matcher/interval rules; §7 seeded word lists; §8 hand-computed golden
- `docs/adr/003-asr-stack-choice.md` §3.2 — `ASRTranscribing` / `WhisperKitASRTranscriber` reused here

## Goal

Produce and persist the interval list for an episode; prove cache reuse. (Playback of those intervals is Slice 08; progress UI is Slice 09.)

## Deliverables

- `AnalysisPipeline`: audio file → `ASRTranscribing` (Slice 05 stack) → `WordMatcher` / `IntervalBuilder` (Slice 02) → interval list
- `IntervalCache` (or equivalent): on-disk interval cache keyed by **episode ID + normalized target-word-set fingerprint** (simple JSON store under a test-injectable base URL; durable DB integration in Slice 11)
- **Transcript-injection path** for fast tests: `analyze(episodeID:audioURL:targetWords:injectedTranscript:)` (or equivalent) skips ASR when a transcript is supplied
- **ASR spy / test double** conforming to `ASRTranscribing` for cache tests (records `transcribe` invocation count; returns fixture transcript)
- Fixtures under `PodWash/PodWashTests/Fixtures/analysis/` (see **Fixture strategy** below)
- `AnalysisPipelineTests` (fast, injected transcript + cache spies); full ASR-inclusive run in `PodWashSlowTests`
- Decision recorded: `docs/adr/005-analysis-pipeline.md` (module layout, cache key, injection seam)

## Fixture strategy (pinned — Engineer / QA)

### Fast path (AC1 — injected transcript, no live ASR)

**Decision: reuse Slice 02 `spec-section8` fixtures** — do **not** duplicate the transcript or recompute goldens.

| Asset | Path | Role |
|-------|------|------|
| Injected transcript | `PodWash/PodWashTests/Fixtures/transcripts/spec-section8.input.json` | 5-word `TimedWord` array from matching-spec §8 (ADR-000 §4) |
| Target word set | `{ "shit", "damn" }` | Same example-local set as spec §8 / Slice 02 |
| Golden intervals | `PodWash/PodWashTests/Fixtures/analysis/e2e_intervals.json` | **Byte-identical values** to `spec-section8.expected.json`: `[{0.92, 1.87}, {2.92, 3.32}]` — provenance cross-referenced in `Fixtures/analysis/analysis-provenance.md` (hand-computed from spec §3–§6, **not** pipeline output) |
| Fixture episode ID | `"fixture-spec-section8"` | Stable cache key for AC1–AC3 |
| Audio URL | Any committed local `.wav` path (e.g. `speech-pangram.wav`) | Required by API shape; **ignored** when `injectedTranscript` is non-nil |

A dedicated `e2e-pipeline.input.json` is **not** needed unless QA discovers bundling/path conflicts; the spec §8 transcript is canonical.

### Fast path (AC2 / AC3 — cache + spy)

Same episode ID and audio URL as AC1. Tests use the **ASR test double** (not injection bypass): first analysis calls `transcribe` **once** and returns `spec-section8.input.json` words. Assertions count **per-call** spy invocations (AC2: **0** on second identical call; AC3: **1** on re-analysis after word-list change).

**AC3 pinned word lists** (same episode, different cache keys):

- Run A target set: `{ "shit", "damn" }` (full §8 set)
- Run B target set: `{ "shit" }` only (strict subset — different fingerprint → cache miss)

### Slow path (AC4 — live ASR, nightly only)

**Decision: reuse `speech-pangram.wav`** — do **not** add a new audio clip. `WordProfiles.profanity` and `WordProfiles.harmless` contain **no tokens** present in the pangram transcript, so they are **not** used for AC4.

| Asset | Path | Role |
|-------|------|------|
| Audio clip | `PodWash/PodWashTests/Fixtures/asr/speech-pangram.wav` | 4.56 s pangram (Slice 05) |
| ASR reference transcript | `PodWash/PodWashTests/Fixtures/asr/asr_fixture_expected.json` | Independent golden for hand-computing slow goldens (not live ASR output) |
| Slow target set (pinned) | `{ "quick", "fox", "dog" }` | Tokens present in `asr_fixture_expected.json`; exercises matcher without profanity |
| Golden intervals | `PodWash/PodWashTests/Fixtures/analysis/slow_pipeline_intervals.json` | Hand-computed by applying matching-spec §3–§6 to `asr_fixture_expected.json` with the slow target set (document steps in `analysis-provenance.md`) |
| Assertion tolerance | **±200 ms** per interval `start`/`end` | Accounts for live WhisperKit drift (ADR-003 AC1); stricter ±0.0005 s applies only to injected-transcript fast tests |

If live ASR drift ever breaks AC4 despite ADR-003 bounds, **do not** loosen the threshold — regenerate `slow_pipeline_intervals.json` only if the hand-computation from `asr_fixture_expected.json` was wrong (never from pipeline output).

## Depends on

- Slices 02, 05

**Parallelizable:** With Slice 08 only after coordination — both touch pipeline/player seams; prefer sequential 07 → 08.

## Out-of-scope

- Playback application of intervals (Slice 08)
- Progress UI and toggles (Slice 09)
- Downloads of real episodes (Slice 10)
- Unrelated-content segmentation (Slices 18–19)
- Durable Core Data cache (Slice 11, ADR-007)
- UI for word-list / category selection (Slice 13)

## Acceptance criteria

Automatable only. **XCTSkip is not allowed on core ACs** — a mapped test that cannot run must fail.

- [x] 1. Integration test (injected transcript): fixture episode `fixture-spec-section8` with target set `{ "shit", "damn" }` → persisted interval list has **exactly 2** intervals; each `start`/`end` equals `e2e_intervals.json` within **±0.0005 s**; ASR spy records **0** `transcribe` calls (injection bypass).
- [x] 2. Unit test: analyze `fixture-spec-section8` twice with the same target set via the ASR test double → second result equals first (field-for-field); spy records **0** additional `transcribe` calls on the second invocation (exactly **1** total from both calls).
- [x] 3. Unit test: after AC2's cached run, re-analyze the same episode with target set `{ "shit" }` only → persisted intervals differ from the `{ "shit", "damn" }` run; spy records **1** additional `transcribe` call on that re-analysis.
- [x] 4. Slow test (`PodWashSlowTests`): full ASR-inclusive pipeline on `speech-pangram.wav` with slow target set `{ "quick", "fox", "dog" }` → produced interval count **≥ 1**; for **every** interval in `slow_pipeline_intervals.json`, some pipeline interval's `start`/`end` are each within **±200 ms** of the golden boundary (pairwise min-distance assert per field).
- [x] 5. Full fast suite green via `scripts/verify.sh` with **exit 0, failed 0, skipped 0**.

## Verification mapping

| AC# | Test file | Test method | Notes |
|-----|-----------|-------------|-------|
| 1 | `PodWash/PodWashTests/AnalysisPipelineTests.swift` | `testPipelineProducesGoldenIntervals` | Loads `spec-section8.input.json` + `e2e_intervals.json`; injects transcript (ASR bypass); asserts `intervals.count == 2`; per-field ±0.0005 s; spy call count == 0 |
| 2 | `PodWash/PodWashTests/AnalysisPipelineTests.swift` | `testSecondRunUsesCache` | ASR test double returns §8 transcript; two identical `analyze` calls; deep equality on intervals; spy records 0 calls on 2nd invoke (1 total) |
| 3 | `PodWash/PodWashTests/AnalysisPipelineTests.swift` | `testWordListChangeInvalidatesCache` | After cached `{shit,damn}` run, re-analyze with `{shit}`; intervals ≠ prior; spy +1 on re-analysis |
| 4 | `PodWash/PodWashSlowTests/FullPipelineSlowTests.swift` | `testFullASRPipelineCoversGoldenTimestamps` | Live WhisperKit on `speech-pangram.wav`; target `{quick,fox,dog}`; compares vs `slow_pipeline_intervals.json` ±200 ms; nightly only (scheme `skipped="YES"`) |
| 5 | — | — | Command-level: unfiltered `scripts/verify.sh` exit 0, failed 0, skipped 0 |

## Verification commands

```bash
# Fast inner loop (NOT sufficient for Done):
scripts/verify.sh -only-testing:PodWashTests/AnalysisPipelineTests

# Slow full-pipeline (nightly / manual; NOT a Done gate):
scripts/setup-asr-models.sh
PODWASH_SCHEME=PodWashSlowTests VERIFY_ALLOW_SKIPS=1 scripts/verify.sh

# Done gate — FULL fast suite:
scripts/verify.sh
```

## Verification record (QA fills at Verify)

> Paste the `VERIFY RESULT:` line from the full-suite `scripts/verify.sh` run here.
> A slice without a recorded full-suite green artifact is not Done.

```
VERIFY RESULT: exit=0 total=31 passed=31 failed=0 skipped=0 filtered=0 bundle=build/test-results/verify-20260709-091311.xcresult
```

Full unfiltered `scripts/verify.sh` run 2026-07-09 (simulator resolved dynamically). All 31 tests
(3 new Slice-07 fast tests + prior suite) passed, 0 failed, 0 skipped. Slow test
`FullPipelineSlowTests` is scheme-disabled (nightly only per ADR-005 §5).

## Plan review record (coordinator fills before downstream roles)

> Record readonly review outcomes before QA writes tests (ADR review) and before
> Engineer starts (test spec review). No record = next role must not spawn.
> See [`multitask-workflow.md`](../multitask-workflow.md) § Plan review gates.

```
ADR review (2026-07-09): QA cleared — fast ACs offline via injection + spy; slow AC4 nightly-only with ADR-003 ±200 ms budget; goldens independent (spec §8 + asr_fixture_expected hand-compute); no circular provenance. PM cleared — scope matches deliverables/out-of-scope; AC thresholds numeric; crux single hypothesis; no PRD §11 halt.
Test spec review (2026-07-09): Architect cleared — tests exercise ADR-005 public API (`analyze`, `IntervalCache`, injection seam, ASR spy); fast tests use temp cache dirs; slow test follows ADR-003 nightly pattern; thresholds match ACs (±0.0005 s, ±200 ms, spy counts).
```

## Done gate

- [x] Every AC mapped to a test; all rows in the mapping table filled
- [x] **Full suite green:** unfiltered `scripts/verify.sh` exit 0, failed 0, skipped 0
- [x] Verification record pasted above (exit code + counts + `.xcresult` path)
- [x] Auto-commit made on green: `slice-07: analyze-episode pipeline`

## Role artifacts

| Role | Gate | Artifact path |
|------|------|---------------|
| PM | Required | `docs/slices/slice-07-analysis-pipeline.md` (this file) |
| Architect | Required | `docs/adr/005-analysis-pipeline.md` — Accepted |
| UX | Waived | — (no user-facing analysis UI; Slice 09) |
| QA | Required | `PodWash/PodWashTests/AnalysisPipelineTests.swift`, `PodWash/PodWashSlowTests/FullPipelineSlowTests.swift`, `PodWash/PodWashTests/Fixtures/analysis/` |
| Engineer | Required | `PodWash/PodWash/AnalysisPipeline.swift` (+ cache module per ADR-005), wiring to `ASRTranscribing` / `WordMatcher` / `IntervalBuilder` |
