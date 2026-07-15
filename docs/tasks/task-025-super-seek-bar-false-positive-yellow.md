# Task 025 — Super seek bar yellow false positives (segmenter)

| Field | Value |
|-------|-------|
| **ID** | 025 |
| **Title** | Super seek bar yellow bands do not match real ads (segmenter false positives) |
| **Status** | Queued |
| **Kind** | fix |
| **Priority** | P1 |
| **Area** | `PodWash/PodWash/HeuristicContentSegmenter.swift`, `PodWash/PodWash/AnalysisTimelineModel.swift`, `PodWash/PodWashTests/Fixtures/segmentation/`, `PodWash/PodWashTests/SegmentationSpikeTests.swift`, `PodWash/PodWashTests/AnalysisTimelineModelTests.swift` |
| **Crux** | With Clean Profanity + Skip ads on and analysis complete, yellow on `playback.superSeekBar` comes only from `HeuristicContentSegmenter` spans that match hand-golden ad labels on a fixture — a host-content opening **without** sponsor openers must produce **0** unrelated segments overlapping that opening, and a fixture with exactly **three** labeled ad clusters must yellow **only** the buckets that overlap those clusters. |

## Outcome

**Observed (device, 2026-07-15, post task-022 build):** TAL **891** (~**71:59**). Clean Profanity **on**, Skip ads **on**. Full-player `playback.superSeekBar` shows about **three** yellow bands that feel **random** relative to the show (not a literal green↔yellow paint swap). Screenshot: playhead at **2:12** still inside a **long opening yellow** band; alternating yellow/green through the episode; red mute markers present. User reports yellow where host content is heard.

**Expected:** Yellow = skippable `.unrelatedContent` only (ADR-018). Opening host content with no real intro-ad span must read **green** (modulo 12-bucket coarseness on a *short* true intro). Mid/end yellow only where real ads / golden labels sit — not three arbitrary bands.

**Framing:** If a TimedWord fixture with (a) a dense but non-sponsor opening and (b) exactly three hand-labeled sponsor clusters proves segmenter output IoU-matches those labels (no opening false positive) and `segmentColors` yellow set equals only buckets overlapping those three ranges, we never need to re-dogfood TAL 891 to trust the bar colors.

**Standing dogfood (until revoked):** TAL **891**; Clean Profanity + Skip ads always on.

**Why not reopen 019 / 022:** Those tasks **Done** with paint↔applied-skip wiring green on injected intervals. Their out-of-scope explicitly escalated **live segmenter precision** when device still showed multi-minute early yellow. This ticket is that escalation.

## Debug notes (intake)

| Observation | Proves | Does not prove |
|-------------|--------|----------------|
| ~3 yellow bands, “kinda random” | Segmenter (or paint of its output) places unrelated spans in ≥3 clusters | Literal `systemGreen`/`systemYellow` swap in `SuperSeekBarView` |
| Playhead **2:12** in opening yellow on ~72 min bar | Opening yellow covers ≥ ~132 s (often whole first ~360 s bucket) | Whether applied `adRanges` are multi-minute vs short intro + coarseness |
| 019/022 wiring ACs green | Paint follows whatever intervals the segmenter/projection emit | That those intervals are true ads |
| Code smell | `HeuristicContentSegmenter` appends **density windows** when `start < 180` even without anchors (`nearOpenClose`) — plausible opening FP | Device dump of live `adRanges` without Console capture |

**Ranked hypotheses**

1. **H1 — Opening density false positive** (`nearOpenClose` / URL-density path) marks early host content as unrelated → long opening yellow while hearing show.
2. **H2 — Mid/end over-flag** — same density/grow path creates extra pods that are not sponsor reads → “random” yellow bands.
3. **H3 — Coarse buckets only** — short true ads paint whole ~6 min buckets (explains some mismatch, **not** three arbitrary mid-episode yellows if golden has fewer ads).

## Acceptance criteria

- [ ] 1. Unit (`HeuristicContentSegmenter`): TimedWord fixture for an opening stretch **≥ 180.0 s** of host-style speech with **no** sponsor-opener phrases from the production anchor list, optionally including URL-/promo-like density tokens that today trip the density path → segmenter returns **0** `ContentSegment` overlapping **`[0.0, 180.0)`**.
- [ ] 2. Unit (`HeuristicContentSegmenter`): TimedWord fixture with **exactly three** hand-labeled sponsor clusters (independent provenance in fixture README), each with a real opener phrase → segmenter returns **exactly 3** segments; each matches its golden range at temporal IoU **≥ 0.5**; **0** unmatched predicted segments (precision **1.0** on this fixture at IoU 0.5).
- [ ] 3. Unit (`AnalysisTimelineModel` / wiring): duration **4319.0 s** (≈71:59), complete snapshot whose `adRanges` are exactly the three golden clusters from AC2 → yellow buckets equal **only** buckets that overlap those ranges; count of yellow-contiguous runs is **≤ 3** (adjacent yellow buckets from one cluster count as one run); bucket **0** is green unless a golden cluster overlaps it.
- [ ] 4. Existing Slice 18 spike golden still meets committed precision/recall floors (no regression on `spike_transcript.json` / ADR-012 thresholds).
- [ ] 5. Human checklist (non-blocking for factory Done): re-dogfood TAL 891; if opening still multi-minute yellow while hearing content after AC1–4 green, capture Console/cached unrelated interval dump and Halt — do not weaken AC1–4.

## Surgical test scope

| AC# | Test id | New? |
|-----|---------|------|
| 1 | `PodWashTests/SegmentationSpikeTests/testOpeningWithoutSponsorAnchorProducesNoEarlySegment()` | yes |
| 2 | `PodWashTests/SegmentationSpikeTests/testThreeSponsorClustersMatchGoldenIoU()` | yes |
| 3 | `PodWashTests/AnalysisTimelineModelTests/testYellowOnlyOnThreeGoldenAdClusters()` | yes |
| 4 | Existing spike / benchmark recompute path (`SegmentationSpikeTests` or committed artifact assert) | no (must stay green) |

## Authorized test changes

- (none) — bug fix; new fixtures/tests only. Do not weaken Slice 18/19 IoU floors or task-019/022 paint↔skip asserts.

## Depends on

- None

## Out of scope

- Reopening or weakening task-019 / task-022 wiring tests (paint already follows applied intervals).
- Changing ADR-018 green/yellow **semantics** or `SuperSeekBarView` `systemGreen`/`systemYellow` mapping (not inverted in code).
- Changing the **12-bucket** equal-width / any-overlap→yellow contract (file a **tweak** if product wants finer ad paint).
- Mute markers (red ticks / slice-27); mini-player-only chrome; CarPlay.
- Live Whisper / full-episode TAL ASR as factory Done (human checklist + Halt if AC1–4 green and device dump still shows large false-positive `adRanges`).

## Human checklist

- [ ] iPhone: TAL **891** downloaded; Clean Profanity on; Skip ads on; analysis complete; fresh build after this fix.
- [ ] Full player: count yellow bands; play from **0:00** — note whether opening yellow is gone or only short-intro coarseness.
- [ ] At ~**2:12**, if still in yellow while hearing host content: Console / interval-cache dump of `.unrelatedContent` ranges; Halt if AC1–4 already green.

## Verification record

> Loop writes `VERIFY RESULT:` here. For tasks, `tier=2` and `filtered=1` are valid for Done.

```
VERIFY RESULT: (pending)
```
