# Factory: tier-2 infra cold-retry + QA harness routing (slice 12)

> Status: **factory fixes landed** (this session + follow-up). Slice 12 resume:
> `scripts/slice-loop.sh --max 1` with implement artifacts already on disk.

## Verdict

Slice 12 hit **three** distinct factory bugs across runs:

1. **Authoring thrash** — TDD compile-red counted toward red-verify budget (fixed earlier).
2. **Infra budget burn** — SBMainWorkspace install/launch counted as Engineer fix attempts.
3. **Stale tier-2 products** — after QA was correctly routed, tier 2 ran
   `test-without-building` against a binary from the *previous* session, so
   neither Engineer nor QA edits were ever compiled. Identical red ×3 in ~40s.

| Run (session 3) | Failure | What actually happened |
|-----------------|---------|------------------------|
| 1–3 | XCTestExpectation double fulfill | QA fixed the test on disk; verify never rebuilt |

## Factory fixes landed

1. **`classify_infra_failure`** — SBMainWorkspace / launchd / bootstrap markers.
2. **`classify_failure`** — sim launch → `flake`; expectation API violation → `assertion` + `fix_scope=tests`.
3. **`run_tier2_implement_gate`** — infra cold-retry (no fix budget); spawn Engineer\|QA via `resolve_tier2_continue`.
4. **`resolve_tier2_continue`** — packaging only for *missing bundle executable*; expectation → QA; lever 0 invalidate-before-setRate / lever 1 predicate wait on ledger escalate.
5. **`verify.sh` tiers 1–2** — rebuild when any Swift source is newer than the built `*.xctestrun` (slice 12 stale-binary death-run).
6. **Product unblock** — `PlaybackRateTests.waitForPlaying` uses `expectation(for: NSPredicate)` (no live KVO across `setRate`).

## Resume slice 12

```bash
rm -f build/test-results/ledger-slice-12.jsonl build/test-results/stuck-slice-12.txt
scripts/slice-loop.sh --max 1
```

Expect: tier-2 detects newer sources → incremental `test` build → predicate wait
runs → green → full suite → Done.

## Follow-up: slice 13 hardening (build vs infra lanes)

Slice 13 thrash-halted when Edison introduced a MainActor compile error. The loop
misclassified it as infra (`coresimulator` / soft `"lock"` ⊂ `"block"` on full
xcodebuild stdout), burned both cold retries, then halted without spawning on
`build_error`.

**Landed** (see `docs/slice-pipeline.md` § Authoring vs post-implement +
`scripts/test_factory_hardening.py`):

1. Exclusive lanes: `build > test > infra`
2. Curated-blob infra classification + phrase-level markers
3. Identical-signature cold-retry abort
4. Classifier disagreement alarm
5. `verify-result.json` + persisted verify stdout in session bundles
6. Post-edit tier-0 gate
7. Capped class-transition credit (1 per gate)

