---
name: Slice 10 attended
overview: Finish Slice 10 attended in Cursor with simple prompting, then use that experience to diagnose why the factory thrash failed on the same work.
todos:
  - id: slice-10-attended
    content: Finish Slice 10 attended (simple Cursor prompts; filtered then full verify.sh)
    status: completed
  - id: diagnose-factory
    content: After green (or clear blockers), write down why slice-loop failed on the same slice
    status: completed
isProject: true
---

# Slice 10 attended, then diagnose the factory

**For the next agent:** execute Step 1 only unless the user also asks for Step 2. Do **not** run `scripts/slice-loop.sh`. Do **not** start OpenHands or factory rewrites.

## Goal

1. **Get Slice 10 green** with a normal attended Cursor session (no `slice-loop`).
2. **Explain the factory failure** using what that session taught you—not more orchestrator patches yet.

## Step 1 — Attended Slice 10

Primary slice file: [`docs/slices/slice-10-downloads.md`](../slices/slice-10-downloads.md)  
ADR: [`docs/adr/008-episode-downloads.md`](../adr/008-episode-downloads.md)  
UX (if needed): [`docs/slices/slice-10-downloads-ux.md`](../slices/slice-10-downloads-ux.md)

- Work the slice like a normal agent session: slice file + ADR-008 + existing tests.
- Known failure themes from the last factory run (starting clues, not gospel):
  - `DownloadManagerTests/testCancelRemovesPartialAndRetainsResumeData` — resume data nil / cancel timing
  - `DownloadUITests/testDownloadAndDeleteButtonFlow` — download never reaches `downloaded`
  - Possible collateral: AnalysisProgress / PlaybackControls UITests after `EpisodeListView` changes
- Inner loop:

```bash
scripts/verify.sh -only-testing:PodWashTests/DownloadManagerTests -only-testing:PodWashUITests/DownloadUITests
```

- Done for Step 1: full suite green:

```bash
scripts/verify.sh
```

- Respect PodWash role rules: app code via engineer path; tests via QA if tests (not app) are wrong. Coordinator must not author `PodWash/PodWash/**` or test targets directly if operating as coordinator—prefer spawning `podwash-engineer` / `podwash-qa`.
- Do **not** weaken or delete AC-mapped assertions.
- Do **not** start `slice-loop`.

## Step 2 — Diagnose factory failure

After Step 1 (green or stuck for a clear reason), answer briefly in a short note (chat is fine; optional file under `docs/plans/`):

- What was the real bug vs what the stuck card / playbook claimed (`ui_race` / lengthen analyzing window)?
- Where did the loop waste time (hidden Engineer grind, wrong lever, bridge, mixed full-suite failures)?
- What would have made the factory succeed—or is this task a bad unattended fit?

No OpenHands, no slice-loop rewrites, no new harness—until that writeup exists.

## Step 2 — Factory tripwire (attended session)

What actually tripped the factory vs what was fixed attended:

- **Cancel/resume:** Need flush wait + ETag/Last-Modified for real `URLSession` resume data; stub lacked validators so system resume data was nil.
- **UI download:** Accessory button hit target too small — XCTest tap did not fire `touchUpInside`.
- **Collateral:** Download refresh on every analysis update raced away the `analysisProgress` AX surface (`AnalysisProgressUITests`).

Stuck-card / playbook themes (`ui_race`, lengthen analyzing window) were not the root causes for the download ACs.
