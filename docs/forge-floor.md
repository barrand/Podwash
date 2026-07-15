# Forge Floor & task factory

Mission control for PodWash Factory v3. **MVP** = `forge-intake` + task board + serial `task-loop` + Forge Floor. Unified `forge.sh` / parallel lanes are sequels.

## Day in the life

1. `scripts/forge-floor.sh` → open [http://127.0.0.1:7420](http://127.0.0.1:7420)
2. **Start factory** for punch-list tasks, or **Start slices** for feature `slice-loop`
3. In Cursor: invoke **forge-intake** for each punch-list item (features still land as slices under `docs/slices/`)
4. Watch **Now** (what's happening) and **Your move** (what you should do). OS notify on Halted, can't-ship, or Pushed
5. Halted → **Your move** → Requeue (amend the ticket in Cursor if the spec was wrong)
6. Can't ship (full suite still red) → **Your move** → Don't push, Retry full suite, or Copy for Cursor
7. When the punch-list is empty, runs full `scripts/verify.sh` **only when needed** (HEAD moved, or meaningful dirt changed vs last green stamp; skips `__pycache__` noise, same-dirt after green, acknowledged Don't push, and open Your-move incidents) — then auto-pushes — or click **Verify & push** to force. Halted tickets park for Requeue first (they block that full suite until Requeue). The loop **stays alive** while waiting (Halted / empty queue) — it should not silently exit and force a manual Restart.
8. **Pause** before hand-editing app code (factory-hot owns the tree). On the slice lane, Pause is a **hard stop** (slice-loop does not soft-park mid-gate).
9. If Floor is killed/relaunched while the factory was running, it **auto-restarts** the worker (boot reconcile + orphan auto-heal). A dead worker is detected by live PID / process scan — not a stale heartbeat timestamp.

## Commands

| Command | Role |
|---------|------|
| `scripts/forge-floor.sh` | Mission control UI (primary) |
| `scripts/task-loop.sh` | Headless serial task runner (Phase 1) — Floor **Start factory** |
| `scripts/slice-loop.sh` | Feature slice pipeline — Floor **Start slices** |
| `scripts/forge.sh` | Alias → task-loop; set `PODWASH_FORGE_UNIFIED=1` for sequel unified loop |
| `scripts/next-task.sh` | Queue brain (`--json` / `--status`) |

Auth: `export CURSOR_API_KEY=cursor_...`

## Ticket board

See [`docs/tasks/README.md`](tasks/README.md). Intake skill: [`.cursor/skills/forge-intake/SKILL.md`](../.cursor/skills/forge-intake/SKILL.md).

**Slices vs tasks on Floor:** Feature slices appear on the same board with a dashed **Slice pipeline** card style. They are **not** drained by **Start factory** (punch-list). Use **Start slices** to run `slice-loop.sh --medic-no-push`. Hot pill shows `factory` vs `slices`. The two runners are mutually exclusive (starting one stops the other).

## Controls

Floor writes `build/factory/controls.json` (pause, ship_now, requeue, cancel, batch_action, `runner_lane`).  
`build/factory/factory-hot` is present while the loop owns the tree — **local-dev defers**. Floor also touches hot when the slice lane is running.

Live status for the Stations panel:

| File | Role |
|------|------|
| `build/factory/station.json` | Current phase (QA / Engineer / tier-2 / FULL-VERIFY) |
| `build/factory/batch-gate.json` | Last green tier-3 SHA stamp |
| `build/factory/heartbeat.json` | Loop liveness (`pid`, `ts`) — Floor derives hot/orphan/starting from this + `runner_pid` |

**Verify & push** (control: `ship_now`) = force a full suite (tier-3) immediately, then `git push` if green. Not App Store submit.

## Verify policy

- Per task: tier-2 surgical tests only (`filtered=1` OK for task Done)
- **Idle drain** (punch-list empty): run tier-3 **only if** HEAD moved, meaningful worktree dirt changed since the last green stamp, or never stamped green; otherwise skip (push-only if ahead of upstream). `__pycache__` / `*.pyc` noise is ignored. After a green idle verify, the same dirt fingerprint does not re-trigger. Halted tickets block this until Requeue. An **open** batch incident at HEAD parks for Your move (does not re-verify); **Don't push** acknowledges and also holds.
- Tier-3 uses xcodebuild `-retry-tests-on-failure` (same as tier-2 unit runs) so flakes are absorbed before Mechanic / Medic / human
- **Verify & push**: always force tier-3, then push
- On persistent red: write `build/factory/batch-failure.json` (open incident), then Mechanic once, then Medic (Floor starts the loop with `--medic-no-push`). If still stuck → Floor **Your move** (Can't push)
- **Don't push** acknowledges the incident (idle drain skips until HEAD moves or Verify & push / Retry)
- **Retry full suite** reopens the incident and sets `ship_now`
- Quarantine / sticky `batch_blocked` are gone — blocked state is derived from the incident file alone

## MVP gate

Use Phase 1+1.5 for real punch lists before enabling:

```bash
PODWASH_FORGE_UNIFIED=1 scripts/forge.sh
# or parallel lanes (after unified feels solid):
# scripts/forge.sh --lanes 2   # via forge_loop
```

See [`docs/forge/mvp-gate.md`](forge/mvp-gate.md).
