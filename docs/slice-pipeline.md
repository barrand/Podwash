# Slice pipeline — loop-as-orchestrator

> Design reference for `scripts/slice_pipeline.py` and `--orchestrator=pipeline`.
> Plan: [`plans/loop-as-orchestrator-refactor.md`](plans/loop-as-orchestrator-refactor.md).
> Factory v2: [`plans/factory-v2.md`](plans/factory-v2.md) (**P0 + P1 landed**; P2 cancelled).
> Fix confidence: [`plans/factory-fix-confidence.md`](plans/factory-fix-confidence.md).
> Runner mechanics: [`slice-runner.md`](slice-runner.md).

## What moved into Python

| Concern | Owner |
|---------|--------|
| Gate ordering / skip-done | `GateState` + FSM in `slice_pipeline.py` |
| `scripts/verify.sh` (tiers 0–3) | Loop (subprocess) — source of truth |
| Red → FailurePacket + stuck card | `failure_packet.py` (evidence formats) |
| Red → **LLM referee** → fix | `referee.py` (strict JSON) + Engineer\|QA |
| Hypothesis ledger (anti-thrash) | `hypothesis_ledger.py` — reject repeat hyp+signature |
| Event log + timeline + SUMMARY | `factory_events.py` |
| Shift-floor narrator + Murphy | `factory_narrator.py` (rendering only) |
| Sim pre-boot / crash watch / stress | `sim_hygiene.py` |
| Red → fix budget | `--max-fix-attempts` (default 2); flake cold-retry is free; exit 5 thrash / 6 infra |
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

## Verify tiers (P0)

`scripts/verify.sh` accepts `VERIFY_TIER` (default **3**) and shares `-derivedDataPath build/dd`:

| Tier | Action | Filters | When |
|------|--------|---------|------|
| 0 | `build-for-testing` | none | warm derived data after edits |
| 1 | `test-without-building` | `VERIFY_FAILED_TESTS` → `-only-testing:` | **after every fix attempt** |
| 2 | `test` / `test-without-building` | slice-mapped + smoke (`VERIFY_SLICE_TESTS` / CLI) | implement exit gate (P1) |
| 3 | `test` (unfiltered) | none | **Done gate** — `VERIFY RESULT:` contract unchanged (+ optional `tier=3`) |

`VERIFY_DRY_RUN=1` prints the resolved argv and exits 0 (unit tests: `scripts/test-verify-tiers.sh`).

## Fix path (FailurePacket → stuck card → referee → ledger → fix)

Applies to **both** coordinator and pipeline modes via shared `run_fix_loop`.

```text
loop-owned verify.sh tier 3 (red)
  → FailurePacket (summary testFailures + exported attachments)
  → print + persist stuck card (build/test-results/stuck-slice-NN.txt)
  → LLM referee (plan mode, cheap model, strict JSON verdict)
  → ledger gate: reject repeat hypothesis on same signature → halt exit 5
  → Engineer|QA fix worker (fresh context, verify banned, ledger in prompt)
  → tier 1 re-verify (failed tests only)
  → if green → tier 3 full suite
  → append ledger entry
```

### FailurePacket

Built by `scripts/failure_packet.py` from:

1. `xcresulttool get test-results summary` — **must** surface real test ids (never leave prompts on only `xcodebuild — TEST FAILED` when summary has names).
2. `xcresulttool export attachments --test-id 'Class/testName()'` — hierarchy + query-chain `.txt` files.
3. Soft undiagnosable: build/lock reds without test ids still produce an actionable packet. Hard-halt only when there is **no** actionable evidence and no bundle.

Signature is stable: sorted `test_ids` + crash fingerprint (not assertion/hierarchy text). Heuristic `classify_failure` remains as a **hint** inside the packet; it no longer routes fixes.

### Stuck card

Human-readable card printed on every red loop-owned verify and thrash halt, also written to `build/test-results/stuck-slice-NN.txt`, and embedded in referee + fix prompts.

### LLM referee (replaces diagnose + playbooks as router)

`scripts/referee.py` — plan-mode worker (`composer-2.5`) returns **only** JSON:

```json
{
  "primary_failure": "…",
  "failure_groups": [["unit …"], ["UI …"]],
  "role": "Engineer",
  "fix_scope": "app",
  "files": ["PodWash/PodWash/…"],
  "instruction": "≤2 sentences",
  "hypothesis": "…",
  "confidence": "high|med|low",
  "narration": "≤25 words"
}
```

Python enforces: parse failure or `confidence=low` → **halt** (never guess). `fix_scope=app` → Engineer; `tests` → QA. Prefer unit assertion/crash over UITest waits as primary (prompt rule).

Legacy `fix_playbooks.py` / diagnose helpers remain in-tree for tests but are **not** consulted by `run_fix_loop`.

### Hypothesis ledger

`build/test-results/ledger-slice-NN.jsonl` — durable across bridge death. Each attempt appends `{ts, attempt, role, hypothesis, files_touched, result_signature, verify_tier, outcome}`. Before spawning a fix worker, Python rejects any referee verdict whose **hypothesis + signature** matches a prior entry → stuck card + exit 5 (“no new hypothesis”). Repeat signatures always get a **fresh** fix worker (new agent context) with the ledger attached.

### Verify ban (fix workers)

Fix-worker `RunProgress` uses `fix_worker=True` + `forced_role=` so logs show `[Engineer]` / `[QA]`, nested red-verify thrash is disabled (`max_red_verifies=0`), and shell `verify.sh` / `xcodebuild … test` is cancelled. First violation → re-prompt; second → attempt burned.

## Fix routing (P0)

| Signal | Worker |
|--------|--------|
| Referee `fix_scope=app` / `role=Engineer` | Engineer (`PodWash/PodWash/**`) |
| Referee `fix_scope=tests` / `role=QA` | QA (tests only) |
| Referee `confidence=low` or unparseable JSON | Halt (stuck card) |
| Ledger hit (same hyp + signature) | Halt (no new hypothesis) |

Shared budget: `--max-fix-attempts` (default 2) → exit **5** on exhaustion.
Budget **persists** across bridge retries. Flake cold-retry does **not** burn budget.
Referee calls do **not** burn budget (routing only).

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

## Unit tests (P0 + P1)

```bash
python3 -m unittest scripts.test_factory_p1 scripts.test_referee \
  scripts.test_hypothesis_ledger scripts.test_slice_pipeline \
  scripts.test_failure_packet -q
./scripts/test-verify-tiers.sh
scripts/slice-loop.sh --orchestrator pipeline --max 1   # unattended default
```

**P1 landed:** JSONL event log (`events-slice-NN.jsonl`), phase timeline, `SUMMARY:`
contract, shift-floor narrator (names + Murphy), pipeline default, implement exit =
tier-2 green (`tier2-slice-NN.ok`, `max_implement_verify_runs=3`), exit **6** infra vs
**5** thrash, sim pre-boot (`PODWASH_SIM_UDID`), crash watchdog, UITest stress-run (5×).

**P2 cancelled** — no Slice-10 replay; try the factory on slice 11+.
