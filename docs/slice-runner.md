# Slice runner — `scripts/next-slice.sh`

> **Onboarding (fresh agent):** [`dark-factory.md`](dark-factory.md) — start here for
> how the factory, coordinator sessions, and scripts fit together. This page is the
> technical reference for the runner scripts.
> It reads the slice stories under [`docs/slices/`](slices/README.md), respects
> each slice's `## Depends on` graph and halt-and-ask gates, and tells you the
> single next slice to run — plus a copy-paste coordinator prompt.
>
> **Read-only.** The script never edits slice files or commits anything.
> **Sequential.** It picks one slice at a time (lowest eligible number).

## Why this exists

Process, roles, and gates live in [`multitask-workflow.md`](multitask-workflow.md):
one coordinator session per slice, `scripts/verify.sh` full-suite green is Done.
The open question that doc left as a "future upgrade" was chaining sessions so the
next slice starts when the previous one lands. `next-slice.sh` is the first,
robust piece of that: it removes the "which slice is next, and is it even
unblocked?" guesswork. Auto-triggering is a deferred phase (see below).

## What it does

```mermaid
flowchart TD
  run["scripts/next-slice.sh"]
  parse["Parse every docs/slices/slice-NN-*.md"]
  decide{"Lowest not-Done slice<br/>with all deps Done?"}
  start["start: run this slice now"]
  halt["halt: needs a user decision first"]
  wait["wait: everything left is blocked"]
  done["done: queue complete"]

  run --> parse --> decide
  decide -->|eligible, not gated| start
  decide -->|eligible, halt-and-ask| halt
  decide -->|all remaining blocked| wait
  decide -->|nothing left| done
```

### Done finish-signal (conservative)

A slice counts as **Done** only when **both** are true, so a half-finished slice
never advances the queue:

1. Its file has `| **Status** | Done |`.
2. Its verification record has a line like
   `VERIFY RESULT: exit=0 ... failed=0 ... skipped=0`.

A slice whose status says `Done` but has no green `VERIFY RESULT` is treated as
**not done** — the runner surfaces it again so it gets finished properly.

### Eligibility and pick policy

- **Eligible** = not Done, and every dependency listed under `## Depends on` is Done.
- Among eligible slices, the runner picks the **lowest slice number** (sequential).
- Dependencies are read from bullet lines under `## Depends on` (e.g. `Slice 01`,
  `Slices 02, 05`, `None`). The `**Parallelizable:**` note directly under that
  heading is intentionally ignored — its slice numbers are not dependencies.

### Halt-and-ask gates

Some slices require a product decision before any agent starts (PRD §11). These
are hardcoded in the script (`HALT_SLICES`), derived from
[`docs/slices/README.md`](slices/README.md):

| Slice | Decision |
|-------|----------|
| ~~13~~ | ~~default word/category profile, default action, analysis timing~~ **Resolved 2026-07-10** — see PRD §11 and `slice-13-settings.md` § Product decisions |
| ~~15~~ | ~~CarPlay at MVP vs fast-follow~~ **Resolved 2026-07-10** — **MVP**; see PRD §11 and `slice-15-carplay.md` § Product decisions |
| ~~17~~ | ~~monetization model~~ **Resolved 2026-07-10** — **free at MVP**; StoreKit deferred post-MVP — see PRD §11 and `slice-17-storekit.md` § Product decisions |

`HALT_SLICES` is currently empty. Post-MVP / deferred slices (e.g. 17, 18, 19) are
skipped automatically when status contains `Deferred` or `post-MVP`.

Slice 11 persistence (Core Data) was resolved 2026-07-09 — see [ADR-007](adr/007-persistence-core-data.md).

The list is hardcoded (rather than scanning for the phrase "halt-and-ask")
because some slices mention halt-and-ask for a narrow sub-case only — e.g.
slice 05 mentions it just for lowering the iOS floor, and should not be gated.
If future slices add gates, edit `HALT_SLICES` at the top of the script.

## Usage

```bash
scripts/next-slice.sh            # human summary + copy-paste coordinator prompt
scripts/next-slice.sh --json     # one machine-readable JSON object
scripts/next-slice.sh --status   # table of every slice: ID, Status, DepsMet, BlockedBy
scripts/next-slice.sh --help
```

### Typical flow

1. Run `scripts/next-slice.sh`.
2. If it prints `Next slice: NN ...`, open a **new** coordinator chat and paste
   the printed prompt.
3. Let the coordinator run the slice to Done (full `scripts/verify.sh` green +
   verification record + auto-commit), per
   [`.cursor/rules/podwash-coordinator.mdc`](../.cursor/rules/podwash-coordinator.mdc).
4. Run `scripts/next-slice.sh` again for the next one.

### `--status` example

```
ID    Status       DepsMet   BlockedBy
--    ------       -------   ---------
01    Done         done      -
05    Draft        yes       -
07    Draft        no        5
11    Draft        no        6
```

`DepsMet`: `done` (slice complete), `yes` (ready to start), `no` (blocked).
`BlockedBy` lists the dependency slice IDs that are not yet Done.

## JSON contract

Exactly one JSON object on stdout. Consumers should branch on `action`.

**start** — run this slice:
```json
{"action":"start","id":5,"file":"docs/slices/slice-05-asr-spike.md","prompt":"Run Slice 05 per ..."}
```

**halt** — eligible but needs a user decision first (no active gates as of 2026-07-10;
example shape when `HALT_SLICES` is non-empty):
```json
{"action":"halt","id":17,"file":"docs/slices/slice-17-storekit.md","reason":"Slice 17 (StoreKit monetization) is a halt-and-ask gate — the user must make a product decision before this slice starts."}
```

**wait** — every remaining slice is blocked on an unfinished dependency:
```json
{"action":"wait","id":7,"blocked_by":[5,2],"message":"Slice 07 waiting on slice(s) 5 2"}
```

**done** — nothing left:
```json
{"action":"done","message":"No eligible slices remaining"}
```

Exit code is `0` for any action; `1` only on a usage or parse error.

## Tests

[`scripts/test-next-slice.sh`](../scripts/test-next-slice.sh) covers start,
sequencing, wait/blocked-by, halt, done, the Done-without-green guard, and a
smoke test against the real `docs/slices/`. It uses synthetic fixture slice
files via the `PODWASH_SLICES_DIR` environment override, so it needs no Xcode or
simulator and can run in CI.

```bash
scripts/test-next-slice.sh
```

## Phase 2 — the auto-run loop (built)

[`scripts/slice-loop.sh`](../scripts/slice-loop.sh) (driver:
[`scripts/slice_loop.py`](../scripts/slice_loop.py)) closes the loop: it runs
eligible slices to Done, one after another, unattended, on your Mac.

### Why local (and not a Cursor Automation)

The Done gate is `scripts/verify.sh`, which needs **Xcode + the iOS Simulator**.
Those exist only on your machine, not on Cursor's cloud infrastructure — and
Cursor Automations run as cloud agents. So a cloud automation could *detect* that
the next slice is eligible but could never *verify* an iOS slice. The loop
therefore runs a **local** Cursor SDK agent (`local.cwd = repo root`), where
`verify.sh` works for real.

### How it works

```mermaid
flowchart TD
  q["next-slice.sh --json"]
  a{action}
  runslice["Local SDK coordinator agent runs the slice"]
  recheck["next-slice.sh --json again"]
  advanced{"slice flipped to Done?"}
  stop["stop + report"]
  loop["loop"]

  q --> a
  a -->|start| runslice
  a -->|halt| stop
  a -->|wait| stop
  a -->|done| stop
  runslice --> recheck --> advanced
  advanced -->|yes| loop
  advanced -->|no| stop
  loop --> q
```

**Verification honesty:** the loop advances only when `next-slice.sh` re-confirms
the slice is no longer the `start` target — i.e. its status flipped to Done with a
green `VERIFY RESULT`. It never trusts the agent's self-report, and a no-progress
guard stops it from re-running the same slice twice. Halt-and-ask and verify
failures stop the loop with a clear message rather than guessing.

### Prerequisites

- **Python 3.10+** for `cursor-sdk`. On macOS, `/usr/bin/python3` is often **3.9**
  (from Xcode) and cannot install the SDK. `slice-loop.sh` auto-selects
  `python3.13` / `python3.12` / … if present (e.g. `brew install python@3.12`).
  Override: `PODWASH_PYTHON=python3.12 scripts/slice-loop.sh`
- **`CURSOR_API_KEY`** — create at [Cursor Dashboard → Integrations](https://cursor.com/dashboard/integrations)
  (user API key or team service-account key; starts with `cursor_...`).

### Usage

```bash
export CURSOR_API_KEY=cursor_...        # user or team service-account key

scripts/slice-loop.sh                    # coordinator mode (default) until it stops
scripts/slice-loop.sh --dry-run          # show the next decision; spawns no agent, no key needed
scripts/slice-loop.sh --max 3            # cap slices run this session (default 6)
scripts/slice-loop.sh --model auto       # let the server pick the coordinator model
scripts/slice-loop.sh --stream-timeout 0 # disable bridge stream idle cap (default; SDK is 600s)
scripts/slice-loop.sh --orchestrator pipeline   # Python gate FSM (see slice-pipeline.md)
scripts/slice-loop.sh --max-fix-attempts 2      # loop-owned Engineer|QA budget (default 2)
```

The wrapper creates an isolated venv under `build/` (gitignored) and installs
[`scripts/slice-loop-requirements.txt`](../scripts/slice-loop-requirements.txt)
(`cursor-sdk`). Design: [`slice-pipeline.md`](slice-pipeline.md).

**Orchestrator modes**

| Mode | Behavior |
|------|----------|
| `coordinator` (default) | One authoring LLM; **must not** run `verify.sh`. Loop owns verify + visible fix workers, then writes `VERIFY RESULT` + Status Done. |
| `pipeline` | Python `GateState` FSM + one SDK worker per gate; loop owns verify, record, split commits, push. |

Model ids are plain (`composer-2.5`, `grok-4.5`) — never Fast variants or bracket syntax.

**Bridge stream timeout:** the SDK defaults to a **600s** stream read timeout.
Quiet Engineer/`verify.sh` stretches longer than that look like
`Bridge request timed out: ReadTimeout` even while work continues. The loop
disables that cap by default (`--stream-timeout 0`) and retries retryable
bridge errors (`--bridge-retries`, default 3). Fix-attempt budget **persists**
across those retries.

### Exit codes

| Code | Meaning |
|------|---------|
| 0 | Queue complete, or `--max` reached cleanly |
| 1 | Agent never started (auth/config/network) |
| 2 | A slice ran but did not reach Done (agent error, red verify, or no progress) |
| 3 | `wait` — blocked on an unfinished dependency |
| 4 | `halt` — a halt-and-ask gate needs a user decision |
| 5 | `thrash` — loop-owned fix/verify budget exhausted |

### Notes and limits

- **Sequential.** One slice at a time (lowest eligible), matching the runner's
  policy. Parallel fan-out of independent slices (e.g. 06 ‖ 07) is not done here;
  run a second loop or a manual chat if you want concurrency.
- **Machine must stay awake.** It runs locally, so sleep/close ends the session.
- **Loop owns verify.** After authoring (or in pipeline mode), the driver runs
  `scripts/verify.sh` itself, routes red to Engineer|QA workers, and records
  Done artifacts. Pipeline mode also owns split commits + push (`--no-commit` /
  `--no-push` to disable).
- **`--dry-run` needs no key or SDK** — it just prints the next decision +
  orchestrator mode, so it is safe to run anytime (and is what the smoke test uses).
- **Simulator crashes are logged.** When verify/xcodebuild output contains
  `Crash: PodWash at …`, or a new `~/Library/Logs/DiagnosticReports/PodWash-*.ips`
  appears during the run, the loop prints `SIMULATOR CRASH detected` plus an
  `investigating crash` line so you can see the agent is acting on it.
- **Test failures are logged.** When verify/xcodebuild fails, the loop prints
  `TEST FAIL (verify/xcodebuild) — Class/method — XCTAssert… failed` (parsed from
  shell output, or from the newest `build/test-results/verify-*.xcresult` when
  output is sparse). Shell completion lines show `FAIL ×N` alongside `RED`.
- **Same-failure streak.** Repeating the same failing test logs
  `🔁 same failure ×N — Class/method` and heartbeats include `❌ testName ×N`.
- **Wrong-role spawn warning.** Spawning UX/PM/Architect to "fix" a test logs
  `⚠ WRONG ROLE` plus `allowed edits:` for that role (UX cannot edit app Swift).
  Prefer pipeline mode so the loop picks the role instead of guessing.
- **Anti-thrash halt.** After **`--max-fix-attempts`** (default 2) loop-owned
  fix attempts on red verify, the loop exits code **5**. Legacy coordinator shell
  thrash still uses `--max-red-verifies`. Disk work is preserved.
- **In Progress resume.** Coordinator prompt includes a RESUME + **handoff
  contract**: audit disk, skip completed authoring gates, **do not** run
  `verify.sh` — end when implement is ready so the loop can verify.
- **Parallel subagents.** Heartbeats show the preferred active role (Engineer
  over Architect review when both are open). A finished review logs
  `still running: Engineer` so long quiet stretches aren't misread as a stuck review.
- **Gate progress.** The loop prints `gates N/M ████░░ · next: implement` from
  slice-file + on-disk artifacts. Heuristic display (`assess_slice_gates`) vs
  pipeline FSM (`assess_gate_state`) — Done still requires green `VERIFY RESULT`.
- **Active work heartbeats.** While a subagent Task is open, heartbeats show
  `▶ UX: … (18m 22s)` instead of stale `last: ✓ Subagent done`.
  Background `verify.sh` / `xcodebuild` is sniffed via `ps` on the legacy path.

### Alternative (not built): Cursor Automation notifier

A **cloud** Automation on `slice-NN:` push could run `next-slice.sh --json` and
Slack/notify you which slice is next (or that the loop halted on a decision gate).
It cannot run `verify.sh`, so it is a notifier only — complementary to, not a
replacement for, the local loop.
