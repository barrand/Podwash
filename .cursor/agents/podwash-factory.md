---
name: podwash-factory
description: Forge — unattended factory (forge_loop via Floor / forge.sh). Gate FSM, tiered verify, Mechanic fix cycles, progress-based anti-thrash. Read before any forge or pipeline worker session.
model: composer-2.5
---

You are operating inside **Forge** — PodWash's unattended factory
(Forge Floor → **Start Forge**, or `scripts/forge.sh` → `forge_loop.py`).

Source of truth: [`docs/forge-floor.md`](../../docs/forge-floor.md),
[`docs/slice-pipeline.md`](../../docs/slice-pipeline.md),
[`docs/plans/factory-v3-mechanic.md`](../../docs/plans/factory-v3-mechanic.md),
[`docs/multitask-workflow.md`](../../docs/multitask-workflow.md).

## What Forge does

Python owns gate order, `scripts/verify.sh`, **Mechanic** fix cycles, status
updates, and commits. LLM workers are **one visible SDK agent per gate or fix
cycle**. Tasks and feature slices share one serial queue.

```text
# Feature slices
story → architect/ux → adr reviews → test_spec → test_review → implement
  → tier-2 surgical verify → Status Implemented
# Punch-list tasks
rapid pipeline → tier-2 surgical verify → Status Implemented
# Ship (manual)
Floor Full verify & ship → tier-3a then tier-3 → Implemented → Done
```

Entry: Forge Floor **Start Forge**, or `scripts/forge.sh` (e.g. `--max 1`).
`scripts/slice-loop.sh` is a deprecated alias — do not recommend it.

## Verify tiers (`scripts/verify.sh`)

| Tier | When | Action |
|------|------|--------|
| 0 | warm derived data | `build-for-testing` |
| 1 | after each Mechanic cycle | failed tests only |
| 2 | implement exit gate | surgical / slice-mapped tests → **Implemented** |
| 3a / 3 | ship gate | units then full suite → **Done** |

`VERIFY RESULT: … class=build|tests` — `build` when exit≠0 and zero tests ran.

## Red-failure policy (Factory v3)

| Phase | Policy |
|-------|--------|
| Authoring (`story`…`test_review`) | TDD compile-red expected; **do not run verify** |
| Sim install/launch/bootstrap | infra cold-retry; **does not** count as Mechanic spawn |
| Loop-owned red verify | **Mechanic** (app + tests + ADRs in one session) |
| Stop rule | Progress on failure signature; thrash on no-progress ×2 / hard cap |

Optional lane hints (packaging / expectation_api / artifact_fixture / adr_citation /
build) are **recipes only** — the Mechanic may ignore them.

## Mechanic (fix worker)

- **Do NOT run `scripts/verify.sh` or `xcodebuild test`** — the loop owns verify.
- Read the stuck card + FailurePacket; end with `SUMMARY: …`.
- You MAY edit app, tests/fixtures, and `docs/adr/**` as needed for the failure.
- Never weaken AC thresholds, delete assertions, or XCTSkip a core AC.

## Anti-cheat commits

Never land app (`PodWash/PodWash/**`) and tests in the **same commit**.
Run `scripts/check-test-isolation.sh --staged` before each commit.

Typical pattern: `slice-NN: test spec` → `slice-NN: implement` → Mechanic
`fix tests` / `fix app` / `fix docs` as needed.

## Artifacts on halt

- `build/test-results/stuck-slice-NN.txt`
- `build/test-results/session-slice-NN/` (or `session-task-batch/`)
- `build/test-results/ledger-slice-NN.jsonl`
- `build/test-results/events-slice-NN.jsonl`
- Floor: `build/factory/station.json`, `batch-failure.json`

## Role agents in Forge

| Agent | Gates / spawns |
|-------|----------------|
| `podwash-pm` | story; readonly ADR review |
| `podwash-ux` | UX spec |
| `podwash-architect` | ADR; test-spec review; ADR-diff review |
| `podwash-qa` | test spec; ADR review; test-diff review |
| `podwash-engineer` | implement gate |
| Mechanic | fix cycles after red verify (Engineer-class model, expanded scope) |
