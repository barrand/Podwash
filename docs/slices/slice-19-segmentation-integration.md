# Slice 19 — Unrelated-content integration (Differentiator 2)

| Field | Value |
|-------|-------|
| **ID** | 19 |
| **Title** | Segmentation integration |
| **Status** | Draft |
| **Crux** | Segment intervals from the Slice 18 approach flow through the existing pipeline (cache → scheduler → playback) with the skip-override affordance, off by default. |

## Product decisions (user, 2026-07-10 — unblocks this slice)

| Decision | Choice |
|----------|--------|
| Ad / unrelated-content skip at MVP | **Yes** — ship Differentiator 2 at MVP (after Slice 18 spike) |
| Default state | **Off by default**; per-channel + settings toggles |
| Legal framing | Content curation per PRD §4/§8; attorney review before App Store launch |

## PRD / spec references

- PRD §4 — Skip/mute segments; visible + overridable skips ("skipped ~30 s — tap to play"); off by default
- PRD §8 — Content-curation framing; attorney review before ship
- PRD §11 — ✅ **Resolved 2026-07-10** (see § Product decisions above)

## Goal

Differentiator 2 becomes a product feature on the pipeline built for Differentiator 1.

## Deliverables

- Segmenter (Slice 18 recommendation) added to `AnalysisPipeline`; segment intervals tagged with their own action (default: skip)
- Skip-override UI: transient "skipped ~Ns — tap to play" affordance (identifier `skipOverrideBanner`)
- Feature toggle **off by default**, in settings + per-channel
- `SegmentationIntegrationTests`, `SkipOverrideUITests`

## Depends on

- Slices 08, 09, 13, 18

**Parallelizable:** No — final integration slice of this track.

## Out-of-scope

- Improving detection quality (iterate in future slices)
- Server-side anything

## Acceptance criteria

- [ ] 1. Integration test: fixture transcript with golden segment labels → pipeline caches segment intervals alongside profanity intervals, actions independently configurable.
- [ ] 2. Unit test: with the feature **off** (default), no segment intervals reach the scheduler.
- [ ] 3. Unit test: skip action seeks past a segment; the override callback replays it from segment start (engine spy).
- [ ] 4. UI test (stubbed intervals): `skipOverrideBanner` appears within the skip event and tapping it resumes inside the segment.
- [ ] 5. Full suite green via `scripts/verify.sh`.

## Verification mapping

| AC# | Test file | Test method | Notes |
|-----|-----------|-------------|-------|
| 1 | `PodWash/PodWashTests/SegmentationIntegrationTests.swift` | `testSegmentsFlowThroughPipeline` | TBD |
| 2 | `PodWash/PodWashTests/SegmentationIntegrationTests.swift` | `testOffByDefault` | TBD |
| 3 | `PodWash/PodWashTests/SegmentationIntegrationTests.swift` | `testSkipAndOverride` | TBD |
| 4 | `PodWash/PodWashUITests/SkipOverrideUITests.swift` | `testOverrideBanner` | Stubbed |
| 5 | — | — | Command-level |

## Verification commands

```bash
scripts/verify.sh -only-testing:PodWashTests/SegmentationIntegrationTests -only-testing:PodWashUITests/SkipOverrideUITests
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
- [ ] Auto-commit on green: `slice-19: <short description>`

## Role artifacts

| Role | Gate | Artifact path |
|------|------|---------------|
| Architect | Required | pipeline-extension design note |
| UX | Required | `docs/slices/slice-19-ux.md` (override affordance) |
