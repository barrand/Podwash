# Slice 20 — Analysis timeline visualization (Skipper-style)

| Field | Value |
|-------|-------|
| **ID** | 20 |
| **Title** | Analysis timeline visualization |
| **Status** | Draft |
| **Crux** | While analysis runs on first play with cleaning enabled, the episode row shows a segmented timeline whose colors match processing state — assertable via accessibility and injected pipeline doubles without a physical device. |

## PRD / spec references

- PRD §11 (2026-07-10) — Skipper-inspired timeline deferred from Slice 13
- Slice 09 — `analysisProgress` row indicator (this slice extends/replaces with full timeline)
- Slice 07 — analysis pipeline states

## Goal

Give users visible feedback during first-play analysis: which parts of the episode are processed, ready, ads (future), or not yet scanned — matching the Skipper app pattern the product owner approved.

## Deliverables

- Episode-row (or now-playing) **segmented timeline** view bound to analysis progress
- **Color contract** (accessibility + UI tests):
  - **Blue** — segment currently processing (ASR/match in flight)
  - **Green** — segment analyzed; ready for cleaned playback
  - **Yellow** — ad segment (will be skipped when unrelated-content ships; stub OK at MVP if ads not detected yet)
  - **Grey** — not yet processed
- Injected analysis pipeline double for unit/UI tests (no wall-clock waits)
- `AnalysisTimelineUITests` and/or unit tests on timeline segment model

## Depends on

- Slices 07, 09 (pipeline + existing progress chrome)
- Slice 13 — analysis timing: **first play with cleaning enabled**
- Slice 23 — production episode-list chrome from Library navigation (serialize on shared list UI)

**Parallelizable:** After Slice 23; can run parallel with 15–16 if deps met.

## Out-of-scope

- Settings / word-list persistence (Slice 13)
- Real ad detection (Slice 18–19 track) — yellow segments may use fixture/stub until segmentation exists
- Physical device / Skipper app comparison as a Done gate

## Acceptance criteria

- [ ] 1. Unit test: timeline model maps pipeline progress fractions to segment colors per the blue/green/grey contract on a synthetic duration.
- [ ] 2. UI test (fixture mode): enabling cleaning and playing shows timeline with at least one blue→green transition within bounded time on stubbed fast analysis.
- [ ] 3. UI test: `accessibilityLabel` or `accessibilityValue` on the timeline exposes processing vs ready state for VoiceOver (numeric or enumerated).
- [ ] 4. Full suite green via `scripts/verify.sh`.

## Verification mapping

| AC# | Test file | Test method | Notes |
|-----|-----------|-------------|-------|
| 1 | TBD | TBD | Segment color model |
| 2 | TBD | TBD | Stubbed pipeline |
| 3 | TBD | TBD | a11y |
| 4 | — | — | Full suite |

## Verification commands

```bash
scripts/verify.sh -only-testing:PodWashUITests/AnalysisTimelineUITests
scripts/verify.sh    # Done gate
```

## Verification record (QA fills at Verify)

```
VERIFY RESULT: (pending)
```

## Done gate

- [ ] Every AC mapped to a test
- [ ] Full suite green; verification record pasted
- [ ] Auto-commit on green: `slice-20: <short description>`

## Role artifacts

| Role | Gate | Artifact path |
|------|------|---------------|
| UX | Required | `docs/slices/slice-20-ux.md` (color contract + scenarios) |
| PM | Required | this file |
| QA | Required | timeline tests |
| Engineer | Required | timeline UI + pipeline binding |
