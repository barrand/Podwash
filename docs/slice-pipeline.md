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
| Status Ready after story content | Deterministic doc writer (`set_slice_status`) |
| Split commits + isolation + push | Loop (pipeline mode) |
| Story / UX / ADR / tests / app / reviews | One visible SDK worker per gate |

## Orchestrator modes

```bash
scripts/slice-loop.sh                              # default — pipeline (unattended)
scripts/slice-loop.sh --orchestrator pipeline       # explicit gate FSM
scripts/slice-loop.sh --orchestrator coordinator   # legacy attended authoring LLM
scripts/slice-loop.sh --orchestrator pipeline --dry-run
```

**Pipeline (default):** Python drives `story → … → implement → verify → record → commit`
with `run_worker()` per gate. Reviewers use SDK `mode=plan`. There is no LLM
“QA verify” gate — the loop owns the suite. Authoring gates must **not** run
`verify.sh` (TDD compile-red is expected until Engineer implements).

**Coordinator (legacy):** one authoring LLM; **must not** run `verify.sh`. After it
returns, the loop runs verify and spawns visible fix workers.

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
for heartbeats only — do not treat it as the FSM. **Story uses the same
predicate in both** (`_story_done`: Crux + AC checkboxes **and** Status Ready+).
A filled Crux while Status is still `Draft` is **not** story-done (Slice 12
failure mode: progress showed `next: ux` while the FSM halted on story).

### Forge (factory brand)

The unattended loop is branded **Forge** (`FACTORY_NAME` in `factory_narrator.py`).
Session start prints a compact ASCII title once; green Done banners say
“Forge gate cleared.” Worker progress lines show **Role Name** (e.g.
`[slice 12][QA Quincy]`) so it is obvious who is speaking. Harness lines keep
the `[slice-loop]` prefix. Murphy remains the failure mascot in narrated red
lines only — not in the brand.

### Story log

Authoring and fix loops emit **chapter beats** instead of stacking mechanical
noise:

- Chapter open: `── Slice 12 · 4/9 test spec · QA Quincy ──`
- Shift open: `════ SLICE 13 ════` banner, then LLM coordinator check-in (or template fallback). `FORGE_LLM_NARRATION=0` disables all floor LLM beats.
- Verify green: one creative LLM sentence from the agent who ran verify (e.g. Edison on 6/6) — no template pool; minimal `✓ … all green (6/6)` fallback if LLM is off.
- Verify red / failure detail / thrash halt: Murphy + 🐒 only when tests we expected green go red.
- Clear: `✓ Quincy cleared test spec (2m) — next: …`
- Stuck: `✗ story stuck — … Unblock: …`
- Failure detail: `from Edison: Murphy got into the wrench drawer. I was on FooTests/testBar() — tried … Got … instead.`
- Role report: `from Ada: Status=Ready; missing artifacts …`
- Recap: `Forge recap · slice 12 · 18m · Priya, Quincy · Murphy ×1 · green`

`worker start` / `worker finished` / duplicate `SUMMARY:` lines are verbose-only.
Heartbeats say `Forge · slice 12 · QA Quincy · 4m` when a named agent is on stage.

### Story → Ready handoff

PM writes Crux / ACs; the harness owns Status. After a successful story-gate
worker, if `_story_content_ok` and Status is still Draft/empty, the pipeline
calls `set_slice_status(..., "Ready")` (same deterministic-writer pattern as
Status Done after green verify). Halt lines from `explain_gate_pending` print
failed predicates + an unblock hint when a gate stays pending after its worker.

## Verify tiers (P0)

`scripts/verify.sh` accepts `VERIFY_TIER` (default **3**) and shares `-derivedDataPath build/dd`:

| Tier | Action | Filters | When |
|------|--------|---------|------|
| 0 | `build-for-testing` | none | warm derived data after edits |
| 1 | `test` or `test-without-building` | `VERIFY_FAILED_TESTS` → `-only-testing:` | **after every fix attempt** |
| 2 | `test` or `test-without-building` | slice-mapped + smoke (`VERIFY_SLICE_TESTS` / CLI) | implement exit gate (P1) |
| 3 | `test` (unfiltered) | none | **Done gate** — `VERIFY RESULT:` contract unchanged (+ optional `tier=3`) |

Tiers 1–2 use `test-without-building` **only when** the built `*.xctestrun` is
newer than every Swift source under `PodWash/{PodWash,PodWashTests,PodWashUITests,PodWashSlowTests}/`.
If any source is newer (Engineer/QA just edited), they fall back to `test` so
fixes are actually compiled. Slice 12’s third halt graded a stale binary for
three verifies because products existed from a prior session.

`VERIFY RESULT` includes `class=build|tests`: `build` when `exit!=0` and 0 tests
ran (compile/link); `tests` otherwise. Consumers (`parse_verify_result`,
`RunProgress`, FailurePacket) use this instead of re-deriving build-vs-test.

`VERIFY_DRY_RUN=1` prints the resolved argv and exits 0 (unit tests: `scripts/test-verify-tiers.sh`).

## Authoring vs post-implement red policy

The factory distinguishes four red states with an **exclusive priority lattice**:

```
build  >  test_failure  >  infra/flake
```

| Phase | Policy |
|-------|--------|
| **TDD compile-red during authoring** (`story`…`test_review`) | Never counted toward thrash; `verify.sh` / `xcodebuild test` cancelled (ban, no budget burn) |
| **Sim install/launch/bootstrap (tier-2)** | Infra cold-retry + `ensure_sim_booted` — **does not** burn Engineer/QA fix budget (slice 12 death-run). Identical failure signature on a cold retry aborts further retries (deterministic ≠ flake). |
| **Build-red after implement** | `class=build` / `build_error:` / missing bundle executable → Engineer; **never** infra cold-retry (slice 13: CoreSimulator in stdout must not override `class=build`) |
| **Test-red after implement** | Assertion / harness → Engineer\|QA (`resolve_tier2_continue`: XCTestExpectation double-fulfill → QA; same hyp+sig escalates to predicate-wait lever) |

**Invariants (enforced in Python + `test_factory_hardening.py`):**

1. `VERIFY RESULT class=build` or `failure_class=build_error` ⇒ `is_tier2_infra_failure` is False.
2. Infra classification uses **curated** failure text only (never full xcodebuild stdout).
3. Phrase-level infra markers only — never bare `dns` / `lock` / `coresimulator`.
4. Structured vs heuristic disagreement logs `CLASSIFIER DISAGREEMENT` and prefers structured.
5. After every fix worker, tier-0 (`build-for-testing`) runs; compile-red becomes the next pending outcome (skips tier-2 until build-green).
6. When failure class changes after the normal fix budget would halt, one **class-transition credit** grants a spawn (cap 1 per gate; total spawns ≤ `max_runs + 1`).

`verify.sh` also writes `build/test-results/verify-result.json` (machine-readable contract). Raw verify stdout is persisted as `verify-output-*.txt` / `verify-output-latest.txt` and copied into the session bundle on halt.

Red-verify thrash (`max_red_verifies=2`) applies only to coordinator-monitored /
post-implement grinding — **not** authoring-gate TDD compile-red. After
`test_spec` + `test_review` clear, the pipeline auto-commits test paths as
`slice-NN: test spec` so a later halt never orphans authored tests.

See also [`plans/factory-tier2-infra-qa-routing.md`](plans/factory-tier2-infra-qa-routing.md).

## Fix path (FailurePacket → stuck card → referee → ledger → fix)

Applies to **both** coordinator and pipeline modes via shared `run_fix_loop`.

```text
loop-owned verify.sh tier 3 (red)
  → FailurePacket (summary testFailures + exported attachments)
  → print + persist stuck card (build/test-results/stuck-slice-NN.txt)
  → LLM referee (plan mode, cheap model, sentinel-wrapped JSON verdict)
  → on parse fail: one free referee retry, then heuristic fallback (try-N)
  → ledger gate: same hyp+sig → reroute opposite role (does not halt while budget remains)
  → scope-contradiction guard (Engineer+test-only files → QA, and vice versa)
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

`scripts/referee.py` — plan-mode worker (`composer-2.5`) returns a **sentinel-wrapped** compact JSON line:

```text
VERDICT_JSON_BEGIN {"primary_failure":"…","role":"Engineer",…} VERDICT_JSON_END
```

Required keys: `primary_failure`, `failure_groups`, `role`, `fix_scope`, `files`, `instruction`, `hypothesis`, `confidence`, `narration`.

Python enforces:

| Outcome | Behavior |
|---------|----------|
| Parse fail | One free referee retry; then heuristic fallback with `heuristic:{class}:{sig}:try-N` (does **not** halt) |
| `confidence=low` / missing hypothesis | Halt (stuck card) |
| `fix_scope=app` / `role=Engineer` | Engineer |
| `fix_scope=tests` / `role=QA` | QA |
| Engineer + only test files (or QA + only app files) | Scope flip before spawn |

Raw referee transcripts are persisted to `build/test-results/referee-slice-NN-attempt-N.txt` (and `…-last.txt`). Session telemetry logs `parse_ok` / `parse_retry` / `parse_fail`.

Legacy `fix_playbooks.py` / diagnose helpers remain in-tree for tests but are **not** consulted by `run_fix_loop`.

### Hypothesis ledger

`build/test-results/ledger-slice-NN.jsonl` — durable across bridge death. Each attempt appends `{ts, attempt, role, hypothesis, files_touched, result_signature, verify_tier, outcome}`. Before spawning a fix worker, if the referee verdict's **hypothesis + signature** matches a prior entry, Python **reroutes to the opposite role** with a fresh `ledger-reroute:…:try-N` hypothesis (never pays for the same theory twice, never leaves budget on the table). Halt on ledger only after the fix budget is exhausted. Repeat signatures always get a **fresh** fix worker (new agent context) with the ledger attached.

### Verify ban (fix workers + authoring gates)

Fix-worker `RunProgress` uses `fix_worker=True` + `forced_role=` so logs show
`[Engineer]` / `[QA]`, nested red-verify thrash is disabled (`max_red_verifies=0`),
and shell `verify.sh` / `xcodebuild … test` is cancelled. First violation →
re-prompt; second → attempt burned.

Authoring-gate `RunProgress` uses `authoring_gate=True`: red verifies are ignored
(TDD compile-red expected), and verify shells are cancelled **without** burning
budget. The `test_spec` prompt also bans verify in text; the cancel is the hard
guarantee.

## Fix routing (P0)

| Signal | Worker |
|--------|--------|
| Referee `fix_scope=app` / `role=Engineer` | Engineer (`PodWash/PodWash/**`) |
| Referee `fix_scope=tests` / `role=QA` | QA (tests only) |
| Scope contradiction (role vs suggested files) | Flip role before spawn |
| Referee `confidence=low` | Halt (stuck card) |
| Unparseable referee JSON | Retry once → heuristic fallback (`try-N`) |
| Ledger hit (same hyp + signature) | Reroute opposite role while budget remains |
| Fix budget exhausted | Halt exit 5 (+ resume hint) |

Shared budget: `--max-fix-attempts` (default **3**) → exit **5** on exhaustion.
Budget **persists** across bridge retries. Flake cold-retry does **not** burn budget.
Referee calls (including one parse retry) do **not** burn budget (routing only).

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
  scripts.test_slice_loop_progress scripts.test_failure_packet -q
./scripts/test-verify-tiers.sh
scripts/slice-loop.sh --orchestrator pipeline --max 1   # unattended default
```

**P1 landed:** JSONL event log (`events-slice-NN.jsonl`), phase timeline, `SUMMARY:`
contract, shift-floor narrator (names + Murphy), pipeline default, implement exit =
tier-2 green (`tier2-slice-NN.ok`, `max_implement_verify_runs=3`), exit **6** infra vs
**5** thrash, sim pre-boot (`PODWASH_SIM_UDID`), crash watchdog, UITest stress-run (5×).

**P2 cancelled** — no Slice-10 replay; try the factory on slice 11+.
