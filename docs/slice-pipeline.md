# Slice pipeline — loop-as-orchestrator

> Design reference for `scripts/slice_pipeline.py` and `--orchestrator=pipeline`.
> Plan: [`plans/loop-as-orchestrator-refactor.md`](plans/loop-as-orchestrator-refactor.md).
> Factory v2: [`plans/factory-v2.md`](plans/factory-v2.md) (**P0 + P1 landed**; P2 cancelled).
> **Factory v3 (Mechanic):** [`plans/factory-v3-mechanic.md`](plans/factory-v3-mechanic.md) — **landed** (one fix worker, progress-based stop).
> Fix confidence: [`plans/factory-fix-confidence.md`](plans/factory-fix-confidence.md).
> Runner mechanics: [`slice-runner.md`](slice-runner.md).

## What moved into Python

| Concern | Owner |
|---------|--------|
| Gate ordering / skip-done | `GateState` + FSM in `slice_pipeline.py` |
| `scripts/verify.sh` (tiers 0–3) | Loop (subprocess) — source of truth |
| Red → FailurePacket + stuck card | `failure_packet.py` (evidence formats) |
| Red → **Mechanic** fix cycle | `mechanic_fix.py` + `factory_progress.py` (no role routing) |
| Hypothesis ledger (audit log) | `hypothesis_ledger.py` — log only; never halt on match |
| Event log + timeline + SUMMARY | `factory_events.py` |
| Shift-floor narrator + Murphy | `factory_narrator.py` (rendering only) |
| Sim pre-boot / crash watch / stress | `sim_hygiene.py` (UITest stress 3×) |
| Red → progress stop | signature progress / oscillation / hard cap 8 spawns or 45 min **Mechanic agent time** (verify excluded); exit 5 thrash|hard-cap / 6 infra |
| `VERIFY RESULT` + Status Done | Deterministic doc writer |
| Status Ready after story content | Deterministic doc writer (`set_slice_status`) |
| Split commits + isolation + push | Loop (pipeline mode); Mechanic deltas → `fix tests` / `fix app` / `fix docs` |
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
- Shift open: `════ SLICE 13 ════` banner (slice id, title, mission — printed once), then **one** coordinator line that does not repeat the banner (LLM or template fallback). `FORGE_LLM_NARRATION=0` disables floor LLM beats.
- Gate spawn: chapter open only — no duplicate `══ IMPLEMENT ══` timeline line after the `── Slice N · … ──` beat. Sim pre-boot uses `══ SIM ══`, not IMPLEMENT.
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

### Fast vs nightly (slow) tests

| Lane | Target | Done / tier-2 gate | When to add |
|------|--------|-------------------|-------------|
| **Fast** | `PodWashTests`, `PodWashUITests` | Every `verify.sh`; **skipped must be 0** | Default for all slice ACs |
| **Nightly / slow** | `PodWashSlowTests` | **Excluded** from tier-2 and Done | Live ML, long CPU, or regenerating committed benchmark JSON |

**Pattern:** fast tests validate **committed artifacts** (e.g. `benchmark-results.json`);
slow tests **regenerate** those artifacts when the heavy implementation changes.
Slow targets sit in the `PodWash` scheme with `skipped="YES"` for structural ACs
but run only via `PODWASH_SCHEME=PodWashSlowTests` (a skipped testable cannot
be forced with `-only-testing:` on the default scheme — ADR-003).

**Factory rule:** `extract_mapped_test_ids(..., tier2=True)` skips mapping rows
marked **nightly only** / **not a Done gate** / `— (live)`. Do **not** run slow
tests before other slices — they are optional regeneration / CI, not slice-queue
prerequisites.

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
| **TDD compile-red during authoring** (`story`…`test_review`) | Never counted toward thrash. Ban is **warn-only** (agent not cancelled). `verify.sh` banned; Architect may run spike-scoped `xcodebuild test -only-testing:…Spike` only |
| **Sim install/launch/bootstrap (tier-2)** | Infra cold-retry + `ensure_sim_booted` — **does not** burn Engineer/QA fix budget (slice 12 death-run). Identical failure signature on a cold retry aborts further retries (deterministic ≠ flake). |
| **Build-red after implement** | `class=build` / `build_error:` / missing bundle executable → Engineer; **never** infra cold-retry (slice 13: CoreSimulator in stdout must not override `class=build`) |
| **Test-red after implement** | Assertion / harness → Engineer\|QA (`resolve_tier2_continue`: XCTestExpectation double-fulfill → QA; same hyp+sig escalates to predicate-wait lever) |

**Invariants (enforced in Python + `test_factory_hardening.py` / `test_factory_v3.py`):**

1. `VERIFY RESULT class=build` or `failure_class=build_error` ⇒ `is_tier2_infra_failure` is False.
2. Infra classification uses **curated** failure text only (never full xcodebuild stdout).
3. Phrase-level infra markers only — never bare `dns` / `lock` / `coresimulator`.
4. Structured vs heuristic disagreement logs `CLASSIFIER DISAGREEMENT` and prefers structured.
5. Progress stop (not count budgets): continue while signature changes or failure count drops; halt on identical signature 2× or oscillation within window N=4; hard cap **8 Mechanic spawns** or **45 min of Mechanic agent time** (verify / `verify.sh` wall clock is **excluded** from the minute budget).
6. ~~class-transition credit~~ / ~~handoff credit~~ — **removed in Factory v3** (see historical note below).

`verify.sh` also writes `build/test-results/verify-result.json` (machine-readable contract). Raw verify stdout is persisted as `verify-output-*.txt` / `verify-output-latest.txt` and copied into the session bundle on halt.

Red-verify thrash applies only to coordinator-monitored /
post-implement grinding — **not** authoring-gate TDD compile-red. After
`test_spec` + `test_review` clear, the pipeline auto-commits test paths as
`slice-NN: test spec` so a later halt never orphans authored tests.

See also [`plans/factory-v3-mechanic.md`](plans/factory-v3-mechanic.md).

## Fix path (FailurePacket → Mechanic → progress stop)

Applies to **both** tier-2 implement gate and full-suite verify via unified
`run_fix_cycle` (`scripts/mechanic_fix.py`).

```text
loop-owned verify.sh (red)
  → FailurePacket + stuck card
  → optional lane HINT (packaging | expectation_api | artifact_fixture | adr_citation | build)
       — recipe only; Mechanic may ignore
  → Mechanic worker (app + tests + ADRs in one session)
  → git delta (all paths count; no per-role filter)
  → tier 1 re-verify → optional UITest stress (3×) → gate tier (2 or 3)
  → progress rule on normalized signature
  → on green: test-diff review (if tests changed) + ADR-diff review (if ADRs changed)
  → append ledger (audit log only — never halt on match)
  → commit split: fix tests → fix app → fix docs
```

Console:

```text
LANE HINT: expectation_api (optional — Mechanic may ignore)
PROGRESS: signature changed (3 failures → 1) — continuing (cycle 4, cap 8)
NO PROGRESS 1/2: identical signature after Mechanic cycle
NO PROGRESS 1/2: signature seen in window (oscillation)
THRASH HALT: no progress 2/2 on sig=…; cycles=5/8; last=stress-flake after green
```

### Deterministic lanes (`scripts/fix_lanes.py`)

Optional **prompt recipes** only (Factory v3 — no role routing):

| Lane | Suggested scope | Trigger |
|------|-----------------|---------|
| `packaging` | app | Missing bundle executable |
| `expectation_api` | tests | XCTestExpectation double-fulfill |
| `artifact_fixture` | tests | Regenerate / unparsable benchmark artifact |
| `adr_citation` | docs | ADR missing committed benchmark numbers |
| `build` | app | Compile/link red |

### Historical (v2 — superseded)

Role routing, LLM referee, `HANDOFF:` flips, class-transition / handoff credits,
and Engineer↔QA path filters are **deleted**. See
[`plans/factory-handoffs.md`](plans/factory-handoffs.md) (superseded) and
[`plans/factory-v3-mechanic.md`](plans/factory-v3-mechanic.md).

### Git baseline (observation-first)

Before each Mechanic cycle: snapshot `git status --porcelain` **and** fingerprints
(mtime+size) of already-dirty paths. After: ledger `files_touched` = new paths
plus dirty paths whose fingerprint changed.

### FailurePacket

Built by `scripts/failure_packet.py` from:

1. `xcresulttool get test-results summary` — **must** surface real test ids (never leave prompts on only `xcodebuild — TEST FAILED` when summary has names).
2. `xcresulttool export attachments --test-id 'Class/testName()'` — hierarchy + query-chain `.txt` files.
3. Soft undiagnosable: build/lock reds without test ids still produce an actionable packet. Hard-halt only when there is **no** actionable evidence and no bundle.

Signature (v3): sorted test ids + normalized failure class (`factory_progress.make_failure_signature`).

### Stuck card

Human-readable card printed on every red loop-owned verify and thrash halt, also
written to `build/test-results/stuck-slice-NN.txt`, and embedded in Mechanic prompts.

### Hypothesis ledger

`build/test-results/ledger-slice-NN.jsonl` — durable across bridge death. Each
Mechanic cycle appends `{ts, attempt, role, hypothesis, files_touched, …}`.
**Audit log only** in Factory v3 — never halt on a ledger match. Fresh Mechanic
prompts may include recent ledger lines for context.

### Verify ban (Mechanic + authoring gates)

Mechanic `RunProgress` uses `fix_worker=True` so shell `verify.sh` /
`xcodebuild … test` **cancels the agent run** (first violation re-prompts;
second burns). Authoring-gate `RunProgress` uses `authoring_gate=True`:
banned verifies are **warn-only** (no agent cancel — avoids CANCELLED →
bridge-close crashes). Architect may run spike-scoped
`xcodebuild test -only-testing:…Spike`; `verify.sh` and full-suite
`xcodebuild` stay banned. Bridge disconnect on agent close → `InfraHalt`
(exit 6) with a `BRIDGE-CLOSE` session bundle.

## Progress stop (Factory v3)

| Signal | Behavior |
|--------|----------|
| Signature changed or failure count dropped | Continue |
| Identical signature 2 consecutive cycles | `THRASH HALT` exit 5 |
| Signature seen in oscillation window (N=4) | Counts as no-progress |
| `stress_flake` ×2 with no harness delta | Thrash halt |
| Test- or ADR-diff review blocked ×2 | Thrash halt |
| Hard cap 8 Mechanic spawns or 45 min **Mechanic agent time** (verify excluded) | `HARD CAP` halt (exit 5; `halt_kind=hard_cap`) |
| Infra / flake cold-retry | Free (not a spawn) |

`--max-fix-attempts` maps to Mechanic spawn cap (default **8**).

## Partial-failure policy

- Reuse one `launch_bridge`; dispose each agent after its gate.
- If gate N fails after earlier gates produced artifacts: **leave artifacts on disk**,
  halt with gate id + attempt, **do not** auto-revert.
- Model ids are pinned in `ROLE_MODELS`; SDK spawns use `scripts/sdk_models.py` with `fast=false` — never bare ids (they bill as `*-fast`). IDE subagents may use frontmatter bracket syntax. Mechanic uses `grok-4.5`.

## Handoff contract (coordinator mode)

1. Coordinator authors only; ends when implement exists or status is Verify.
2. Loop always owns verify when implement is done **or** status ∈ `{In Progress, Verify}`.
3. Sequential only — never parallel loop verify with a coordinator-owned verify.

## Medic (self-heal)

Optional supervisor around the loop — **does not** live inside `slice_loop.py`
(heals must reload in a fresh process).

```bash
scripts/slice-loop.sh --self-heal --max 1
scripts/slice-loop.sh --self-heal --medic-no-push   # commit heal, skip push
```

| Concern | Owner |
|---------|--------|
| Subprocess `slice_loop` + exit dispatch | `forge_supervisor.py` |
| Diagnose / critic / implement prompts + quality gates | `forge_medic.py` |
| Halt signature dedup | `build/test-results/medic-ledger.jsonl` |
| Post-mortems | `docs/forge/medic-reports/` |

**When Medic runs:** exit **5** (thrash), or exit **6** after one free plain retry.

**Pipeline:** structured diagnose JSON → lane gate (`test` → human) → one-shot
critic rubric → implement (`scripts/**` only) → diff denylist (hard reject) →
regression canary (new test **fails** on pre-fix tree, **passes** after) →
full factory unit suite → commit `forge: harden …` → resume.

**Models:** Medic diagnose + implement = `grok-4.5` (`fast=false`, `effort=high`);
critic = `composer-2.5` (`fast=false`). Never fast variants.

**Anti-thrash:** one heal attempt per halt signature; max 2 per slice / 3 per
session. A recurring signature after a heal means the fix did not stick → human.

Default `--self-heal` is **off** until trusted. Manual
[`.cursor/skills/forge-fix/SKILL.md`](../.cursor/skills/forge-fix/SKILL.md)
remains for attended post-mortems.

## Unit tests

```bash
python3 -m unittest scripts.test_factory_v3 scripts.test_factory_p1 \
  scripts.test_fix_lanes scripts.test_factory_hardening \
  scripts.test_hypothesis_ledger scripts.test_slice_pipeline \
  scripts.test_slice_loop_progress scripts.test_failure_packet \
  scripts.test_forge_medic scripts.test_forge_supervisor -q
./scripts/test-verify-tiers.sh
scripts/slice-loop.sh --orchestrator pipeline --max 1   # unattended default
scripts/slice-loop.sh --self-heal --max 1               # optional Medic supervisor
```

**Factory v3 landed:** Mechanic (no role routing), unified `run_fix_cycle`,
progress-based stop, UITest verify retries dropped, stress-run 3×, test/ADR diff
reviews, commit split `fix tests` / `fix app` / `fix docs`. Phase 3 (agent
resume) deferred. **Medic supervisor** landed behind `--self-heal`.
