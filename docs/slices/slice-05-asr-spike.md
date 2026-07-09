# Slice 05 — On-device ASR spike

| Field | Value |
|-------|-------|
| **ID** | 05 |
| **Title** | On-device ASR spike |
| **Status** | Done |
| **Crux** | On-device ASR (WhisperKit `tiny.en`, chosen over `SpeechAnalyzer` per ADR-003 — SpeechAnalyzer is unverifiable in the simulator) produces word-level timestamps for a bundled clip within ±200 ms of a golden transcript, with **execution evidence** (committed benchmark JSON artifact) that the spike actually ran. |

## PRD / spec references

- PRD §6 — Analyze once (ASR word timestamps); SpeechAnalyzer vs WhisperKit
- PRD §11 — Open decisions (ASR stack, minimum iOS version)
- `docs/adr/000-foundations.md` §4 (transcript schema — ASR **produces** `TimedWord`), §5 (iOS floor: this spike may confirm/raise it)

## Why this slice is early

The ASR choice drives the minimum iOS version (ADR-000 §5) and the transcript pipeline. It runs **in parallel with Slices 02/03/06** immediately after Slice 01 — not after the player work.

## Goal

Pick the ASR stack with data, produce `TimedWord` JSON for a bundled clip, and record the decision.

## Deliverables

- Spike comparing `SpeechAnalyzer` (iOS 26+) vs WhisperKit — **decided: WhisperKit `tiny.en`** (ADR-003; SpeechAnalyzer has no provisioned speech assets in the iOS Simulator, so it cannot gate the dark-factory pipeline)
- Bundled clip `PodWash/PodWashTests/Fixtures/asr/speech-pangram.wav` — a **~4.6 s** deterministic synthetic-speech fixture (see clip-duration note below), output conforms to the pinned `TimedWord` schema (ADR-000 §4)
- Golden `asr_fixture_expected.json` — provenance: word boundaries **hand-computed from the known per-word concatenation layout** (external-tool/analytic provenance documented in the fixture README), **not** output of the ASR under test
- **Benchmark JSON artifact** at `PodWash/PodWashTests/Fixtures/asr/benchmark-results.json` — **written by the slow benchmark test** and committed: engine/version, model, model revision, compute units, device, load time, transcription duration, real-time factor, word count, words (`[TimedWord]`), per-word drift stats
- App-target ASR modules `PodWash/PodWash/ASRTranscribing.swift` (protocol + `ASRBenchmark`) and `PodWash/PodWash/WhisperKitASRTranscriber.swift` (WhisperKit wrapper) — reused by Slice 07 (ADR-003 §3.2)
- `scripts/setup-asr-models.sh` — documented model pre-download with **pinned exact model revision**; models land in gitignored `Models/`
- New **`PodWashSlowTests` target**, member of the `PodWash` scheme's test action **with `skipped="YES"`** (present for AC4 + nightly CI; excluded from the default fast `verify.sh` run so AC6 stays `skipped=0` — ADR-003 §3.4)
- `ASRSpikeFixtureTests` (fast, Done gate — validates the committed artifact + golden, no live ASR); heavy live benchmark runs in `PodWashSlowTests` (nightly)
- Decision recorded: `docs/adr/003-asr-stack-choice.md` + PRD §11 (and §6/§7 prose) updated

**Clip-duration note (PM):** the original draft said 30–60 s. The dark-factory fixture is intentionally **~4.6 s**: it must be a small, committed, deterministic clip with an independent hand-computed golden and it runs through CPU-only simulator inference in the nightly slow suite. A 30–60 s clip would bloat the repo, be impossible to golden by hand, and slow the benchmark with no added verification value. Full-episode-length transcription is Slice 07 scope.

## Depends on

- Slice 01

**Parallelizable:** Yes — parallel with Slices 02, 03, 06.

## Out-of-scope

- Full-episode transcription pipeline (Slice 07)
- Matcher integration (Slice 07)
- Production model bundling / App Store size optimization
- Server-side ASR fallback

## Acceptance criteria

- [x] 1. Fast test: from the **committed `benchmark-results.json`** (real transcription output produced by the WhisperKit slow test), every word boundary is within **±200 ms** of the golden transcript and word error count ≤ 2 for the fixture. The test **recomputes** drift/word-errors from `benchmark.words` vs the independent golden (does not trust embedded stat fields) and asserts the artifact's `engine`/`model`/`modelRevision`/`computeUnits` match the pinned values. (Live transcription happens in `PodWashSlowTests`, which produces/refreshes the artifact.)
- [x] 2. **Execution evidence:** the fast test FAILS (does not skip) if `benchmark-results.json` is missing, unparsable, or has `wordCount == 0`. No `XCTSkip`. The failure message points at `scripts/setup-asr-models.sh` + `PodWashSlowTests` (a missing model blocks only the slow regeneration path, never the fast gate).
- [x] 3. `scripts/setup-asr-models.sh` exists, pins an **exact** model revision, and is documented in the fixture README.
- [x] 4. `PodWashSlowTests` target exists and is a member of the `PodWash` scheme test action (structural assert on `PodWash.xcscheme`; `skipped="YES"` so it is present but excluded from the default fast run).
- [x] 5. Decision artifact: `docs/adr/003-asr-stack-choice.md` committed with benchmark numbers; PRD §11 ASR/iOS-floor items (and §6/§7 prose) updated (per ADR-000 §5, floor stays 26.1 — not lowered, so no halt).
- [x] 6. Full suite (fast) green via `scripts/verify.sh` with skipped = 0.

## Verification mapping

| AC# | Test file | Test method | Notes |
|-----|-----------|-------------|-------|
| 1 | `PodWash/PodWashTests/ASRSpikeFixtureTests.swift` | `testTranscriptionWithinDriftTolerance` | Recomputes drift/errors from committed `benchmark.words` vs golden (±200 ms, ≤2); asserts pinned engine/model/revision/compute |
| 2 | `PodWash/PodWashTests/ASRSpikeFixtureTests.swift` | `testBenchmarkArtifactExistsAndNonEmpty` | Fails (never skips) on missing/unparsable/`wordCount==0` |
| 3 | `PodWash/PodWashTests/ASRSpikeFixtureTests.swift` | `testSetupModelsScriptPinsExactRevision` | Structural: script exists + contains pinned revision; README documents it |
| 4 | `PodWash/PodWashTests/ASRSpikeFixtureTests.swift` | `testSlowTestTargetInScheme` | Structural: `PodWash.xcscheme` contains a `PodWashSlowTests` TestableReference |
| 5 | `PodWash/PodWashTests/ASRSpikeFixtureTests.swift` | `testDecisionArtifactsRecorded` | Structural: ADR-003 exists with benchmark numbers; PRD §11 marks the decision resolved |
| 6 | — | — | Command-level: unfiltered `scripts/verify.sh` exit 0, skipped 0 |
| — (live) | `PodWash/PodWashSlowTests/ASRBenchmarkTests.swift` | `testWhisperKitBenchmarkAndRegenerateArtifact` | Nightly only (NOT a Done gate): live WhisperKit run; regenerates `benchmark-results.json`; asserts drift/errors |

## Verification commands

```bash
# One-time setup (pinned model download):
scripts/setup-asr-models.sh

# Fast inner loop:
scripts/verify.sh -only-testing:PodWashTests/ASRSpikeFixtureTests

# Slow benchmarks (nightly CI or manual; not the Done gate). PodWashSlowTests is skipped="YES"
# in the PodWash scheme, so it runs via its dedicated scheme (a skipped testable cannot be
# forced with -only-testing:):
PODWASH_SCHEME=PodWashSlowTests VERIFY_ALLOW_SKIPS=1 scripts/verify.sh

# Done gate — FULL fast suite:
scripts/verify.sh
```

## Verification record (QA fills at Verify)

```
VERIFY RESULT: exit=0 total=23 passed=23 failed=0 skipped=0 filtered=0 bundle=build/test-results/verify-20260709-032834.xcresult
```

Full unfiltered `scripts/verify.sh` (scheme PodWash) — the `PodWashSlowTests` target is a
scheme member with `skipped="YES"` so it is not executed by the Done gate (skipped=0). The
committed `benchmark-results.json` was produced by the live slow test
(`PODWASH_SCHEME=PodWashSlowTests VERIFY_ALLOW_SKIPS=1 scripts/verify.sh` → exit=0 total=1
passed=1): WhisperKit `tiny.en` CPU-only, 9 words, recomputed max drift 134 ms, mean 54 ms,
1 word error ("Fock"→"fox"), all 18 boundaries within ±200 ms.

## Plan review record

> Readonly review outcomes (see [`multitask-workflow.md`](../multitask-workflow.md) § Plan review gates).

```
ADR review (2026-07-08):
  QA cleared — WITH one blocker (now RESOLVED): AC4∩AC6 slow-target isolation. Resolved in
    ADR-003 §3.4: PodWashSlowTests joins the scheme with skipped="YES" (member for AC4;
    excluded from default verify.sh so AC6 stays skipped=0; nightly forces it via -only-testing).
    QA recommendations folded in: fast test recomputes drift/errors from benchmark.words (not
    embedded stats), asserts pinned engine/model/revision/compute, normalizes words
    (lowercase+strip non-alphanumerics), and loads the artifact from the test bundle.
    Golden provenance confirmed independent (hand-computed layout, not ASR output); generation
    commands documented in the fixture README.
  PM cleared — WITH one blocker (now RESOLVED): AC1 wording ("transcribe" implied live inference).
    Resolved by rewriting AC1/AC2 to the committed-artifact validation and updating the crux,
    deliverables (clip ~4.6 s + rationale, app-target modules, golden provenance), and adding a
    PRD §6/§7 prose update to AC5. No halt-and-ask: iOS floor stays 26.1 (not lowered).
Test spec review (2026-07-08): Architect (readonly) — CLEARED, no blockers. All ACs 1–6
    mapped to concrete assertions; AC1 recomputes drift/errors from benchmark.words (not
    embedded stats) + asserts pinned provenance; AC2 fails (never skips); XCTSkip confined to
    the slow target's model-absent path; WhisperKit imported in exactly one file; slow-target
    isolation (skipped="YES") correct; #filePath path assumptions verified against on-disk
    layout. Two NITs: (1) AC4 test now also asserts skipped="YES" (applied); (2) slow-test
    loadSeconds is informational-only and left at 0 (fast gate ignores timings). Noted
    dependency: benchmark-results.json must be generated by the slow test + committed before
    AC1/AC2/AC6 pass (intended execution-evidence workflow, ADR-003 §3.4).
```

## Done gate

- [x] Every AC mapped to a test; all rows filled
- [x] **Full suite green:** unfiltered `scripts/verify.sh` exit 0, failed 0, skipped 0
- [x] Verification record pasted above
- [x] Auto-commit on green: `slice-05: on-device ASR spike (WhisperKit tiny.en)`

## Role artifacts

| Role | Gate | Artifact path |
|------|------|---------------|
| Architect | Required | `docs/adr/003-asr-stack-choice.md` (done) |
| UX | Waived | — (no user-facing ASR UI in spike) |
