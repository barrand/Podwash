# Factory handoffs (landed)

Observation-first fix-loop handoffs — shared deterministic lanes, per-worker git
deltas, thin `HANDOFF:` line. See [`docs/slice-pipeline.md`](../slice-pipeline.md)
§ Fix path.

## Landed checklist

- [x] `scripts/fix_lanes.py` — `classify_fix_lane`, git delta helpers, `HANDOFF:` parse
- [x] Tier-2 + full-suite share deterministic lanes (packaging / expectation / artifact / build)
- [x] Referee still owns crash / ui_race / generic assertion / unknown
- [x] Per-worker git baseline → ledger `files_touched` = in-scope delta
- [x] Empty in-scope → force opposite role among Engineer↔QA (Architect only for adr_citation)
- [x] Fingerprint delta counts in-place edits to already-dirty paths
- [x] `HANDOFF:` honored only when in-scope delta empty
- [x] Explicit no-edit×2 → `NO-EDIT THRASH`
- [x] Handoff credit at budget boundary (slice 19: last-attempt flip still spawns)
- [x] Rich `attempt_notes` (summary + files + handoff) in fix prompts
- [x] Narrator ledger-block copy says flip/reroute (not halt)
- [x] Unit tests: `scripts/test_fix_lanes.py` + existing factory suites green

## Deferred

- Authoring-gate completion cards (PM→Architect→QA)
- Playbooks as referee constraints
- Hard-fail / retry on missing `HANDOFF:`
- Skipping referee for crash/ui_race
