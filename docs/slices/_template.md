# Slice NN — Short title

| Field | Value |
|-------|-------|
| **ID** | NN |
| **Title** | Short title |
| **Status** | Draft \| Ready \| In Progress \| Verify \| Done |
| **Crux** | One testable hypothesis — the smallest proof of the key risk for this slice. |

## PRD / spec references

- PRD §X — brief note on what this slice pulls from (link only; do not paste PRD text)
- `docs/specs/matching-spec.md` §X — when the slice ports algorithm behavior
- `docs/adr/000-foundations.md` — when the slice touches playback, transcript schema, or verification mechanics

## Goal

One sentence tied to PRD scope.

## Deliverables

- Concrete file, module, or fixture paths
- …

## Depends on

- Slice X (or none)

**Parallelizable:** Yes / No — brief note if parallel with another slice

## Out-of-scope

- Explicit deferrals (prevents scope creep)
- …

## Acceptance criteria

Automatable only. Coordinator and QA reject criteria that require manual listening, visual review, or "try on device." **Thresholds must be numeric** (e.g. "RMS < 0.01", "±0.25 s"). Golden fixtures must have documented independent provenance (hand-computed or spec-derived — never generated from the code under test). **XCTSkip is not allowed on core ACs** — a mapped test that cannot run must fail.

- [ ] 1. …
- [ ] 2. …
- [ ] 3. …

## Verification mapping

| AC# | Test file | Test method | Notes |
|-----|-----------|-------------|-------|
| 1 | `PodWash/PodWashTests/…` | `test…` | TBD until QA test spec |
| 2 | `PodWash/PodWashTests/…` | `test…` | |
| 3 | `PodWash/PodWashUITests/…` | `test…` | |

## Verification commands

```bash
# Fast inner loop (NOT sufficient for Done):
scripts/verify.sh -only-testing:PodWashTests/…

# Done gate — FULL suite, zero failures, zero skips:
scripts/verify.sh
```

## Verification record (QA fills at Verify)

> Paste the `VERIFY RESULT:` line from the full-suite `scripts/verify.sh` run here.
> A slice without a recorded full-suite green artifact is not Done.

```
VERIFY RESULT: (pending)
```

## Plan review record (coordinator fills before downstream roles)

> Record readonly review outcomes before QA writes tests (ADR review) and before
> Engineer starts (test spec review). No record = next role must not spawn.
> See [`multitask-workflow.md`](../multitask-workflow.md) § Plan review gates.

```
ADR review: (pending)
Test spec review: (pending)
```

## Done gate

- [ ] Every AC mapped to a test; all rows in the mapping table filled
- [ ] **Full suite green:** unfiltered `scripts/verify.sh` exit 0, failed 0, skipped 0
- [ ] Verification record pasted above (exit code + counts + .xcresult path)
- [ ] Auto-commit made on green: `slice-NN: <short description>` (push only when the user asks)

## Tickets (optional)

> **Default: leave empty.** Add sub-tickets only when parallel workers need non-overlapping packages within this slice. If you need many tickets, split into a new slice instead.

| Ticket | Owner role | AC subset | Depends on |
|--------|------------|-----------|------------|
| — | — | — | — |

## Role artifacts

| Role | Gate | Artifact path |
|------|------|---------------|
| Architect | Required / Waived | `docs/adr/…` or — |
| UX | Required / Waived | `docs/slices/slice-NN-ux.md` or — |
