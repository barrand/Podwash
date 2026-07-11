---
name: forge-fix
description: >-
  Diagnose PodWash Forge (slice-loop) halts and harden factory scripts/console
  messaging — never fix PodWash app or tests. Use when the forge breaks, thrash
  halt, TIER2 HALT, InfraHalt, WORKER VIOLATION, stuck card, session bundle, or
  the user invokes forge-fix / forge post-mortem.
disable-model-invocation: true
---

# forge-fix

Repeatable post-mortem for Forge breaks. Dig into what happened, why the factory
stopped, and harden the Forge so the next run is clearer and more robust.

## Automated path (Medic)

Unattended equivalent: `scripts/slice-loop.sh` (Medic **on by default**). The
Medic supervisor (`scripts/forge_supervisor.py` + `scripts/forge_medic.py`) embeds
this workflow (structured diagnose JSON → critic rubric → scripts-only implement
→ regression canary → factory suite). Prefer Medic for routine thrash/infra heals;
use this skill attended when Medic refuses (`lane=test`, critic block, denylist,
canary fail) or you want a human-led post-mortem. Opt out: `--no-self-heal`.

Reports land in `docs/forge/medic-reports/`. Ledger:
`build/test-results/medic-ledger.jsonl`.

## Hard bans

**In scope:** `scripts/slice_*.py`, `scripts/*factory*`, `scripts/verify.sh`,
`scripts/failure_packet.py`, `scripts/mechanic_fix.py`,
`scripts/factory_progress.py`, `scripts/fix_lanes.py`,
`scripts/session_bundle.py`, `scripts/sim_hygiene.py`, factory unit tests
(`scripts/test_factory_*.py`, `scripts/test_slice_*.py`,
`scripts/test_failure_packet.py`, etc.), and process docs under
`docs/slice-*.md` / `docs/plans/factory-*.md`.

**Out of scope — do not edit:**

- `PodWash/PodWash/**`
- `PodWash/PodWashTests/**`
- `PodWash/PodWashUITests/**`
- `PodWash/PodWashSlowTests/**`
- Slice story / AC rewrites
- “Get the slice green” by changing product code or tests

If a real app test failed, still diagnose the **factory’s** handling (opaque
halt lines, bad routing, verify-ban thrash, empty `still red: []`). Do not become
the Engineer for the slice.

## Mode

| Phase | Mode | Do |
|-------|------|----|
| Diagnose + propose | **Plan** (preferred) | Read artifacts/scripts; write post-mortem; propose factory patches |
| Land hardening | **Agent** | Edit factory scripts/tests/docs only, after user approves |
| Never | Debug-as-default | Do not open Debug to “fix the app.” Debug only if artifacts are insufficient *and* you must reproduce live `verify.sh`/sim infra |

If already in Agent mode: finish the diagnosis report **before** any edit.

## Workflow

Copy and track:

```
Forge-fix progress:
- [ ] Intake (slice id, exit, phase, bundle path)
- [ ] Evidence ladder
- [ ] Classify lane
- [ ] Diagnosis report (no edits yet)
- [ ] Plain-English summary (what broke / slice plan / forge harden plan)
- [ ] User approved hardening
- [ ] Land factory patches + unit tests
- [ ] Run factory unit tests
```

### 1. Intake

From the user’s paste or console:

- Slice id (`slice 18` → `18`)
- Loop exit: `5` = thrash, `6` = infra
- Phase: `TIER2-GATE` vs full-suite fix / `HALT`
- Session bundle path if logged

If missing, find newest:

`build/test-results/session-slice-*/halt.json`

### 2. Evidence ladder

Read in order; stop when root cause is clear:

1. `build/test-results/session-slice-NN/halt.json`
2. `session-slice-NN/verify-output.txt` (tail around `VERIFY RESULT`)
3. `stuck-slice-NN.txt` or bundle stuck card
4. `events-slice-NN.jsonl` — `verify_violation`, `TIER2-GATE`, `HALT`
5. `ledger-slice-NN.jsonl`
6. `git status` / `git diff` — only to see dirty tree left by workers, **not** to finish the slice

Details: [reference.md](reference.md).

### 3. Classify lane (exclusive priority)

Pick **one** primary lane:

1. **policy** — WORKER VIOLATION / verify ban / CANCELLED worker
2. **build** — `exit≠0`, `failed=0`, or `class=build`
3. **infra** — sim / destination / bridge markers
4. **test** — real XCTest ids in packet / stuck card
5. **messaging** — halt lied (e.g. `still red: []` while verify was red)

### 4. Diagnosis report (required before edits)

```markdown
## Forge post-mortem — slice NN

**Halt:** exit=N · phase=… · reason=…
**Lane:** policy | build | infra | test | messaging
**What happened:** 2–4 sentences, timeline from events
**Why the factory stopped:** root cause in scripts/ (not “tests failed”)
**App/product code:** leave alone / note only if workers left dirty tree
**Hardening:** specific files + behavior change
**Console upgrade:** exact log line(s) that should have been printed
**Regression test:** which unittest asserts the new behavior
```

### 4b. Plain-English summary (required — show the user)

After the technical post-mortem, always add a short section the user can read
without knowing factory internals. Use everyday language; avoid script names
unless helpful. Three parts, in order:

```markdown
## In simple terms

### What broke
One short paragraph: what the factory was trying to do, what actually failed,
and whether the app/tests are the problem or the factory pipeline is.

### Plan to fix the slice (if anything)
What the slice team should do next — or explicitly “nothing in app code; re-run
the loop after forge hardening.” Do not volunteer to fix the slice here.

### Plan to harden the forge
Numbered list (2–4 items): what we will change in `scripts/` so this class of
break is prevented or much clearer next time. Each item = one behavior change
in plain English, not a file diff.
```

**Tone:** direct, no jargon (“tier-2 gate” → “the factory’s slice-test check”).
**Honesty:** if the halt message lied or wasted Engineer attempts, say so plainly.

### Nightly-only tests (plain language)

When explaining halts or hardening, readers should know:

- **Fast tests** prove the slice on every run (Done gate, tier-2).
- **Nightly / slow tests** (`PodWashSlowTests`) are for heavy work (live ASR,
  benchmarks). They are **not** prerequisites for the next slice.
- Mapping tables may list slow tests for documentation; the factory must **not**
  schedule them on the default scheme during tier-2.

See `docs/slice-pipeline.md` § Fast vs nightly and ADR-003.

### 5. Harden the Forge

After user approval:

- Smallest change that prevents recurrence **and** improves console/narrator clarity
- Add/extend unit tests under `scripts/test_factory_*.py` (or related)
- Prefer encoding the bug in a unit test over re-running full `slice-loop`
- Do **not** re-run the full slice-loop as the “fix” unless the user asks

### 6. Verify factory changes

```bash
python3 -m unittest scripts.test_factory_hardening scripts.test_factory_p1 \
  scripts.test_slice_pipeline scripts.test_failure_packet -q
```

Also run any other `scripts/test_*.py` modules you touched.

## Success criteria

- Post-mortem names a factory root cause and a concrete `scripts/` hardening
- Plain-English summary answers what broke, slice next steps, and forge hardening
  in language a non-pipeline reader can follow
- No proposed or landed edits under `PodWash/PodWash/**` or test targets
- Console upgrade is specific (exact line shape), not “better logs”
- A regression test would fail before the hardening and pass after

## Additional resources

- Artifact map, exit codes, lanes, worked example: [reference.md](reference.md)
- Pipeline design: `docs/slice-pipeline.md`
- Runner / exit codes: `docs/slice-runner.md`
