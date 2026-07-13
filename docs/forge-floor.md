# Forge Floor & task factory

Mission control for PodWash Factory v3. **MVP** = `forge-intake` + task board + serial `task-loop` + Forge Floor. Unified `forge.sh` / parallel lanes are sequels.

## Day in the life

1. `scripts/forge-floor.sh` → open [http://127.0.0.1:7420](http://127.0.0.1:7420)
2. **Start factory**
3. In Cursor: invoke **forge-intake** for each punch-list item
4. Watch stations / OS notify on Halted, Batch blocked, or Pushed
5. Halted → decide on the Floor (Requeue / Cancel); amend ticket in Cursor if the spec was wrong
6. Idle drain runs full `scripts/verify.sh` **only when needed** (HEAD/dirty vs last green stamp), then auto-pushes — or click **Ship now** to force
7. **Pause** before hand-editing app code (factory-hot owns the tree)

## Commands

| Command | Role |
|---------|------|
| `scripts/forge-floor.sh` | Mission control UI (primary) |
| `scripts/task-loop.sh` | Headless serial task runner (Phase 1) |
| `scripts/forge.sh` | Alias → task-loop; set `PODWASH_FORGE_UNIFIED=1` for sequel unified loop |
| `scripts/next-task.sh` | Queue brain (`--json` / `--status`) |
| `scripts/slice-loop.sh` | Legacy / slice pipeline (features until unified) |

Auth: `export CURSOR_API_KEY=cursor_...`

## Ticket board

See [`docs/tasks/README.md`](tasks/README.md). Intake skill: [`.cursor/skills/forge-intake/SKILL.md`](../.cursor/skills/forge-intake/SKILL.md).

## Controls

Floor writes `build/factory/controls.json` (pause, ship_now, requeue, cancel, batch_action).  
`build/factory/factory-hot` is present while the loop owns the tree — **local-dev defers**.

Live status for the Stations panel:

| File | Role |
|------|------|
| `build/factory/station.json` | Current phase (QA / Engineer / tier-2 / FULL-VERIFY) |
| `build/factory/batch-gate.json` | Last green tier-3 SHA stamp |

**Ship now** = force a full suite (tier-3) immediately, then `git push` if green. Not App Store submit.

## Verify policy

- Per task: tier-2 surgical tests only (`filtered=1` OK for task Done)
- **Idle drain** (queue empty): run tier-3 **only if** HEAD moved, worktree dirty, or never stamped green; otherwise skip (push-only if ahead of upstream)
- **Ship now**: always force tier-3, then push
- Batch still red after one Mechanic retry → Floor Batch blocked (quarantine vs hold-all)

## MVP gate

Use Phase 1+1.5 for real punch lists before enabling:

```bash
PODWASH_FORGE_UNIFIED=1 scripts/forge.sh
# or parallel lanes (after unified feels solid):
# scripts/forge.sh --lanes 2   # via forge_loop
```

See [`docs/forge/mvp-gate.md`](forge/mvp-gate.md).
