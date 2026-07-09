# Slice 15 — CarPlay

| Field | Value |
|-------|-------|
| **ID** | 15 |
| **Title** | CarPlay |
| **Status** | Draft |
| **Crux** | CarPlay audio-app templates (library/queue/now-playing) are driven by a testable data source; template contents are asserted on doubles — physical head-unit checks are documentation, never gates. |

## PRD / spec references

- PRD §2, §7 — CarPlay as native-controls requirement
- PRD §11 — ⚠️ Open decision: CarPlay at MVP vs fast-follow. Coordinator confirms with the user before starting this slice.

## Goal

CarPlay browsing and playback control through `CPListTemplate`/`CPNowPlayingTemplate`.

## Deliverables

- CarPlay scene delegate + entitlement request documentation (entitlement approval is an external, non-gate step)
- Template data source mapping subscriptions/queue to `CPListItem`s
- `CarPlayTemplateTests` (data source on doubles; no simulator head-unit dependency)

## Depends on

- Slices 11, 14

**Parallelizable:** Yes — with Slices 16, 17.

## Out-of-scope

- Physical head-unit verification as a Done gate (future automation target / manual spot-check only)
- CarPlay-specific settings

## Acceptance criteria

- [ ] 1. Unit test: data source produces one `CPListItem` per queued episode with title and artwork placeholder set.
- [ ] 2. Unit test: selecting a list item (invoked programmatically) starts playback of that episode (engine spy).
- [ ] 3. Unit test: play state changes propagate to the now-playing template double.
- [ ] 4. Full suite green via `scripts/verify.sh`.

## Verification mapping

| AC# | Test file | Test method | Notes |
|-----|-----------|-------------|-------|
| 1 | `PodWash/PodWashTests/CarPlayTemplateTests.swift` | `testListItemsFromQueue` | TBD |
| 2 | `PodWash/PodWashTests/CarPlayTemplateTests.swift` | `testSelectionStartsPlayback` | TBD |
| 3 | `PodWash/PodWashTests/CarPlayTemplateTests.swift` | `testNowPlayingStatePropagation` | TBD |
| 4 | — | — | Command-level |

## Verification commands

```bash
scripts/verify.sh -only-testing:PodWashTests/CarPlayTemplateTests
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
- [ ] Auto-commit on green: `slice-15: <short description>`

## Role artifacts

| Role | Gate | Artifact path |
|------|------|---------------|
| Architect | Required | CarPlay scene/data-source design note |
| UX | Light | template hierarchy spec inline |
