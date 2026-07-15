# Forge Floor & task factory

Mission control for PodWash Factory. **One process:** `forge-intake` + unified board (tasks + slices) + serial `forge_loop` + Forge Floor.

## Day in the life

1. `scripts/forge-floor.sh` → open [http://127.0.0.1:7420](http://127.0.0.1:7420)
2. **Start Forge** — one serial runner drains punch-list tasks and feature slices by priority
3. In Cursor: invoke **forge-intake** (bugs/tweaks → `docs/tasks/`; features → `docs/slices/`)
4. Watch **Now**, **Your move**, and the **N items since last green full verify** counter
5. Each item exits at tier-2 green → Status **Implemented** (pushed per item)
6. When you're ready, press **Full verify & ship** (tier-3a then tier-3). On green, all Implemented → **Done**
7. Halted / halt-and-ask → **Your move** (Requeue, answer, Don't push, Retry)
8. **Pause** before hand-editing app code (`factory-hot` owns the tree). Soft pause parks at gate boundaries.

## Commands

| Command | Role |
|---------|------|
| `scripts/forge-floor.sh` | Mission control UI (primary) |
| `scripts/forge.sh` | Unified serial runner (default) |
| `scripts/task-loop.sh` | Thin alias → `forge.sh` |
| `scripts/slice-loop.sh` | Medic wrapper; set `PODWASH_FORGE_LOOP` for the loop module |
| `scripts/next-work.sh` | Unified queue brain (`--json`) |
| `scripts/next-task.sh` / `next-slice.sh` | Per-kind queue brains (used by next-work) |

Auth: `export CURSOR_API_KEY=cursor_...`

## Ticket board

See [`docs/tasks/README.md`](tasks/README.md). Intake skill: [`.cursor/skills/forge-intake/SKILL.md`](../.cursor/skills/forge-intake/SKILL.md).

**One board, two kinds:** Bugs/tweaks (tasks) and features (slices) share Queued → In Progress → **Implemented** → Done. Cards show gate chips (short for tasks, full strip for slices). Both are drained by **Start Forge**.

## Controls

Floor writes `build/factory/controls.json` (pause, ship_now, requeue, cancel, answer_halt, `runner_lane=forge`).  
`build/factory/factory-hot` is present while the loop owns the tree — **local-dev defers**.

| File | Role |
|------|------|
| `build/factory/station.json` | Current phase (QA / Engineer / SLICE gate / FULL-VERIFY) |
| `build/factory/batch-gate.json` | Last green tier-3 SHA stamp |
| `build/factory/heartbeat.json` | Loop liveness |
| `build/factory/batch-failure.json` | Open ship-gate incident (+ optional bisect) |

**Full verify & ship** (`ship_now`) = force ship gate (3a then 3), promote Implemented→Done, then `git push` if green.

## Verify policy

- Per item (task or slice): tier-2 surgical tests → **Implemented** (`filtered=1` OK)
- Ship gate: tier-3a (units) then tier-3 (full); requires `tier=3 filtered=0` to promote to **Done**
- Tier-3 full suite does **not** retry flakes (avoids doubling wall time); tier-3a / unit-filtered runs still retry once
- On batch red: Mechanic once, then lightweight commit-range bisect (tier-3a), then **Your move**
- CI status is surfaced on the Floor as a safety net between manual ship gates (push-per-item)
- **Don't push** acknowledges the incident; **Retry** reopens + `ship_now`

### Verify speed notes

- `verify.sh` records `elapsed_s` plus boot / xcodebuild / parse phases in `build/test-results/verify-timing-latest.json`
- Observed 30–45 min full runs were often **retry doubling** + serial UITests + cold sim; retries are off for tier-3/3b
- Split **3a** (units) then **3b**/full gives an early red signal before the UI-dominant cost
- **Parallel `PodWashTests`:** scheme still `parallelizable=NO`. Offline-render units may be safe (ADR-001 serializes UI/audio). Flip only after **3 consecutive green** `VERIFY_TIER=3a` runs with parallel enabled — do not land without that gate

## MVP gate

Cleared — see [`docs/forge/mvp-gate.md`](forge/mvp-gate.md).
