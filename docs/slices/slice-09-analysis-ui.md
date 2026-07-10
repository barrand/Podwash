# Slice 09 — Analysis progress UI + cleaning toggles

| Field | Value |
|-------|-------|
| **ID** | 09 |
| **Title** | Analysis progress UI + cleaning toggles |
| **Status** | Done |
| **Crux** | Per-channel and per-episode cleaning toggles plus an analysis progress indicator are drivable and assertable through accessibility identifiers with a stubbed (instant) pipeline. |

## PRD / spec references

- PRD §3 — Per-channel / per-episode toggles; clear UI indicators (badges for "channel on", "episode on", "analysis in progress", "off")

## Goal

Give the analyze-and-clean flow a visible, testable UI surface.

## Deliverables

- `AnalysisUIState` enum + `AnalysisUIViewModel` with four states and legal transitions
- `InMemoryCleaningToggleStore` for channel + per-episode toggle persistence (Slice 11 migrates to Core Data, ADR-007)
- Toggle UI on podcast (channel) header and episode rows; state badges per PRD §3
- Analysis progress indicator bound to pipeline analyzing state
- `FixtureAnalysis` launch argument for stubbed instant pipeline in UI tests
- `AnalysisUIStateTests` (view model), `AnalysisProgressUITests`

## Depends on

- Slices 06, 07

**Parallelizable:** Yes — with Slice 08 (different files; coordinator serializes any shared view model edits).

## Out-of-scope

- Settings screen (Slice 13); word-list management UI (Slice 13)
- Real long-running analysis in UI tests (stub only)
- Unrelated-content toggle (future slice)
- Playback action choice (mute vs skip) UI — Slice 08 backend only

## Acceptance criteria

- [ ] 1. Unit test: view model exposes exactly four states (`off`, `channelOn`, `episodeOn`, `analyzing`) and legal transitions between them; illegal transitions are rejected (state unchanged).
- [ ] 2. UI test: toggling episode cleaning on episode row 0 sets badge identifier `cleaningBadge_episodeOn`; channel toggle sets `cleaningBadge_channelOn`.
- [ ] 3. UI test (stubbed pipeline): starting analysis shows `analysisProgress` element; on completion (≤ 5 s) it disappears and `cleaningBadge_episodeOn` appears.
- [ ] 4. Unit test: toggle state persists across view model reload via `InMemoryCleaningToggleStore` (channel on + episode 0 on survive reload).
- [ ] 5. Full suite green via `scripts/verify.sh` (exit 0, 0 failed, 0 skipped).

## Verification mapping

| AC# | Test file | Test method | Notes |
|-----|-----------|-------------|-------|
| 1 | `PodWash/PodWashTests/AnalysisUIStateTests.swift` | `testStateMachineTransitions` | Asserts 4 states + legal/illegal transitions |
| 2 | `PodWash/PodWashUITests/AnalysisProgressUITests.swift` | `testToggleBadges` | Fixture feed + toggle taps |
| 3 | `PodWash/PodWashUITests/AnalysisProgressUITests.swift` | `testProgressIndicatorLifecycle` | `-UITestFixtureAnalysis` instant stub |
| 4 | `PodWash/PodWashTests/AnalysisUIStateTests.swift` | `testTogglePersistence` | In-memory store reload |
| 5 | — | — | `scripts/verify.sh` full suite |

## Verification commands

```bash
scripts/verify.sh -only-testing:PodWashTests/AnalysisUIStateTests -only-testing:PodWashUITests/AnalysisProgressUITests
scripts/verify.sh    # Done gate
```

## Verification record (QA fills at Verify)

```
VERIFY RESULT: exit=0 total=40 passed=40 failed=0 skipped=0 filtered=0 bundle=build/test-results/verify-20260709-155305.xcresult
```

## Plan review record

ADR review: waived (Architect gate waived — no new shared APIs; extends existing `PodcastDetailView` / `EpisodeListView`).

Test spec review (2026-07-09): Architect cleared on resume — tests map to ADR-000 + slice-09-ux identifiers; `InstantEpisodeAnalyzer` stub matches fixture contract; no blockers.

## Done gate

- [ ] Every AC mapped to a test; all rows filled
- [ ] **Full suite green:** unfiltered `scripts/verify.sh` exit 0, failed 0, skipped 0
- [ ] Verification record pasted above
- [ ] Auto-commit on green: `slice-09: <short description>`

## Role artifacts

| Role | Gate | Artifact path |
|------|------|---------------|
| Architect | Waived (no new shared APIs) | — |
| UX | Required | `docs/slices/slice-09-ux.md` |
| QA | Test spec | `PodWash/PodWashTests/AnalysisUIStateTests.swift`, `PodWash/PodWashUITests/AnalysisProgressUITests.swift` |
| Engineer | Implement | `AnalysisUIState.swift`, `AnalysisUIViewModel.swift`, `InMemoryCleaningToggleStore.swift`, `FixtureAnalysis.swift`, `InstantEpisodeAnalyzer.swift`, view wiring |
