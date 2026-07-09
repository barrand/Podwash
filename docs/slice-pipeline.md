# Slice pipeline — loop-as-orchestrator

> Design reference for `scripts/slice_pipeline.py` and `--orchestrator=pipeline`.
> Plan: [`plans/loop-as-orchestrator-refactor.md`](plans/loop-as-orchestrator-refactor.md).
> Runner mechanics: [`slice-runner.md`](slice-runner.md).

## What moved into Python

| Concern | Owner |
|---------|--------|
| Gate ordering / skip-done | `GateState` + FSM in `slice_pipeline.py` |
| `scripts/verify.sh` | Loop (subprocess) — source of truth |
| Red → fix | Engineer\|QA router + `--max-fix-attempts` |
| `VERIFY RESULT` + Status Done | Deterministic doc writer |
| Split commits + isolation + push | Loop (pipeline mode) |
| Story / UX / ADR / tests / app / reviews | One visible SDK worker per gate |

## Orchestrator modes

```bash
scripts/slice-loop.sh --orchestrator coordinator   # default — Phase 1
scripts/slice-loop.sh --orchestrator pipeline       # gate FSM — Phase 2+
scripts/slice-loop.sh --orchestrator pipeline --dry-run
```

**Coordinator (default):** one authoring LLM; **must not** run `verify.sh`. After it
returns, the loop runs verify and spawns visible fix workers.

**Pipeline:** Python drives `story → … → implement → verify → record → commit` with
`run_worker()` per gate. Reviewers use SDK `mode=plan`. There is no LLM “QA verify”
gate — the loop owns the suite.

Dual-path is **time-boxed**. After pipeline is trusted, delete the coordinator path.

## Gate graph

```
story ─┬─► architect ─┐
       └─► ux ────────┼─► adr_review_qa ─┐
                       │                  ├─► test_spec → test_review → implement
                       └─► adr_review_pm ─┘         │
                                                    ▼
                                              verify (loop)
                                                    ▼
                                         record (doc writer)
                                                    ▼
                                              commit (+ push)
```

`assess_gate_state()` is the FSM state function (strict artifact contracts).
`assess_slice_gates()` in `slice_loop_progress.py` remains a **progress heuristic**
for heartbeats only — do not treat it as the FSM.

## Fix router

| Signal | Worker |
|--------|--------|
| Crash / IPS / app paths | Engineer (`PodWash/PodWash/**`) |
| Fixture / XCTAssert-only / same signature after Engineer | QA (tests only) |
| Ambiguous | Engineer first |

Shared budget: `--max-fix-attempts` (default 2) → exit **5** on exhaustion.
Budget **persists** across bridge retries.

## Partial-failure policy

- Reuse one `launch_bridge`; dispose each agent after its gate.
- If gate N fails after earlier gates produced artifacts: **leave artifacts on disk**,
  halt with gate id + attempt, **do not** auto-revert.
- Model ids are pinned plain strings (`composer-2.5`, `grok-4.5`) — never scrape
  agent-frontmatter bracket syntax.

## Handoff contract (coordinator mode)

1. Coordinator authors only; ends when implement exists or status is Verify.
2. Loop always owns verify when implement is done **or** status ∈ `{In Progress, Verify}`.
3. Sequential only — never parallel loop verify with a coordinator-owned verify.
