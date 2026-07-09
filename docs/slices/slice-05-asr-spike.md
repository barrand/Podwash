# Slice 05 — On-device ASR spike

| Field | Value |
|-------|-------|
| **ID** | 05 |
| **Title** | On-device ASR spike |
| **Status** | Draft |
| **Crux** | On-device ASR (`SpeechAnalyzer` vs WhisperKit) produces word-level timestamps for a bundled clip within tolerance of a golden transcript, with **execution evidence** (benchmark JSON artifact) that the spike actually ran. |

## PRD / spec references

- PRD §6 — Analyze once (ASR word timestamps); SpeechAnalyzer vs WhisperKit
- PRD §11 — Open decisions (ASR stack, minimum iOS version)
- `docs/adr/000-foundations.md` §4 (transcript schema — ASR **produces** `TimedWord`), §5 (iOS floor: this spike may confirm/raise it)

## Why this slice is early

The ASR choice drives the minimum iOS version (ADR-000 §5) and the transcript pipeline. It runs **in parallel with Slices 02/03/06** immediately after Slice 01 — not after the player work.

## Goal

Pick the ASR stack with data, produce `TimedWord` JSON for a bundled clip, and record the decision.

## Deliverables

- Spike comparing `SpeechAnalyzer` (iOS 26+) vs WhisperKit on a bundled 30–60 s clip
- Output conforms to the pinned `TimedWord` schema (ADR-000 §4)
- Golden `asr_fixture_expected.json` — provenance: human-verified transcript of the bundled clip (documented in fixture README), **not** output of the ASR under test
- **Benchmark JSON artifact** written by the harness to `PodWash/PodWashTests/Fixtures/asr/benchmark-results.json`: model, load time, transcription duration, word count, per-word drift stats
- `scripts/setup-asr-models.sh` — documented model pre-download with **pinned model version**; models land in gitignored `Models/`
- New **`PodWashSlowTests` target**, member of the `PodWash` scheme's test action (this activates the CI nightly job)
- `ASRSpikeFixtureTests` (fast); heavy benchmark runs in `PodWashSlowTests`
- Decision recorded: `docs/adr/003-asr-stack-choice.md` + PRD §11 updated

## Depends on

- Slice 01

**Parallelizable:** Yes — parallel with Slices 02, 03, 06.

## Out-of-scope

- Full-episode transcription pipeline (Slice 07)
- Matcher integration (Slice 07)
- Production model bundling / App Store size optimization
- Server-side ASR fallback

## Acceptance criteria

- [ ] 1. Fast test: transcribe the bundled clip → every word boundary within **±200 ms** of the golden transcript; word error count ≤ 2 for the fixture.
- [ ] 2. **Execution evidence:** test FAILS (does not skip) if `benchmark-results.json` is missing, unparsable, or has `wordCount == 0`. No `XCTSkip` — a missing model is a setup failure, surfaced by pointing at `scripts/setup-asr-models.sh`.
- [ ] 3. `scripts/setup-asr-models.sh` exists, pins an exact model version, and is documented in the fixture README.
- [ ] 4. `PodWashSlowTests` target exists and is a member of the `PodWash` scheme test action (structural assert or `xcodebuild -list` in CI).
- [ ] 5. Decision artifact: `docs/adr/003-asr-stack-choice.md` committed with benchmark numbers; PRD §11 ASR/iOS-floor items updated (per ADR-000 §5, raising the floor is tolerated; lowering it is a user decision — halt and ask).
- [ ] 6. Full suite (fast) green via `scripts/verify.sh` with skipped = 0.

## Verification mapping

| AC# | Test file | Test method | Notes |
|-----|-----------|-------------|-------|
| 1 | `PodWash/PodWashTests/ASRSpikeFixtureTests.swift` | `testTranscriptionWithinDriftTolerance` | TBD |
| 2 | `PodWash/PodWashTests/ASRSpikeFixtureTests.swift` | `testBenchmarkArtifactExistsAndNonEmpty` | Fails, never skips |
| 3 | — | — | Structural: script in repo |
| 4 | — | — | Structural: scheme membership |
| 5 | — | — | Artifact: ADR-003 + PRD update |
| 6 | — | — | Command-level |

## Verification commands

```bash
# One-time setup (pinned model download):
scripts/setup-asr-models.sh

# Fast inner loop:
scripts/verify.sh -only-testing:PodWashTests/ASRSpikeFixtureTests

# Slow benchmarks (nightly CI or manual; not the Done gate):
VERIFY_ALLOW_SKIPS=1 scripts/verify.sh -only-testing:PodWashSlowTests

# Done gate — FULL fast suite:
scripts/verify.sh
```

## Verification record (QA fills at Verify)

```
VERIFY RESULT: (pending)
```

## Done gate

- [ ] Every AC mapped to a test; all rows filled
- [ ] **Full suite green:** unfiltered `scripts/verify.sh` exit 0, failed 0, skipped 0
- [ ] Verification record pasted above
- [ ] Auto-commit on green: `slice-05: <short description>`

## Role artifacts

| Role | Gate | Artifact path |
|------|------|---------------|
| Architect | Required | `docs/adr/003-asr-stack-choice.md` (TBD) |
| UX | Waived | — (no user-facing ASR UI in spike) |
