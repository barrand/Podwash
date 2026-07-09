# ASR spike fixtures (Slice 05)

Deterministic inputs + golden for the on-device ASR spike. See
[`docs/adr/003-asr-stack-choice.md`](../../../../docs/adr/003-asr-stack-choice.md) and
[`docs/slices/slice-05-asr-spike.md`](../../../../docs/slices/slice-05-asr-spike.md).

## Files

| File | What it is | Provenance |
|------|------------|------------|
| `speech-pangram.wav` | 4.56 s, 16 kHz mono, "the quick brown fox jumps over the lazy dog" (9 words) | Synthesized word-by-word (see below) — deterministic, committed |
| `asr_fixture_expected.json` | Golden `[TimedWord]` (ADR-000 §4) | **Hand-computed from the known concatenation layout** — NOT ASR output |
| `benchmark-results.json` | `ASRBenchmark` execution evidence | **Written by the `PodWashSlowTests` live WhisperKit run**, then committed |

## Model pin (AC3)

The ASR stack is **WhisperKit** (SPM `exactVersion` **1.0.0**) with the Core ML model
**`openai_whisper-tiny.en`** from HuggingFace repo `argmaxinc/whisperkit-coreml`, pinned at
the **exact revision** `97a5bf9bbc74c7d9c12c755d04dea59e672e3808`, run **CPU-only**.

Download the pinned model with:

```sh
scripts/setup-asr-models.sh
```

It lands in the **gitignored** `Models/whisperkit-coreml/openai_whisper-tiny.en/` directory
(never committed). `base.en` and larger models render empty output on the CPU-only
simulator and are therefore not usable in the dark-factory suite (ADR-003 §3.1).

## Golden provenance (independent — hard rule)

`asr_fixture_expected.json` is **not** produced by any ASR. The clip is synthesized
word-by-word via macOS `say` (voice Samantha), each word silence-trimmed, then concatenated
with **0.05 s inter-word gaps** and **0.2 s lead/tail** silence. Because the exact
per-word layout is known, each boundary is computed analytically with the convention that
**an inter-word boundary sits at the midpoint of the synthesized silent gap** (the true
boundary lies within that silence); the first word starts at `lead/2` and the last word
ends at `tail/2` past its trimmed audio. This makes the golden a hand-computed reference
independent of the code under test.

## Word normalization (pinned scoring rule)

Both the fast gate and the slow benchmark compare words after normalizing to **lowercase**
and **stripping non-alphanumerics** (`ASRScoring.normalize`). Alignment is positional
against the 9-word golden; a word-count mismatch counts toward the error budget.

## Regenerating `benchmark-results.json`

The artifact is refreshed by the **slow** test (nightly / manual — not the Done gate):

```sh
scripts/setup-asr-models.sh
# PodWashSlowTests is skipped="YES" in the PodWash scheme, so it runs via its own dedicated
# scheme (a skipped TestableReference cannot be forced with -only-testing:):
PODWASH_SCHEME=PodWashSlowTests VERIFY_ALLOW_SKIPS=1 scripts/verify.sh
```

`PodWashSlowTests/ASRBenchmarkTests` runs WhisperKit live and writes this file back to the
source tree. The fast `PodWashTests/ASRSpikeFixtureTests` (Done gate) then validates the
committed artifact against the golden without re-running inference.
