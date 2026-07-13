---
name: forge-intake
description: >-
  Grill the user into a falsifiable Forge ticket (bug, tweak, or feature) and
  file it on the task/slice board. Use when queuing a fix, tweak, punch-list
  item, bug report, feature ask, or when the user invokes forge-intake / intake.
---

# forge-intake

Single front door onto the Forge. **Refuse to write the ticket until success is falsifiable.** Never edit app or test code — intake only.

Pairs with `forge-fix` (post-mortem). Writes `docs/tasks/task-NNN-*.md` or a slice under `docs/slices/`.

## Flow (propose-then-correct)

1. **Triage** — bug / tweak / feature / needs-human.
   - Feature tripwires: new screen or module, ADR-level decision, >~2 modules, or surgical tests cannot be named → **slice**, not task.
   - Device-only / subjective / CarPlay with no proxy assert → **Needs-human** task (human checklist; factory never auto-Dones).
2. **Read first** — grep relevant views/models and existing tests; cite real symbols in questions.
3. **Draft** best-guess ticket (ACs, surgical tests, Area tags, Priority).
4. **Ask only uninferrable fields** (max two rounds). Punch-list sessions carry device/build/area across tickets.
5. **Duplicate nudge** — if a Queued/Halted ticket looks similar (title/area), warn and ask continue vs open existing; do not block filing.
6. **Write** the file; Status = Queued (or Needs-human).

## Priority defaults (throughput-biased)

| Kind | Default |
|------|---------|
| Bug / fix | **P1** |
| Tweak | **P2** |
| Feature / slice | **P3** |
| Needs-human | **P2** |

Show the assumed priority in the draft. Explicit “urgent / blocker / P0” overrides.

## Question tracks

### Bug

Repro, device/frequency, observed vs expected with numbers. Killer question: **which existing test should have caught this?** That answer becomes surgical test scope (new or extended).

### Tweak

Current designed behavior vs desired delta. Killer question: **which existing tests assert the old behavior?** List them under **Authorized test changes** — the only legitimate bend-the-test path. Flag PRD/slice lines to amend.

### Feature

Grill for story/AC enough to start the slice pipeline. Create/update `docs/slices/slice-NN-*.md` from the slice template (Status Ready or Queued-equivalent per slices README). MVP: execution may still use `slice-loop`; still file it so Forge Floor shows it.

### Needs-human

Clear human checklist (device steps). No fake `VERIFY_SLICE_TESTS`. Kind = needs-human.

## Exit criteria (before write)

- One crux per ticket (two cruxes → two tickets)
- Every AC maps to an assertion (or Needs-human checklist item)
- Surgical test scope as concrete ids (automatable tasks):
  - App: `Target/Class/test()` (e.g. `PodWashTests/FooTests/testBar()`)
  - Scripts-only: `scripts.test_<module>.Class.method` (factory/floor punch lists)
- **Area** tags: source paths/modules the change will touch
- Framing: “what test, if it existed and passed, would let you never manually check this again?”

## File layout

- Tasks: copy structure from [`docs/tasks/_template.md`](../../../docs/tasks/_template.md); next id = max existing `task-NNN-*` + 1 (zero-pad to 3).
- Slices: [`docs/slices/_template.md`](../../../docs/slices/_template.md).

## Hard bans

- Do not edit `PodWash/PodWash/**` or test targets
- Do not invent weak tests for Needs-human work
- Do not skip the grill to “just file it”
