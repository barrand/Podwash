# Task NNN — Short title

| Field | Value |
|-------|-------|
| **ID** | NNN |
| **Title** | Short title |
| **Status** | Queued \| In Progress \| Done \| Halted \| Needs-human |
| **Kind** | fix \| tweak \| needs-human |
| **Priority** | P0 \| P1 \| P2 \| P3 |
| **Area** | comma-separated source paths/modules (disjoint scheduling) |
| **Crux** | One falsifiable outcome — the single thing this ticket proves. |

## Outcome

One paragraph: observed vs expected (bugs) or current vs desired (tweaks).

## Acceptance criteria

Automatable only. Every item maps to an assertion. Numeric thresholds where thresholds exist.

- [ ] 1. …
- [ ] 2. …

## Surgical test scope

Concrete `Target/Class/test()` identifiers for `VERIFY_SLICE_TESTS` / `VERIFY_TIER=2`.

| AC# | Test id | New? |
|-----|---------|------|
| 1 | `PodWashTests/FooTests/testBar()` | no / yes |
| 2 | … | |

## Authorized test changes

Tweaks only — named existing assertions the human approved changing at intake. Empty for bugs. Workers must **never** modify a test not listed here.

- (none)

## Depends on

- None (or task NNN)

## Out of scope

- …

## Human checklist

Needs-human tickets only. Factory never auto-Dones these.

- [ ] …

## Verification record

> Loop writes `VERIFY RESULT:` here. For tasks, `tier=2` and `filtered=1` are valid for Done.

```
VERIFY RESULT: (pending)
```
