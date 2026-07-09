# Slice pipeline — loop-as-orchestrator

> Design reference for `scripts/slice_pipeline.py` and `--orchestrator=pipeline`.
> Plan: [`plans/loop-as-orchestrator-refactor.md`](plans/loop-as-orchestrator-refactor.md).
> Fix confidence: [`plans/factory-fix-confidence.md`](plans/factory-fix-confidence.md).
> Runner mechanics: [`slice-runner.md`](slice-runner.md).

## What moved into Python

| Concern | Owner |
|---------|--------|
| Gate ordering / skip-done | `GateState` + FSM in `slice_pipeline.py` |
| `scripts/verify.sh` | Loop (subprocess) — source of truth |
| Red → FailurePacket + stuck card | `failure_packet.py` (xcresult summary + attachments) |
| Red → diagnose → fix | Free plan-mode diagnose + Engineer\|QA + playbooks |
| Red → fix budget | `--max-fix-attempts` (default 2); flake cold-retry is free |
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

## Fix path (FailurePacket → stuck card → diagnose → playbook)

Applies to **both** coordinator and pipeline modes via shared `run_fix_loop`.

```text
loop-owned verify.sh (red)
  → FailurePacket (summary testFailures + exported attachments)
  → print + persist stuck card (build/test-results/stuck-slice-NN.txt)
  → heuristic class (+ free plan-mode diagnose when unknown / UITest / assertion)
  → playbook lever for attempt N
  → Engineer|QA fix worker (verify banned)
  → loop-owned verify again
```

### FailurePacket

Built by `scripts/failure_packet.py` from:

1. `xcresulttool get test-results summary` — **must** surface real test ids (never leave prompts on only `xcodebuild — TEST FAILED` when summary has names).
2. `xcresulttool export attachments --test-id 'Class/testName()'` — hierarchy + query-chain `.txt` files.
3. Soft undiagnosable: build/lock reds without test ids still route Engineer (`build_error`). Hard-halt only when there is **no** actionable evidence and no bundle.

Signature is stable: sorted `test_ids` + crash fingerprint (not assertion/hierarchy text).

### Stuck card

Human-readable card printed on every red loop-owned verify and thrash halt, also written to `build/test-results/stuck-slice-NN.txt`, and embedded in fix prompts.

### Diagnose (free)

Plan-mode `QA review` worker when class is `unknown`, first UITest attempt, or `assertion`. Does **not** increment `--max-fix-attempts`. Heuristic `failure_class` wins unless heuristic was `unknown`; diagnose may still set hypothesis / `fix_scope` / `suggested_files`.

### Playbooks

`scripts/fix_playbooks.py` — per-class levers. Same packet signature advances lever index. Notable rules:

| Class | Lever 1 | Lever 2 (same signature) |
|-------|---------|---------------------------|
| `ui_race` | Engineer: hold analyzing / defer completion | Engineer: alternate app lever (defer completion / main-actor publish). Halt only after **two** Engineer attempts (or `--max-fix-attempts` exhaustion) unless diagnose `fix_scope=tests` + AC requires transient |
| `flake` | Cold re-verify once (no budget burn) | Then normal levers for reclassified class |
| `unknown` | Diagnose then minimal Engineer | Halt with stuck card |

Slice Role artifacts / Deliverables Swift paths are unioned into `suggested_files`.

### Verify ban (fix workers)

Fix-worker `RunProgress` uses `fix_worker=True` + `forced_role=` so logs show `[Engineer]` / `[QA]`, nested red-verify thrash is disabled (`max_red_verifies=0`), and shell `verify.sh` / `xcodebuild … test` is cancelled. First violation → re-prompt; second → attempt burned.

## Fix router

| Signal | Worker |
|--------|--------|
| Crash / IPS / `ui_race` / `missing_identifier` / `build_error` | Engineer (`PodWash/PodWash/**`) |
| `assertion` with `fix_scope=tests` / fixture-only | QA (tests only) |
| Same signature after first role | Opposite role (or playbook halt for `ui_race`) |
| Ambiguous | Engineer first |

Shared budget: `--max-fix-attempts` (default 2) → exit **5** on exhaustion.
Budget **persists** across bridge retries. Diagnose + flake cold-retry do **not** burn budget.

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
