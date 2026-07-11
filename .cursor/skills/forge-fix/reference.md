# forge-fix reference

Read this when diagnosing a Forge halt. Keep [SKILL.md](SKILL.md) as the workflow;
this file is the evidence map and worked examples.

**Factory v3:** one **Mechanic** worker; progress-based stop. See
[`docs/plans/factory-v3-mechanic.md`](../../../docs/plans/factory-v3-mechanic.md).

## Artifact inventory

All under `build/test-results/` (gitignored).

### Session bundle (first stop)

`build/test-results/session-slice-NN/` — written on thrash/infra halt:

| File | Contents |
|------|----------|
| `halt.json` | `reason`, `verify_result`, `failures`, `crashes`, `phase`, `extra` |
| `README.md` | Index of bundle contents |
| `stuck-card.txt` | Human stuck card |
| `ledger.jsonl` | Hypothesis ledger copy (audit log) |
| `events.jsonl` | Factory event timeline copy |
| `verify-output.txt` | Latest verify stdout/stderr |
| `verify-result.json` | Machine-readable VERIFY RESULT |
| `xcresult-path.txt` | Path to relevant `.xcresult` |

### Persistent artifacts

| Path | When |
|------|------|
| `stuck-slice-NN.txt` | Every red loop-owned verify + thrash halt |
| `ledger-slice-NN.jsonl` | Each Mechanic cycle |
| `events-slice-NN.jsonl` | Phases: `TIER2-VERIFY`, `FULL-VERIFY`, `FIX-N`, `HALT`, … |
| `verify-output-latest.txt` | Every `run_verify` |
| `verify-result.json` | Every `verify.sh` run |
| `verify-*.xcresult` | Test runs (tiers 1–3) |
| `tier2-slice-NN.ok` | Tier-2 gate went green |

### Console prefixes

- `[slice-loop]` — harness
- `[slice NN][Mechanic Name]` — fix worker progress
- `LANE HINT: …` — optional recipe (not a role route)
- `PROGRESS:` / `NO PROGRESS:` / `THRASH HALT:` — progress rule
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
| **5** | **ThrashHalt** — no progress / hard cap / review blocked ×2 |
| **6** | **InfraHalt** — bridge/DNS/sim (retry-safe) |

`halt.json` `extra.halt_kind` distinguishes **`hard_cap`** (Mechanic minute/spawn
ceiling; verify wall clock excluded) from **`no_progress`** / review thrash.
Hard-cap reasons start with `HARD CAP:` — never `no progress 0/2`.

## Verify tiers

| Tier | Action | When |
|------|--------|------|
| 0 | `build-for-testing` | Warm / post-edit compile check |
| 1 | Failed tests only | After each Mechanic cycle |
| 2 | Slice-mapped tests | Implement exit gate |
| 3 | Full unfiltered suite | Done gate |

**Green contract:** `exit == 0` and `failed == 0` and `skipped == 0`.

UITest / unfiltered runs omit `-retry-tests-on-failure` (Factory v3). Unit-only
filtered runs may still retry once. UITest fixes get stress confirmation (3×).

## Optional lane hints

| Lane | Suggested recipe |
|------|------------------|
| `packaging` | Restore app bundle executable |
| `expectation_api` | Fix KVO / expectation double-fulfill in tests |
| `artifact_fixture` | Regenerate committed benchmark artifact |
| `adr_citation` | Fill ADR § Benchmark results from fixture |
| `build` | Fix compile/link |

Mechanic may ignore a wrong hint.

## Progress rule

Continue while signature changes or failure count drops. Halt when:

- identical signature 2 consecutive cycles, or
- signature repeats inside oscillation window (N=4), or
- `stress_flake` ×2 with no test-harness delta, or
- test/ADR diff review blocked ×2, or
- hard cap (8 spawns / 45 min)

## Anti-cheat

- Never mix app + tests in one commit (`check-test-isolation.sh`)
- Mechanic deltas auto-split: `fix tests` → `fix app` → `fix docs`
- Non-trivial test-target diff → readonly QA review before Done
- ADR diff → readonly Architect review before Done
