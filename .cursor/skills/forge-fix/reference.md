# forge-fix reference

Read this when diagnosing a Forge halt. Keep [SKILL.md](SKILL.md) as the workflow;
this file is the evidence map and worked examples.

## Artifact inventory

All under `build/test-results/` (gitignored).

### Session bundle (first stop)

`build/test-results/session-slice-NN/` — written on thrash/infra halt:

| File | Contents |
|------|----------|
| `halt.json` | `reason`, `verify_result`, `failures`, `crashes`, `phase`, `extra` |
| `README.md` | Index of bundle contents |
| `stuck-card.txt` | Human stuck card |
| `ledger.jsonl` | Hypothesis ledger copy |
| `events.jsonl` | Factory event timeline copy |
| `verify-output.txt` | Latest verify stdout/stderr |
| `verify-result.json` | Machine-readable VERIFY RESULT |
| `xcresult-path.txt` | Path to relevant `.xcresult` |
| `referee-last.txt` | Last referee transcript (if any) |

### Persistent artifacts

| Path | When |
|------|------|
| `stuck-slice-NN.txt` | Every red loop-owned verify + thrash halt |
| `ledger-slice-NN.jsonl` | Each fix / tier-2 attempt |
| `events-slice-NN.jsonl` | Phases: `TIER2-GATE`, `FIX-N`, `REFEREE`, `HALT`, … |
| `verify-output-latest.txt` | Every `run_verify` |
| `verify-output-t{tier}-{timestamp}.txt` | Per-tier timestamped output |
| `verify-result.json` | Every `verify.sh` run |
| `verify-*.xcresult` | Test runs (tiers 1–3) |
| `referee-slice-NN-attempt-N.txt` | Referee transcripts |
| `tier2-slice-NN.ok` | Tier-2 gate went green |

### Console prefixes

- `[slice-loop]` — harness
- `[slice NN][Role Name]` — worker progress
- `Forge · slice NN · …` — heartbeats
- `Forge recap · …` — end-of-slice summary

## Loop exit codes

| Code | Meaning |
|------|---------|
| 0 | Queue complete / `--max` clean |
| 1 | Agent never started (auth/config/network) |
| 2 | Slice ran but not Done |
| 3 | `wait` — blocked on dependency |
| 4 | `halt` — halt-and-ask gate |
| **5** | **ThrashHalt** — fix/verify budget exhausted |
| **6** | **InfraHalt** — bridge/DNS/sim (retry-safe) |

`TIER2 HALT` is still exit **5** (`ThrashHalt` from the implement tier-2 gate).

## Verify tiers

| Tier | Action | When |
|------|--------|------|
| 0 | `build-for-testing` | Warm / post-edit compile check |
| 1 | Failed tests only | After each fix attempt |
| 2 | Slice-mapped tests | Implement exit gate |
| 3 | Full unfiltered suite | Done gate |

**Tier-2 test selection:** `extract_mapped_test_ids(..., tier2=True)` skips mapping
rows whose Notes (or `— (live)` AC#) mark **nightly only** / **not a Done gate**.
Slow tests live in `PodWashSlowTests` and run via
`PODWASH_SCHEME=PodWashSlowTests` — not on the default scheme (slice 18 death-run).

**Green contract:** `exit == 0` and `failed == 0` and `skipped == 0`.

Tier 0: `exit == 0` counts green even with 0 tests.

When `exit != 0` and `total == 0` and `failed == 0` → treat as **build** class (tests never ran).

## Verify owned by loop

Only the Python loop may run `scripts/verify.sh` / `xcodebuild … test` for Done and post-implement fix.

**WORKER VIOLATION:**

1. First violation on a fix worker → cancel SDK run + re-prompt (edits may remain on disk)
2. Second violation → attempt burned (`verify_violation`)
3. Authoring gates: cancel, **no** budget burn (TDD compile-red expected)

`status=CANCELLED` after a verify ban means the worker tried to verify; the loop will still run its own tier-0 / tier-2.

## Failure lanes (decision tree)

```
halt.json / console
  │
  ├─ events show verify_violation / WORKER VIOLATION?
  │    → lane: policy (prompt compliance / ban UX)
  │
  ├─ verify_result: exit≠0 AND failed=0 (or class=build)?
  │    → lane: build (or infra if sim/destination markers)
  │
  ├─ infra markers (sim dead, destination, bridge)?
  │    → lane: infra (exit 6 path / cold-retry)
  │
  ├─ real test_ids in packet / stuck card?
  │    → lane: test (factory routing/messaging still in scope;
  │              do NOT fix PodWash Swift/tests here)
  │
  └─ failures empty but verify was red / still red: []?
       → lane: messaging (+ underlying build/infra/test)
```

Exclusive priority when multiple apply: **policy → build → infra → test → messaging**.

Messaging is often a **secondary** finding: always fix opaque halt lines when `still red: []` hides a real red verify.

### Fix-loop handoff lanes (factory routing)

When diagnosing thrash inside the fix/tier-2 loop (not forge-fix “who owns the product bug”):

| Console / halt | Meaning |
|----------------|---------|
| `LANE: artifact_fixture → QA` | Deterministic lane skipped referee; QA owns fixtures |
| `LANE: expectation_api → QA` | Double-fulfill / KVO harness |
| `LANE: packaging → Engineer` | Missing bundle executable |
| `LANE: build → Engineer` | Compile-red |
| `NO-EDIT: empty in-scope delta — next role=…` | Worker changed nothing in scope; flip next |
| `HANDOFF FLIP: …` | Worker `HANDOFF:` honored (empty in-scope delta) |
| `HANDOFF credit: spawning QA (pending flip; budget exhausted)` | Flip was pending at budget halt — one extra spawn granted |
| `HANDOFF IGNORED: …` | Worker claimed out_of_scope but edited in-scope paths |
| `NO-EDIT THRASH` | Explicit no-edit handoff twice on same signature |

## Key scripts

| Path | Role |
|------|------|
| `scripts/slice-loop.sh` | Shell wrapper |
| `scripts/slice_loop.py` | Driver, exit codes |
| `scripts/slice_pipeline.py` | Gate FSM, tier-2 gate, fix loop, thrash raises |
| `scripts/fix_lanes.py` | Deterministic lanes + HANDOFF parse + git delta helpers |
| `scripts/slice_loop_progress.py` | Telemetry, verify ban, `ThrashHalt` |
| `scripts/verify.sh` | Green source of truth |
| `scripts/failure_packet.py` | FailurePacket + stuck card |
| `scripts/referee.py` | Fix routing (plan-mode diagnose) for hard cases |
| `scripts/hypothesis_ledger.py` | Anti-repeat hypotheses |
| `scripts/session_bundle.py` | Halt bundle writer |
| `scripts/factory_narrator.py` | Console narration (Murphy, recap) |
| `scripts/sim_hygiene.py` | Sim / infra classification |

## Hardening regression tests

After factory patches:

```bash
python3 -m unittest scripts.test_factory_hardening scripts.test_factory_p1 \
  scripts.test_fix_lanes scripts.test_slice_pipeline scripts.test_failure_packet -q
```

Also: `./scripts/test-verify-tiers.sh` when touching `verify.sh` tiers.

## Worked example — slice 18 opaque tier-2 halt

### Console pattern

```
WORKER VIOLATION: verify owned by loop — do not run verify.sh …
status: CANCELLED
loop-owned verify: tier=0 … green=True exit=0
══ TIER2-GATE ══
loop-owned verify: tier=2 … green=False exit=70 failed=0
THRASH HALT: implement tier-2 gate failed after 3 runs; still red: []
TIER2 HALT: …
```

### Interpretation

1. **policy:** Fix worker ran verify; run cancelled (possibly attempt burned).
2. **build/infra:** Tier-0 compile green; tier-2 `exit=70` with `failed=0` means tests never ran (destination/install/abort), not an assertion failure.
3. **messaging:** Halt reason used only `outcome.failures[:3]` → empty `[]` while verify was red. Operator cannot see `exit=` / `class=` from the halt line alone.

### What to read

1. `session-slice-18/halt.json` — `verify_result.exit`, `class`
2. `session-slice-18/verify-output.txt` — xcodebuild stderr around exit 70
3. `events-slice-18.jsonl` — verify_violation + TIER2-GATE timeline
4. `stuck-slice-18.txt` — may have `build_error:` if packet caught it

### Factory hardening targets (not PodWash app)

- Halt reason includes `exit=`, `class=`, and `"opaque red (no test ids)"` when failures empty (`scripts/slice_pipeline.py` thrash raise for tier-2 / fix budget)
- When `failed=0` and `exit!=0`, log: build/infra abort before tests ran
- Clearer post-`verify_violation` line: attempt burned vs edits kept; loop will verify next
- Narrator: do not blame Murphy for non-test opaque reds

### Out of scope for forge-fix on this halt

- Editing slice-18 Swift / SlowTests to “get green”
- Re-running the full slice-loop as the primary fix (unless user asks after factory patches land)
