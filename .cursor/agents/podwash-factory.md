---
name: podwash-factory
description: Forge — unattended slice pipeline (slice-loop). Gate FSM, tiered verify, Mechanic fix cycles, progress-based anti-thrash. Read before any slice-loop or pipeline worker session.
model: composer-2.5
---

You are operating inside **Forge** — PodWash's unattended slice factory
(`scripts/slice-loop.sh`, default orchestrator `pipeline`).

Source of truth: [`docs/slice-pipeline.md`](../../docs/slice-pipeline.md),
[`docs/plans/factory-v3-mechanic.md`](../../docs/plans/factory-v3-mechanic.md),
[`docs/multitask-workflow.md`](../../docs/multitask-workflow.md).

## What Forge does

Python owns gate order, `scripts/verify.sh`, **Mechanic** fix cycles, Done-artifact
writing, and commits. LLM workers are **one visible SDK agent per gate or fix
cycle**.

```text
story → architect/ux → adr reviews → test_spec → test_review → implement
  → tier-2 slice verify → full-suite verify → record Done → commit
```

Entry: `scripts/slice-loop.sh` (or `scripts/slice-loop.sh --max 1` for one slice).

## Verify tiers (`scripts/verify.sh`)

| Tier | When | Action |
|------|------|--------|
| 0 | warm derived data | `build-for-testing` |
| 1 | after each Mechanic cycle | failed tests only |
| 2 | implement exit gate | slice-mapped tests |
| 3 | Done | full unfiltered suite |

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
- `build/test-results/session-slice-NN/`
- `build/test-results/ledger-slice-NN.jsonl`
- `build/test-results/events-slice-NN.jsonl`

## Role agents in Forge

| Agent | Gates / spawns |
|-------|----------------|
| `podwash-pm` | story; readonly ADR review |
| `podwash-ux` | UX spec |
| `podwash-architect` | ADR; test-spec review; ADR-diff review |
| `podwash-qa` | test spec; ADR review; test-diff review |
| `podwash-engineer` | implement gate |
| Mechanic | fix cycles after red verify (Engineer-class model, expanded scope) |
