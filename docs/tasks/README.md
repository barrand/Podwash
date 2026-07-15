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
| Queued | Eligible for the unified forge loop |
| In Progress | A worker owns it |
| Implemented | Tier-2 surgical green (work finished; awaiting ship gate) |
| Done | Promoted by **Full verify & ship** (tier-3 `filtered=0`) |
| Halted | Thrash after retry — floor soft-control to requeue/cancel |
| Needs-human | Not auto-run; human checklist + floor **Mark done** |

## Kind & priority defaults (intake)

| Kind | Default priority |
|------|------------------|
| fix (bug) | P1 |
| tweak | P2 |
| feature → slice | P3 |
| needs-human | P2 (unless stated) |

Dispatcher order (via `next-work.sh`): reclaim In Progress, then highest Priority among Queued/Ready tasks, then eligible slices (default P3). Soft controls can bump. Halted is never auto-started (Requeue on Floor).

## Depends on (contract)

Parsed by `scripts/next-task.sh` from the `## Depends on` section only:

| Bullet | Meaning |
|--------|---------|
| `- None` | No deps (parentheticals after None are ignored) |
| `- Task 007 …` / `- task-007` / `- 007` | Depends on that id (must be Implemented or Done + green verify) |

Related-but-not-blocking tickets go in **Out of scope**, never as dep prose. Cycles among open tickets are **ignored** (stderr warning) so the factory cannot deadlock.

## Done signal

Per-item exit is **Implemented** on tier-2 filtered green:

```
VERIFY RESULT: exit=0 … failed=0 skipped=0 filtered=1 … tier=2 …
```

**Scripts-only tickets** (`scripts.test_…` surgical ids): same `VERIFY RESULT` line with `class=unittest` / `bundle=scripts-unittest`.

Ship-gate **Done** requires tier-3 `filtered=0` from Floor **Full verify & ship** (promotes all Implemented items). CI is the safety net between manual ship gates.

## Queue brain

```bash
scripts/next-task.sh
scripts/next-task.sh --json
scripts/next-task.sh --status
```

Override dir for tests: `PODWASH_TASKS_DIR=…`.

## Runner

```bash
scripts/forge.sh                 # unified serial runner (preferred)
scripts/task-loop.sh             # thin alias → forge.sh
scripts/forge-floor.sh           # open http://127.0.0.1:7420 → Start Forge
```

See [`docs/forge-floor.md`](../forge-floor.md).
