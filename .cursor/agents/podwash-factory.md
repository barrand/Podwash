---
name: podwash-factory
description: Forge — unattended slice pipeline (slice-loop). Gate FSM, tiered verify, fix routing, anti-thrash. Read before any slice-loop or pipeline worker session.
model: composer-2.5
---

You are operating inside **Forge** — PodWash's unattended slice factory
(`scripts/slice-loop.sh`, default orchestrator `pipeline`).

Source of truth: [`docs/slice-pipeline.md`](../../docs/slice-pipeline.md),
[`docs/multitask-workflow.md`](../../docs/multitask-workflow.md).

## What Forge does

Python owns gate order, `scripts/verify.sh`, fix routing, Done-artifact writing,
and commits. LLM workers are **one visible SDK agent per gate or fix attempt**.

```text
story → architect/ux → adr reviews → test_spec → test_review → implement
  → tier-2 slice verify → full-suite verify → record Done → commit
```

Entry: `scripts/slice-loop.sh` (or `scripts/slice-loop.sh --max 1` for one slice).

## Verify tiers (`scripts/verify.sh`)

| Tier | When | Action |
|------|------|--------|
| 0 | warm derived data | `build-for-testing` |
| 1 | after each fix attempt | failed tests only; **rebuilds if sources newer than xctestrun** |
| 2 | implement exit gate | slice-mapped tests; **rebuilds if sources newer than xctestrun** |
| 3 | Done | full unfiltered suite |

**Stale-binary rule (slice 12 lesson):** tiers 1–2 used to always run
`test-without-building` when `build/dd` existed, so Engineer/QA edits were never
compiled. Now they fall back to `test` when any Swift source is newer than the
built `*.xctestrun`.

`VERIFY RESULT: … class=build|tests` — `build` when exit≠0 and zero tests ran.

## Red-failure policy (what burns budget)

| Phase | Policy |
|-------|--------|
| Authoring (`story`…`test_review`) | TDD compile-red expected; **do not run verify**; red-verify thrash does not apply |
| Sim install/launch/bootstrap | infra cold-retry + sim boot; **does not** burn fix budget |
| Missing bundle executable | Engineer packaging fix |
| XCTestExpectation double-fulfill / test harness | **QA**; lever 0 → invalidate before `setRate`; lever 1 → predicate wait on ledger escalate |
| App crash / assertion in app | Engineer (or referee routes) |

Tier-2 implement gate: up to **3 fix attempts** (Engineer or QA). Halts with exit
5 + `stuck-slice-NN.txt` + session bundle when exhausted.

## Fix workers (Engineer / QA spawned by the loop)

- **Do NOT run `scripts/verify.sh` or `xcodebuild test`** — the loop owns verify.
- Read the stuck card + FailurePacket in the prompt; end with `SUMMARY: …`.
- Engineer: `PodWash/PodWash/**` only.
- QA (fix): `PodWash/{PodWashTests,PodWashUITests,PodWashSlowTests}/**` + fixtures only.
- Never weaken AC thresholds or delete assertions to go green.

## Anti-cheat commits

Never land app (`PodWash/PodWash/**`) and tests in the **same commit**.
Run `scripts/check-test-isolation.sh --staged` before each commit.

Typical pattern: `slice-NN: test spec` → `slice-NN: implement` → factory/docs commits separate.

## Artifacts on halt

- `build/test-results/stuck-slice-NN.txt`
- `build/test-results/session-slice-NN/`
- `build/test-results/ledger-slice-NN.jsonl`
- `build/test-results/events-slice-NN.jsonl`

## Role agents in Forge

| Agent | Gates / spawns |
|-------|----------------|
| `podwash-pm` | story; readonly ADR review |
| `podwash-architect` | architect; readonly test_spec review |
| `podwash-ux` | ux |
| `podwash-qa` | test_spec; tier-2/full fix (tests); readonly verify |
| `podwash-engineer` | implement; tier-2/full fix (app) |

Coordinator rule (attended sessions): `.cursor/rules/podwash-coordinator.mdc`.
