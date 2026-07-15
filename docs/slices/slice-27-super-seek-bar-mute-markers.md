# Slice 27 — Super seek bar mute markers

| Field | Value |
|-------|-------|
| **ID** | 27 |
| **Title** | Super seek bar mute markers |
| **Status** | Ready |
| **Crux** | On a complete analysis snapshot with ≥ **1** `.profanity` + `.mute` interval, the full-player super seek bar exposes assertable mute-marker accessibility state (count + normalized positions) distinct from yellow ad buckets — so users can see where language will be cleaned without listening. |

## PRD / spec references

- PRD §2 — profanity handling (mute/skip as playback controls)
- PRD §3 — unrelated-content skip (existing yellow ad ranges stay ad-only)
- `docs/adr/000-foundations.md` — offline / AX verification over device listening
- `docs/adr/018-analysis-timeline.md` — yellow = `.unrelatedContent` only; profanity does not paint yellow today
- `docs/adr/021-progressive-playback-super-seek-bar.md` — `playback.superSeekBar` chrome
- `docs/adr/022-transcript-cache.md` — transcript shows raw words; does **not** highlight profanity (markers live on the bar, not in transcript text)
- `docs/adr/023-super-seek-bar-mute-markers.md` — mute-marker model, complete-only gate, AX suffix

## Goal

Show where profanity mute intervals sit on the super seek bar so cleaning is visually verifiable at a glance.

## Product decisions (intake — pin before Architect)

| Decision | Choice |
|----------|--------|
| What to mark | Cached intervals with `source == .profanity` **and** `action == .mute` only |
| Ads / skip | Unchanged — yellow buckets from `.unrelatedContent` only (ADR-018) |
| Skip-action profanity | **Out of scope** this slice (mute markers only; skip-profanity ticks = follow-up if needed) |
| Progressive / in-flight | Markers only when timeline is **complete** (same gate as yellow today), from applied/cached intervals |
| Visual language | Distinct from green/yellow/blue/grey segment fills — e.g. tick/marker overlays (Architect + UX) |
| Entry | Full-player `playback.superSeekBar` only (mini-player timeline OOS unless free) |

## Deliverables

- [ADR-023](../adr/023-super-seek-bar-mute-markers.md) — mute-marker model on super seek bar (positions, AX contract, complete-only gate); explicit non-change to ADR-018 yellow = ads only
- `SuperSeekBarModel` / view — render markers from mute intervals; AX identifiers/values for count + positions
- UX spec `docs/slices/slice-27-ux.md` — marker appearance, contrast, VoiceOver
- Tests — unit (normalized positions from fixture intervals) + UI (`playback.superSeekBar` / child AX asserts mute marker count)

## Depends on

- Slice 25 (Done) — super seek bar
- Slice 26 (Done) — optional dogfood with transcript; not a hard code dep

**Parallelizable:** Yes vs task-020 / task-019 (different crux); serialize if both touch `SuperSeekBarView.swift`.

## Out-of-scope

- Highlighting matched words inside `TranscriptView` (Slice 26 OOS)
- Changing mute/skip algorithm or ASR model
- CarPlay / lock-screen custom markers
- Mini-player interactive seek bar
- Markers for `.skip` profanity or unrelated mute (if ever)

## Acceptance criteria

Automatable only. **XCTSkip is not allowed on core ACs.**

- [ ] 1. Unit test: duration **120.0** s, one mute interval **[10.0, 11.0)** → marker model exposes count **1** and start/end normalized to duration within **±0.001** (e.g. start **10/120**, end **11/120**).
- [ ] 2. Unit test: two mute intervals → count **2**; zero mute intervals → count **0**; `.unrelatedContent` skip intervals alone → mute marker count **0** (ads do not create mute markers).
- [ ] 3. UI test (fixture with ≥ **1** injected/cached profanity mute interval, cleaning on, complete snapshot): `playback.superSeekBar` (or dedicated child id pinned in UX) `accessibilityValue` includes mute marker count **≥ 1** within **5.0** s of full-player present.
- [ ] 4. UI test (ad-only fixture, yellow present, **0** mute intervals): mute marker count in AX is **0** while ad/yellow semantics from Slice 25 remain intact (segment value still parses; no regression to ready/processing/pending contract beyond documented marker suffix).
- [ ] 5. Full suite green via `scripts/verify.sh` (**exit 0, failed 0, skipped 0**).

## Verification mapping

| AC# | Test file | Test method | Notes |
|-----|-----------|-------------|-------|
| 1 | `PodWash/PodWashTests/SuperSeekBarMuteMarkerTests.swift` | `testSingleMuteMarkerNormalized` | TBD until QA |
| 2 | `PodWash/PodWashTests/SuperSeekBarMuteMarkerTests.swift` | `testMuteMarkerCountIgnoresAds` | TBD until QA |
| 3 | `PodWash/PodWashUITests/SuperSeekBarUITests.swift` | `testMuteMarkersExposedWhenProfanityMutePresent` | TBD until QA |
| 4 | `PodWash/PodWashUITests/SuperSeekBarUITests.swift` | `testMuteMarkersAbsentForAdsOnly` | TBD until QA |
| 5 | — | — | Unfiltered `scripts/verify.sh` |

## Verification commands

```bash
# Fast inner loop (NOT sufficient for Done):
scripts/verify.sh -only-testing:PodWashTests/SuperSeekBarMuteMarkerTests
scripts/verify.sh -only-testing:PodWashUITests/SuperSeekBarUITests

# Done gate — FULL suite, zero failures, zero skips:
scripts/verify.sh
```

## Verification record (QA fills at Verify)

```
VERIFY RESULT: (pending)
```

## Plan review record (coordinator fills before downstream roles)

```
ADR review (2026-07-15): (pending) QA cleared — pipeline worker finished PM cleared — pipeline worker finished
Test spec review: (pending)
```

## Design note (Architect)

Durable decision: [`docs/adr/023-super-seek-bar-mute-markers.md`](../adr/023-super-seek-bar-mute-markers.md).

- Filter: `source == .profanity` && `action == .mute`; normalize start/end by duration (±0.001).
- Complete-only gate (same as yellow); in-flight AX omits `muteMarkers:`.
- Complete colored bar: `ready:N,processing:N,pending:N,muteMarkers:M` (always include `M`, may be 0).
- ADR-018 yellow = ads only — **unchanged**; markers are overlays, not a new segment color.
- Wire applied/cached intervals into full-player `SuperSeekBarView` only.

## Role artifacts

| Role | Required? | Artifact |
|------|-----------|----------|
| PM | **Required** | This story (refine AC if Architect renames AX contract) |
| Architect | **Required** | [ADR-023](../adr/023-super-seek-bar-mute-markers.md) |
| UX | **Required** | `docs/slices/slice-27-ux.md` |
| QA | **Required** | Mapped tests above |
| Engineer | **Required** | App implementation |

## Done gate

- [ ] All AC checked; full suite green; `VERIFY RESULT` recorded
- [ ] Plan reviews recorded
- [ ] Auto-commit on green: `slice-27: super seek bar mute markers`
