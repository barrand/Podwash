# Slice 02 — Matching engine

| Field | Value |
|-------|-------|
| **ID** | 02 |
| **Title** | Matching engine |
| **Status** | Draft |
| **Crux** | The Swift port of `docs/specs/matching-spec.md` reproduces the spec's hand-computed golden intervals exactly (±0.0005 s) from fixture transcripts, via unit tests alone. |

## PRD / spec references

- **`docs/specs/matching-spec.md`** — the normative algorithm spec (constants, `normalize_word`, midpoint expansion, sort-and-merge, seeded word lists). **Port from this document**, not from memory or deleted prototype code.
- PRD §3 — Profanity handling (interval list from word matches)
- PRD §5 — Word and category selection
- `docs/adr/000-foundations.md` §4 — shared `TimedWord` transcript schema

## Goal

Port the matching and interval padding/merge algorithm from the spec into tested Swift units with spec-derived golden outputs.

## Deliverables

- `TimedWord` Codable model per ADR-000 (`{word: String, start: Double, end: Double}`) — this pinned schema is shared with the ASR slice
- `WordMatcher`: `normalize(_:)` exactly per spec §3; exact set-membership matching per spec §4
- `IntervalBuilder`: padding + midpoint expansion per spec §5 (including the t=0 clamp quirk); sort-and-merge per spec §6; attach action (mute/skip)
- Seeded category word lists per spec §7
- Fixtures in `PodWash/PodWashTests/Fixtures/transcripts/`: the spec §8 example transcript + expected intervals JSON, plus the clamp/expansion supplementary case — **goldens transcribed from the spec's hand computation** (provenance noted in fixture README)
- `WordMatcherTests`, `IntervalBuilderTests`

## Depends on

- Slice 01

**Parallelizable:** Yes — parallel with Slices 03, 05, 06 after Slice 01.

## Out-of-scope

- ASR / transcription (Slice 05)
- Playback integration (Slices 03–04)
- UI screens; word-list management UI (Slice 13)
- Unrelated-content segmentation (Slices 18–19)

## Acceptance criteria

- [ ] 1. `normalize(_:)` matches spec §3 for the spec's example table (`"Shit!"` → `"shit"`, `"'ship'"` → `"ship"`, `"$#!%"` → `""`, interior chars kept).
- [ ] 2. Exact set-membership matching only: `"shipment"` does NOT match a list containing `"ship"` (spec §4).
- [ ] 3. Padding constants are exactly `START_PADDING_SECONDS = 0.080`, `END_PADDING_SECONDS = 0.120`, `MIN_CENSOR_SECONDS = 0.180`; midpoint expansion implements spec §5 including the t=0 clamp quirk (word `[0.00, 0.05]` → interval `[0.000, 0.175]`).
- [ ] 4. Sort-and-merge implements spec §6: touching intervals (`start == previous.end`) merge; contained intervals don't shorten containers.
- [ ] 5. Spec §8 golden: the 5-word example transcript produces exactly `[{0.92, 1.87}, {2.92, 3.32}]` within ±0.0005 s, loaded from fixture JSON.
- [ ] 6. Full suite green via `scripts/verify.sh`.

## Verification mapping

| AC# | Test file | Test method | Notes |
|-----|-----------|-------------|-------|
| 1 | `PodWash/PodWashTests/WordMatcherTests.swift` | `testNormalizeMatchesSpecTable` | TBD |
| 2 | `PodWash/PodWashTests/WordMatcherTests.swift` | `testNoSubstringFalsePositive` | TBD |
| 3 | `PodWash/PodWashTests/IntervalBuilderTests.swift` | `testPaddingConstantsAndMidpointExpansion` | TBD |
| 4 | `PodWash/PodWashTests/IntervalBuilderTests.swift` | `testSortAndMergeSemantics` | TBD |
| 5 | `PodWash/PodWashTests/IntervalBuilderTests.swift` | `testSpecGoldenExample` | Golden from spec §8 (hand-computed provenance) |
| 6 | — | — | Command-level |

## Verification commands

```bash
# Fast inner loop:
scripts/verify.sh -only-testing:PodWashTests/WordMatcherTests -only-testing:PodWashTests/IntervalBuilderTests

# Done gate — FULL suite:
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
- [ ] Auto-commit on green: `slice-02: <short description>`

## Role artifacts

| Role | Gate | Artifact path |
|------|------|---------------|
| Architect | Light — module boundaries inline; ADR-000 pins schema | `docs/adr/000-foundations.md` §4 |
| UX | Waived | — |
