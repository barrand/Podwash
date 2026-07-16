# Forge Floor & task factory

Mission control for PodWash Factory. **One process:** `forge-intake` + unified board (tasks + slices) + serial `forge_loop` + Forge Floor.

## Day in the life

1. `scripts/forge-floor.sh` → open [http://127.0.0.1:7420](http://127.0.0.1:7420)
2. **Start Forge** — one serial runner drains punch-list tasks and feature slices by priority
3. In Cursor: invoke **forge-intake** (bugs/tweaks → `docs/tasks/`; features → `docs/slices/`)
4. Watch **Now**, **Your move**, and the **N items since last green full verify** counter
5. Each item exits at tier-2 green → Status **Implemented** (pushed per item)
6. When you're ready, press **Full verify → Done** in the Ship gate panel (tier-3a then tier-3). On green, all Implemented → **Done**
7. Halted / halt-and-ask → **Your move** (Requeue, answer, Don't push, Retry)
8. **Pause** before hand-editing app code (`factory-hot` owns the tree). Default click pauses now (interrupts in-flight work); menu **After this ticket** finishes the current item first. Soft pause parks the loop — use **Kill Forge** (⋯) only to hard-kill the process.

## Commands

| Command | Role |
|---------|------|
| `scripts/forge-floor.sh` | Mission control UI (primary) |
| `scripts/forge.sh` | Unified serial runner (venv + Medic → `forge_loop`) |
| `scripts/task-loop.sh` | Thin alias → `forge.sh` |
| `scripts/slice-loop.sh` | **Deprecated** thin alias → `forge.sh` |
| `scripts/next-work.sh` | Unified queue brain (`--json`) |
| `scripts/next-task.sh` / `next-slice.sh` | Per-kind queue brains (used by next-work) |

Auth: `export CURSOR_API_KEY=cursor_...`

## Ticket board

See [`docs/tasks/README.md`](tasks/README.md). Intake skill: [`.cursor/skills/forge-intake/SKILL.md`](../.cursor/skills/forge-intake/SKILL.md).

**One board, two kinds:** Bugs/tweaks (tasks) and features (slices) share Queued → In Progress → Done. **Implemented** (tier-2, awaiting ship) and ship-gate **Done** both land in the Done column — the status chip tells them apart. Cards show gate chips (short for tasks, full strip for slices). Both kinds are drained by **Start Forge**.

## Controls

Floor writes `build/factory/controls.json` (pause, pause_after_current, ship_now, requeue, cancel, answer_halt, `runner_lane=forge`).  
`build/factory/factory-hot` is present while the loop owns the tree — **local-dev defers**.

| File | Role |
|------|------|
| `build/factory/station.json` | Current phase (QA / Engineer / SLICE gate / FULL-VERIFY) |
| `build/factory/batch-gate.json` | Last green tier-3 SHA stamp |
| `build/factory/heartbeat.json` | Loop liveness |
| `build/factory/batch-failure.json` | Open ship-gate incident (+ optional bisect) |

### Header toolbar

| Control | Role |
|---------|------|
| **Start Forge** | Spawn the unified runner (morphs to Running / Paused status while live) |
| **Pause** ▾ | Soft pause now (interrupt). Menu: **After this ticket** arms a boundary pause |
| **Cancel pause** | Clears an armed “after this ticket” without parking yet |
| **Resume** | Unpark after a soft pause (only shown while paused) |
| **⋯ → Kill Forge** | Hard-kill the runner process group (not a pause). Surfaced in the header for orphan / starting escape |

### Ship gate panel

**Full verify → Done** (`ship_now`) = force ship gate (3a then 3), promote Implemented→Done, then `git push` if green. Lives next to **CI safety net**, not in the header.

## Verify policy

- Per item (task or slice): tier-2 surgical tests → **Implemented** (`filtered=1` OK)
- Ship gate: tier-3a (units) then tier-3 (full); requires `tier=3 filtered=0` to promote to **Done**
- Tier-3 full suite does **not** retry flakes (avoids doubling wall time); tier-3a / unit-filtered runs still retry once
- On batch red: Mechanic once; if Mechanic **thrashes**, skip a second full tier-3 (bisect only) and **exit the loop** (`EXIT_THRASH`) so the Medic supervisor can run
- Ship thrash/infra **returns to `forge_supervisor`** — do not idle-continue into another overnight Full verify
- Medic heals **factory scripts only** (`scripts/**`); product XCTest failures are `lane=test` → Medic declines → Floor **Your move** (Mechanic/Engineer own app fixes)
- Event feed timestamps display in **Mountain Time** (`MT`); live verify elapsed tracks the current `verify-*.xcresult` bundle
- CI status is surfaced on the Floor as a safety net between manual ship gates (push-per-item)
- **Don't push** acknowledges the incident; **Retry** reopens + `ship_now`

### Verify speed notes

- `verify.sh` records `elapsed_s` plus boot / xcodebuild / parse phases in `build/test-results/verify-timing-latest.json`
- Observed 30–45 min full runs were often **retry doubling** + serial UITests + cold sim; retries are off for tier-3/3b
- Split **3a** (units) then **3b**/full gives an early red signal before the UI-dominant cost
- **Parallel `PodWashTests`:** scheme still `parallelizable=NO`. Offline-render units may be safe (ADR-001 serializes UI/audio). Flip only after **3 consecutive green** `VERIFY_TIER=3a` runs with parallel enabled — do not land without that gate

## MVP gate

Cleared — see [`docs/forge/mvp-gate.md`](forge/mvp-gate.md).
