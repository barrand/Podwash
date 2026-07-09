# Test fixtures

Bundled fixtures for `PodWashTests`. Conventions:

- **Layout:** `transcripts/` (TimedWord JSON + expected intervals), `audio/`
  (synthetic clips, < 1 MB each), `feeds/` (RSS XML + expected JSON), `asr/`
  (benchmark artifacts, golden transcripts).
- **Provenance (hard rule):** every golden/expected file must state where its
  values came from — hand-computed from `docs/specs/matching-spec.md`,
  hand-transcribed from a fixture, or produced by an external reference tool.
  **Never generate a golden from the code under test.** Note provenance in a
  sibling `*.provenance.md` file or a comment field in the JSON.
- **Size:** audio fixtures stay under ~1 MB (`.gitignore` un-ignores this
  directory; keep it that way by keeping files small). Larger media is
  documented for local setup instead of committed.
- **ASR models** are never committed — see `scripts/setup-asr-models.sh`
  (created in Slice 05).
