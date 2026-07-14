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

Concrete test identifiers for Done evidence:

- **App / XCTest tasks:** `Target/Class/test()` for `VERIFY_SLICE_TESTS` / `VERIFY_TIER=2`
  (e.g. `PodWashTests/FooTests/testBar()`).
- **Scripts-only tasks** (factory / floor / task-loop): `scripts.test_<module>.Class.method`
  (slash form `Class/method` is accepted and normalized). Done runs
  `python3 -m unittest`, not xcodebuild.

| AC# | Test id | New? |
|-----|---------|------|
| 1 | `PodWashTests/FooTests/testBar()` | no / yes |
| 2 | … | |

## Authorized test changes

Tweaks only — named existing assertions the human approved changing at intake. Empty for bugs. Workers must **never** modify a test not listed here.

- (none)

## Depends on

**Machine-parsed.** Only these bullet shapes are legal:

- `- None` — no dependencies (preferred default)
- `- Task NNN` or `- task-NNN` — hard dependency (NNN must be Done + green verify before this starts)

Do **not** put other task ids in prose here (`orthogonal to task-016`, `see task-012`, etc.) — that used to create fake edges and deadlock the queue. Mention related tickets under **Out of scope** instead.

The queue brain **ignores cyclic deps** (A→B→A) so a mistaken loop cannot freeze In Progress empty forever.

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
