# PodWash test fixtures

This directory holds deterministic inputs and **golden** expected outputs for
`PodWashTests`: transcripts (`TimedWord` JSON per ADR-000 §4), synthetic audio,
RSS/feed samples, and expected matcher/interval outputs. UI-test fixtures that
must be readable by the UI bundle live under `PodWash/PodWashUITests/Fixtures/`
instead (UI tests cannot read the unit-test bundle).

## Layout conventions

- One subject per fixture; name by what it represents, not by the test that
  reads it (e.g. `profanity-basic.transcript.json`, `two-word-mute.expected.json`).
- Pair each golden with its input using a shared stem: `<case>.input.*` and
  `<case>.expected.*`.
- Keep committed audio small (< ~1 MB each). `.gitignore` ignores `*.m4a`,
  `*.mp3`, `*.wav` globally but **un-ignores** everything under this directory
  (`!PodWash/PodWashTests/Fixtures/**`). Document local setup for anything larger
  rather than committing it.
- JSON uses seconds as `Double` and the shared schema from ADR-000 §4:
  `[ { "word": String, "start": Double, "end": Double } ]`.

## Golden provenance (hard rule)

Every golden (expected intervals, expected transcripts, expected feed JSON) must
have **provenance that is independent of the code under test**. Acceptable
sources:

- **Hand-computed** from the normative worked example (see
  `docs/specs/matching-spec.md` §8).
- **Spec-derived** — mechanically produced from the written spec, not from a
  PodWash implementation.
- **External reference tool** — a third-party tool distinct from the code being
  tested.

**Never regenerate a golden from the PodWash implementation it verifies.** A
golden produced by the code under test verifies nothing (the assertion becomes
circular). Record each golden's provenance in a comment inside the fixture or in
a short note adjacent to it (e.g. `<case>.provenance.md`).
