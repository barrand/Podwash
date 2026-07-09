# Slice 09 — Analysis progress UI + cleaning toggles

| Field | Value |
|-------|-------|
| **ID** | 09 |
| **Title** | Analysis progress UI + cleaning toggles |
| **Status** | Draft |
| **Crux** | Per-channel and per-episode cleaning toggles plus an analysis progress indicator are drivable and assertable through accessibility identifiers with a stubbed (instant) pipeline. |

## PRD / spec references

- PRD §3 — Per-channel / per-episode toggles; clear UI indicators (badges for "channel on", "episode on", "analysis in progress", "off")

## Goal

Give the analyze-and-clean flow a visible, testable UI surface.

## Deliverables

- Toggle UI on podcast (channel) and episode views; state badges per PRD §3
- Analysis progress indicator bound to pipeline progress
- Stub pipeline injection for UI tests (launch argument, instant completion)
- `AnalysisUIStateTests` (view model), `AnalysisProgressUITests`

## Depends on

- Slices 06, 07

**Parallelizable:** Yes — with Slice 08 (different files; coordinator serializes any shared view model edits).

## Out-of-scope

- Settings screen (Slice 13); word-list management UI (Slice 13)
- Real long-running analysis in UI tests (stub only)

## Acceptance criteria

- [ ] 1. Unit test: view model exposes exactly four states (`off`, `channelOn`, `episodeOn`, `analyzing`) and legal transitions between them.
- [ ] 2. UI test: toggling episode cleaning sets badge identifier `cleaningBadge_episodeOn`; channel toggle sets `cleaningBadge_channelOn`.
- [ ] 3. UI test (stubbed pipeline): starting analysis shows `analysisProgress` element; on completion it disappears and the on-badge appears.
- [ ] 4. Unit test: toggle state persists across view model reload (in-memory store).
- [ ] 5. Full suite green via `scripts/verify.sh`.

## Verification mapping

| AC# | Test file | Test method | Notes |
|-----|-----------|-------------|-------|
| 1 | `PodWash/PodWashTests/AnalysisUIStateTests.swift` | `testStateMachineTransitions` | TBD |
| 2 | `PodWash/PodWashUITests/AnalysisProgressUITests.swift` | `testToggleBadges` | TBD |
| 3 | `PodWash/PodWashUITests/AnalysisProgressUITests.swift` | `testProgressIndicatorLifecycle` | Stubbed pipeline |
| 4 | `PodWash/PodWashTests/AnalysisUIStateTests.swift` | `testTogglePersistence` | TBD |
| 5 | — | — | Command-level |

## Verification commands

```bash
scripts/verify.sh -only-testing:PodWashTests/AnalysisUIStateTests -only-testing:PodWashUITests/AnalysisProgressUITests
scripts/verify.sh    # Done gate
```

## Verification record (QA fills at Verify)

```
VERIFY RESULT: (pending)
```

## Done gate

- [ ] Every AC mapped to a test; all rows filled
- [ ] **Full suite green:** unfiltered `scripts/verify.sh` exit 0, failed 0, skipped 0
- [ ] Verification record pasted above
- [ ] Auto-commit on green: `slice-09: <short description>`

## Role artifacts

| Role | Gate | Artifact path |
|------|------|---------------|
| Architect | Waived (no new shared APIs) | — |
| UX | Required | `docs/slices/slice-09-ux.md` (TBD) |
