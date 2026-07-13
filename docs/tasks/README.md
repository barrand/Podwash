# Forge task board

Punch-list work for Factory v3: bugs, tweaks, and Needs-human items. Features land as slices under [`docs/slices/`](../slices/); both appear on **Forge Floor**.

## Files

| Path | Role |
|------|------|
| `task-NNN-<slug>.md` | One ticket (zero-padded id) |
| [`_template.md`](_template.md) | Copy this when filing by hand (prefer `forge-intake`) |
| This README | Contract |

## Status

| Status | Meaning |
|--------|---------|
| Queued | Eligible for the task loop |
| In Progress | A worker lane owns it |
| Done | Green `VERIFY RESULT` recorded (tier-2 filtered OK) |
| Halted | Thrash after one retry — floor soft-control to requeue/cancel |
| Needs-human | Not auto-run; human checklist + floor **Mark done** |

## Kind & priority defaults (intake)

| Kind | Default priority |
|------|------------------|
| fix (bug) | P1 |
| tweak | P2 |
| feature → slice | P3 |
| needs-human | P2 (unless stated) |

Dispatcher order: **In Progress (reclaim)** first, then highest Priority among Queued/Ready, then lowest id. Soft controls can bump. Halted is never auto-started (Requeue on Floor).

## Done signal

Unlike slices, task Done accepts **tier-2 filtered** green:

```
VERIFY RESULT: exit=0 … failed=0 skipped=0 filtered=1 … tier=2 …
```

**Scripts-only tickets** (`scripts.test_…` surgical ids): Done evidence is the same
`VERIFY RESULT` line with `class=unittest` / `bundle=scripts-unittest` from
`python3 -m unittest` (no simulator / xcodebuild). Do not mix PodWashTests and
`scripts.test_*` ids on one ticket — split them.

Full-suite (tier-3) runs at **idle drain** / **Ship now**, not per task. Idle drain only runs when there is no Queued/Ready work **and** no In Progress ticket (In Progress is reclaimed first). Halted tickets park the loop for Requeue — they do not trigger full verify.

## Queue brain

```bash
scripts/next-task.sh
scripts/next-task.sh --json
scripts/next-task.sh --status
```

Override dir for tests: `PODWASH_TASKS_DIR=…`.

## Runner

```bash
scripts/task-loop.sh              # Phase 1 headless
# Prefer after Phase 1.5:
scripts/forge-floor.sh            # open http://127.0.0.1:7420 → Start factory
```

See [`docs/forge-floor.md`](../forge-floor.md).
