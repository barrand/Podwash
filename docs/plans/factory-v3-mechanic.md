# Factory v3 — the Mechanic (one fix worker, no routing)

**Status:** landed · 2026-07-10 (Phases 1+2+4; Phase 3 resume deferred)
**Motivation:** six thrash halts across five slices, all caused by the fix loop's
role routing, count-based budgets, or worker amnesia — never by the authoring
gates. ~20 of 71 repo commits are factory hardening. The factory must stop
needing a post-mortem per slice.

## Evidence (why patching again won't work)

| Slice | Halt | Root cause class |
|-------|------|------------------|
| 09 | red verify limit 2/2 | count-based stop while failure signature was changing (progress) |
| 11 | `no new hypothesis` ledger halt | fresh agents re-proposing old theories (amnesia) |
| 12 | tier-2 3 runs — expectation API | budget exhausted mid-diagnosis |
| 13 | tier-2 3 runs — build error | new failure class arrived after budget died → class-transition credit invented |
| 18 | tier-2 3 runs — ADR citation | wrong role owned the fix → adr_citation lane invented |
| 19a | tier-2 3 runs — handoff dropped | Engineer's `out_of_scope→QA` flip discarded at budget edge → handoff credit invented |
| 19b | fix budget — Architect at a UITest | no-edit rotation pulled Architect into a UI failure → Architect-skip invented |
| 19c | fix budget — green then stress-red | stress-run red on last attempt had no credit path |

Three root causes, not eight:

1. **Role routing.** Fix work is split across Engineer (app only), QA (tests
   only), Architect (ADRs only). Real failures span those boundaries (slice 19:
   remove UISwitch hit-thief **and** change tap harness). Each worker lands half
   a fix; each half-fix verifies red; each red burns budget. The shuttle
   machinery — `HANDOFF:` regex, git-delta observation, no-edit flips, referee
   role verdicts, credits, fingerprints — is ~800 lines that exists only
   because one fix is split across three agents. Every mechanism has had a
   post-mortem.
2. **Count-based budgets.** `max_attempts=3` cannot distinguish thrash (same
   failure, no progress) from a multi-step fix (signature changing every
   cycle). The credit zoo (class-transition, handoff, proposed stress) is the
   symptom: each credit un-halts one specific flavor of legitimate progress.
3. **Worker amnesia.** Fresh SDK agent per attempt; context re-packed into
   prompts; hypothesis ledger doing fragile text-matching to stop re-proposals.
   Slice 19: three QA agents each re-read `SettingsUITests.swift` and re-derived
   overlapping theories.

Structural multiplier: `slice_pipeline.py` (4,019 lines) contains **two
near-duplicate fix loops** (tier-2 gate + full-suite). Every fix lands twice or
diverges (the handoff credit landed in both copies on 2026-07-10).

Flake incoherence: `verify.sh` runs `-retry-tests-on-failure -test-iterations 2`
on tiers 1–3 (a test may pass Done while flaky) while the stress policy demands
5 straight greens (a fixed test may "fail" stress). Two contradictory
definitions of green.

## Design

### Phase 1 — one fix worker ("Mechanic"), no routing

When loop-owned verify is red (tier-2 gate or full-suite), spawn a single
**Mechanic** worker with write access to app code, tests, fixtures, and ADRs in
the same session.

Deleted outright (no longer reachable — do **not** leave behind a
`FIX_ROUTER=legacy` flag):

- `scripts/referee.py` + parse retry/fallback machinery in the pipeline
- `HANDOFF:` flip resolution, no-edit reroutes, `alternate_fix_role`
- Handoff credits, class-transition credits, Architect-skip rules
- Scope-contradiction guard, `fix_scope` role coercion, per-role path filters
  *in the fix loop* (commit-time isolation remains, below)
- Role-routing unit tests that assert Engineer|QA|Architect shuttle behavior
  (migrate useful cases into `scripts/test_factory_v3.py`; delete the rest)

Kept:

- FailurePacket + stuck card (become Mechanic context directly)
- Hypothesis ledger as a **log** (not an anti-repeat gate — never halt on
  ledger match in v3; see Phase 3)
- Deterministic *instruction* lanes (packaging / expectation_api /
  artifact_fixture / adr_citation / build) as **optional prompt hints** —
  they no longer route roles. Wrong lane must not bias the Mechanic; the
  prompt says the lane is a suggested recipe the worker may ignore
- Verify ban (loop owns verify), sim hygiene, event log, narrator

**Anti-cheat moves to where it is enforceable — commit time and Done:**

1. `check-test-isolation.sh` still forbids app+tests in one commit. Tests are
   already committed (`slice-NN: test spec`) before the fix loop runs, so any
   Mechanic test edit is a reviewable diff against a committed baseline.
2. **Commit splitting (loop-owned):** when a Mechanic cycle's in-scope delta
   touches both `PodWash/PodWash/**` and
   `PodWash/{PodWashTests,PodWashUITests,PodWashSlowTests}/**`, the loop
   auto-splits into two commits before Done — e.g. `slice-NN: fix tests` then
   `slice-NN: fix app` (tests first when both changed). Never a mixed commit.
   ADR-only or docs-only deltas commit separately from app/tests as today.
3. Mechanic prompt: never weaken assertions, thresholds, or goldens; never
   XCTSkip a core AC (same text QA carries today).
4. **Test-diff review gate (new, cheap):** if the Mechanic's cumulative fix
   delta touches any non-trivial path under
   `PodWashTests|PodWashUITests|PodWashSlowTests` (any edit except pure
   comments/whitespace — not only assertion/golden lines), spawn a
   **readonly QA diff review** before Done. Reviewer sees the diff + the AC
   mapping and reports blocker/clear.
5. **ADR-diff review gate (new, cheap):** if the cumulative fix delta touches
   `docs/adr/**`, spawn a **readonly Architect diff review** before Done
   (same blocker/clear contract). Slice 18 makes ADR edits a real fix path;
   a bent ADR must not silently "fix" a citation failure.
6. **Review-loop cap:** blocker → one Mechanic cycle to address → re-review.
   After **2 consecutive blocked reviews** (QA or Architect), halt with exit 5
   and a stuck card. Review ping-pong must not replace role ping-pong.
7. QA-verifier readonly pass at Done (unchanged).

Authoring gates (PM story → Architect ADR → QA+PM ADR review → QA test spec →
Architect test review → Engineer implement) are **unchanged** — zero of the
eight halts happened there. Engineer remains the implement-gate author; the
Mechanic exists only after loop-owned verify goes red.

### Phase 2 — one fix loop, progress-based stopping

Unify the tier-2 gate loop and the full-suite fix loop into a single
`run_fix_cycle` loop parameterized by verify tier (2 vs 3, tier-1 re-verify
inside). One code path, one set of tests.

#### Signature / family contract (load-bearing — unit-test it)

| Term | Definition |
|------|------------|
| **Failure signature** | Canonical string: sorted failing test ids + normalized failure class (`build` / `assert` / `ui_race` / `stress_flake` / `infra` / …). Empty failing set = green (no signature). |
| **Progress** | Signature set changed **or** failure count strictly dropped vs the previous cycle. |
| **No progress** | Signature identical to the previous cycle, **or** signature equals any signature already seen in the last **N=4** cycles (oscillation window). |
| **Resume family** (Phase 3) | Same family iff Jaccard similarity of failing test-id sets ≥ 0.5 **or** the symmetric difference is at most one test id. Otherwise treat as a material signature change → fresh spawn. |

Replace count budgets with a **progress rule**:

- After each Mechanic cycle, compare the normalized failure signature using the
  contract above.
- **Continue** while there is progress, regardless of how many cycles that takes.
- **Halt (exit 5)** when there is no progress for **2 consecutive cycles**
  (true thrash), or at a sanity hard cap (**8 Mechanic spawns** or **45 min of
  Mechanic agent time**, whichever first) to bound LLM spend. **`verify.sh`
  wall clock is excluded** from the minute budget — pause the Mechanic timer
  around every verify (initial + tier-1/2/3 + stress). Hard-cap halts use
  `halt_kind=hard_cap` and a `HARD CAP:` message (not `no progress 0/2`).
- **Stress-flake thrash:** green → stress-red is a `stress_flake` signature
  family (not a failed attempt). After the dedicated determinism recipe is
  applied, **2 consecutive `stress_flake` cycles with no in-scope harness
  delta** (test wait/query/setup edits) count as no progress and halt — do not
  burn the full 8/45 cap on unbounded flake churn.
- Free (never counted toward the spawn cap **or** the Mechanic minute budget):
  infra cold-retries, flake cold-retry, stress *confirmation* repeats after
  green, tier-0 compile checks, test-diff / ADR-diff reviews, and **all
  `verify.sh` runs**.

Under this rule, slices 09, 12, 13, 19a/b/c complete; slice 11's genuine
same-signature thrash still halts, one cycle earlier than today.

Console (exact shapes):

```text
PROGRESS: signature changed (3 failures → 1) — continuing (cycle 4, cap 8)
NO PROGRESS 1/2: identical signature after Mechanic cycle
NO PROGRESS 1/2: signature seen in window (oscillation)
THRASH HALT: no progress 2/2 on sig=…; cycles=5/8; last=stress-flake after green
HARD CAP: fix loop mechanic 44m / 45m limit — verify consumed 60m, mechanic spawns 1/8; denying spawn 2/8
```

### Phase 3 — continuity: resume, don't respawn

**Tension with v2:** Factory v2 treated fresh workers as a win (nobody doubled
down on a stale theory). Phase 3 bets the opposite for *stable* failure
families. Resume is therefore guarded, not always-on — and v3 ships without
it (see Rollout).

While the failure signature stays in the same **resume family** (contract
above), **and** the last Mechanic cycle produced a non-empty in-scope delta,
**resume the same Mechanic agent** for the next cycle instead of spawning
fresh. Fresh spawn when:

- the signature leaves the resume family (material change), or
- the resumed agent stalls twice (no in-scope delta), or
- the last cycle had no in-scope delta (do not resume a no-op agent)

Requires a small bridge spike: `run_worker` currently creates one SDK agent
per call; the Cursor SDK supports agent resume — extend the bridge to hold
and resume the agent handle across cycles.

The hypothesis ledger stays as a durable log (bridge-death recovery, prompts
for *fresh* spawns) but stops being the primary anti-repeat mechanism — a
resumed agent remembers what it tried. **Never halt on ledger match in v3.**

### Phase 4 — one definition of green

Land Phase 4 in the **same change as Phases 1+2**, and **before** trusting
progress signatures in production — otherwise UITest retries will mask flakes
that then look like signature thrash under the progress rule.

- Drop `-retry-tests-on-failure -test-iterations 2` for **UITest** targets in
  `verify.sh` (keep for unit tiers if desired, or drop everywhere).
- Keep the stress-run (reduce 5× → 3× to recover the cost of dropped retries)
  as *confirmation* after a UITest flips green.
- Green-then-stress-red is a `stress_flake` outcome, not a failed attempt: the
  Mechanic resumes with a dedicated recipe ("make this test deterministic —
  hermetic waits, re-resolved queries, no coordinate taps"), and the progress
  rule treats it as its own signature family (see stress-flake thrash above).
- Done gate unchanged: full unfiltered suite, exit 0, failed 0, skipped 0.

## What gets deleted (estimate)

| Surface | Lines (approx) | Action |
|---------|----------------|--------|
| `referee.py` + parse retry/fallback in pipeline | ~500 | **Delete** file; strip call sites |
| Role rotation / handoff flips / credits / scope guards in fix paths | ~450 | **Delete** — no legacy flag |
| Duplicated second fix loop | ~500 | **Unify** into `run_fix_cycle` |
| Role-shuttle unit tests obsolete under Mechanic | varies | **Delete** or migrate into `test_factory_v3.py` |
| Net removal | **~1,200–1,400** | |

The deleted lines are precisely the ones that generated all five post-mortems.
Do not reintroduce role routing behind a feature flag.

## Risks and mitigations

| Risk | Mitigation |
|------|------------|
| Mechanic bends tests to pass broken code | Tests pre-committed (diffable baseline); widened test-diff review; QA-verifier readonly at Done; prompt bans + ledger audit trail |
| Mechanic bends ADRs to pass citation failures | ADR-diff review gate (Architect readonly) |
| Review ping-pong | Cap: 2 consecutive blocked reviews → exit 5 |
| Progress rule loops on oscillating signatures (A→B→A→B) | Oscillation window N=4: seen-before signature = no-progress |
| Unbounded stress_flake churn | 2 stress_flake cycles with no harness delta → thrash halt |
| Hard cap too generous (spend) | 8 spawns / 45 min **Mechanic agent time** is a ceiling, not a target; thrash rule usually fires first; verify wall clock excluded |
| Resume keeps a confused agent alive (v2 fresh-context tension) | Resume only on stable family **and** last cycle had in-scope delta; stall twice → fresh spawn |
| Mixed app+tests commit | Loop auto-splits commits; `check-test-isolation.sh` still enforced |
| One worker loses adversarial tension | Tension preserved at authoring (QA writes tests first) and at Done (readonly verify); fix loop was never adversarial — it was ping-pong |
| Wrong instruction lane biases Mechanic | Lanes are optional hints the worker may ignore |

## Regression matrix (must pass before v3 ships)

Encode each historical halt as a unit test against the unified loop:

1. slice-09 shape: signature changes across cycles → no halt at cycle 2
2. slice-11 shape: identical signature 2 cycles → halt (exit 5)
3. slice-12/13 shape: failure class changes late → same Mechanic continues; no credit needed
4. slice-18 shape: ADR-citation failure → optional adr_citation hint in Mechanic prompt; Mechanic may edit `docs/adr/**`; ADR-diff review fires
5. slice-19a shape: worker says "test problem" → same session fixes the test; no handoff exists to drop
6. slice-19b shape: no Architect spawn possible on a UITest failure
7. slice-19c shape: green → stress-red → `stress_flake` cycle, not a halt
8. Anti-cheat: any non-trivial test-target diff → test-diff review gate fires; app+tests never in one commit (auto-split)
9. Oscillation: A→B→A signatures → halt on the repeat (window)
10. Stress-flake thrash: 2 stress_flake cycles, no harness delta → exit 5
11. Review cap: 2 consecutive blocked test- or ADR-diff reviews → exit 5
12. Signature contract helpers: progress / no-progress / resume-family / window — pure unit tests

Run: `python3 -m unittest scripts.test_factory_hardening scripts.test_factory_p1 scripts.test_slice_pipeline scripts.test_fix_lanes scripts.test_failure_packet -q`
plus a new `scripts/test_factory_v3.py` carrying the matrix above.

## Rollout

1. **Land Phases 1+2+4 together** (unified loop + Mechanic + flake coherence).
   Feature branch; regression matrix green. Phase 4 must land before progress
   signatures are trusted on real UITest failures.
2. **Acceptance gate (not "slice 19 warm"):** regression matrix green **and**
   one **synthetic** red→Mechanic→green fixture (scripted FailurePacket +
   stub verify outcomes exercising progress, oscillation, stress_flake, and
   commit split). Do not use a half-fixed live slice as the sole acceptance
   test — working-tree churn on slice 19 is entangled with product fixes.
   Optional later: a clean warm `slice-loop.sh --max 1` on a known-red slice
   once the synthetic gate passes.
3. Phase 3 (resume) is a follow-up spike — v3 works without it; it removes the
   amnesia tax when the bridge supports it. Ship resume only with the guarded
   rules above.
4. Update `docs/slice-pipeline.md` (§ Fix path, § budgets; mark handoff/credit
   sections historical) and `.cursor/skills/forge-fix/reference.md` (lanes
   table, console lines) in the same change. Supersede
   `docs/plans/factory-handoffs.md` (mark superseded by this plan).

## Out of scope

- Authoring gates, plan-review gates, verify tiers 0–3 (commit *policy* stays;
  commit *splitting* for Mechanic deltas is in scope above)
- Slice 19's actual Settings UITest fix (product work, not the v3 acceptance gate)
- Narrator/Murphy (cosmetic; keep, but never blame Murphy for a policy halt)
- Mechanic model slug / billing choice (implementer picks Engineer-class or
  cheaper; not a design constraint)
- Attended coordinator-mode fix-path doc/rule updates (follow-up; pipeline is
  the v3 target)
