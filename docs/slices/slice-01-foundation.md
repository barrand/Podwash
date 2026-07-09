# Slice 01 — Foundation: test harness, verify.sh, CI

| Field | Value |
|-------|-------|
| **ID** | 01 |
| **Title** | Foundation: test harness, verify.sh, CI |
| **Status** | Done |
| **Crux** | The user-created Xcode project runs its full test suite green via `scripts/verify.sh` locally **and** in GitHub Actions CI, with real (non-template) smoke tests and a committed fixtures directory. |

## PRD / spec references

- PRD §7 — Platform and tech stack (Swift + SwiftUI, iOS native)
- `docs/adr/000-foundations.md` §6 — test destination via `scripts/verify.sh` only

## Context: what already exists

The user created `PodWash/PodWash.xcodeproj` in Xcode (2026-07-08): app target `PodWash`, unit test target `PodWashTests`, UI test target `PodWashUITests`, scheme `PodWash`, deployment target **iOS 26.1**, bundle ID `com.barrandfarm.PodWash`. The remediation pass added `scripts/verify.sh`, `.github/workflows/test.yml`, and a **shared scheme** (`xcshareddata/xcschemes/PodWash.xcscheme` — the original was user-local only, which CI cannot see). This slice verifies all of it end to end and replaces Xcode's template placeholder tests with meaningful ones.

## Goal

Prove the build/test/CI loop every later slice depends on: full suite green locally and on a GitHub runner.

## Deliverables

- `PodWash/PodWashTests/SmokeTests.swift` — real smoke test (app module loads; a known type exists) replacing template `testExample`/`testPerformanceExample`
- `PodWash/PodWashUITests` trimmed to a fast `testLaunch` (drop the template `testLaunchPerformance`, which adds ~2 min per run for no signal)
- `PodWash/PodWashTests/Fixtures/README.md` — fixtures directory committed (gitignore already un-ignores it)
- Confirmation the **shared scheme** drives `xcodebuild test` (delete/ignore stale user-scheme assumptions)
- First green **CI run** on push (fast job in `.github/workflows/test.yml`)

## Depends on

- None

**Parallelizable:** No — everything else is blocked until this is Done.

## Out-of-scope

- Product features (RSS, playback, matching, ASR)
- Apple Developer account / device builds
- `PodWashSlowTests` target (created in Slice 05)

## Acceptance criteria

- [x] 1. `scripts/verify.sh` (full suite) exits 0 locally with failed = 0 and skipped = 0.
- [x] 2. `PodWashTests` contains ≥ 1 non-template smoke test that asserts on the app module (not an empty `testExample`).
- [x] 3. `PodWashUITests` contains a passing `testLaunch`; total UI test wall time < 120 s on the local machine.
- [x] 4. `PodWash/PodWashTests/Fixtures/` exists in the repo with a README describing fixture conventions and provenance rules.
- [x] 5. The `PodWash` scheme is **shared** (`PodWash/PodWash.xcodeproj/xcshareddata/xcschemes/PodWash.xcscheme` tracked in git).
- [x] 6. GitHub Actions fast job completes green on push (verify.sh full suite on the macOS runner). — CI run [28986955592](https://github.com/barrand/Podwash/actions/runs/28986955592) green on commit `237ad8f` (`test` job passed in 5m38s, 2026-07-09).

## Verification mapping

| AC# | Test file | Test method | Notes |
|-----|-----------|-------------|-------|
| 1 | — | — | Command-level: full `scripts/verify.sh` |
| 2 | `PodWash/PodWashTests/SmokeTests.swift` | `testAppModuleLoads` | QA writes at test spec |
| 3 | `PodWash/PodWashUITests/PodWashUITests.swift` | `testLaunch` | |
| 4 | — | — | Structural: file exists in git |
| 5 | — | — | Structural: shared scheme tracked in git |
| 6 | — | — | CI: green `test` workflow run on push |

## Verification commands

```bash
# Done gate — FULL suite, zero failures, zero skips:
scripts/verify.sh
```

CI check: latest `test` workflow run on the pushed commit is green (AC6). Note: AC6 requires a push, which per commit policy happens only when the user asks — the coordinator should ask the user to push (or for permission to push) to close AC6.

## Verification record (QA fills at Verify)

```
VERIFY RESULT: exit=0 total=3 passed=3 failed=0 skipped=0 filtered=0 bundle=build/test-results/verify-20260708-185754.xcresult
```

Full-suite run on 2026-07-08 (simulator: iPhone 17 Pro). Testing completed in
~107 s wall time (UI + unit), under the 120 s AC3 budget. 3 tests executed:
`SmokeTests.testAppModuleLoads`, `PodWashUITests.testLaunch`, and
`PodWashUITestsLaunchTests.testLaunch`.

## Done gate

- [x] Every AC mapped to a test; all rows in the mapping table filled
- [x] **Full suite green:** unfiltered `scripts/verify.sh` exit 0, failed 0, skipped 0
- [x] Verification record pasted above
- [x] Auto-commit on green: `slice-01: <short description>`

## Role artifacts

| Role | Gate | Artifact path |
|------|------|---------------|
| Architect | Waived (foundations pinned in ADR-000) | `docs/adr/000-foundations.md` |
| UX | Waived | — (no product UI) |
