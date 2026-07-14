# Slice 26 — Episode transcript viewer

| Field | Value |
|-------|-------|
| **ID** | 26 |
| **Title** | Episode transcript viewer |
| **Status** | Draft |
| **Crux** | After analysis, the on-disk `[TimedWord]` transcript for an episode is readable from a dedicated viewer that marks **listened** words (from `playbackPosition`) and **skipped unrelated** spans (from cached `IntervalSource.unrelatedContent` + `.skip` intervals) — assertable via cache round-trip + UI tests without device listening. |

## PRD / spec references

- PRD §2 — episode preview / library browsing (transcript as text preview of episode content)
- PRD §3 — unrelated-content skip visibility ("skipped ~30s — tap to play"); transcript surfaces what was skipped
- PRD §11 (2026-07-10) — analysis on first play; cache until episode deleted
- `docs/adr/000-foundations.md` §4 — `TimedWord` schema (`word`, `start`, `end`)
- `docs/adr/005-analysis-pipeline.md` — `AnalysisPipeline` + `IntervalCache` (today: intervals only, transcript discarded)
- `docs/adr/013-segmentation-integration.md` — `IntervalSource.unrelatedContent` on `CensorInterval`

## Goal

Let users read the episode transcript when analysis has produced one — to preview an episode, review what they have already heard, and see which ad/superfluous spans were skipped during playback.

## Product decisions (assumed at intake — correct if wrong)

| Decision | Choice (confirmed at intake) |
|----------|-------------------------------|
| Entry points | **Full player** toolbar button `playback.viewTranscript` when transcript exists; **episode row** trailing affordance `episode.viewTranscript` on analyzed episodes (same sheet) |
| When affordance hidden | No **complete** cached transcript on disk — includes in-flight analysis (progressive partial ASR does **not** show affordance until full episode transcribed) |
| Partial transcript (in-flight analysis) | **Complete only** — hide affordance until full `[TimedWord]` array is persisted; no progressive append in this slice |
| "Listened" marking | Words with `end ≤ playbackPosition` (from `ResumePositionStore`) carry accessibility marker `listened` in `accessibilityValue` |
| "Skipped ad" marking | Words whose time range overlaps any cached interval with `source == unrelatedContent` **and** `action == skip` carry marker `skippedAd` (profanity intervals **not** highlighted in transcript text) |
| Profanity in display | Show **raw ASR words** — audio cleaning does not redact transcript text |
| Tap word to seek | **Out of scope** (follow-up) |

## Goal (current vs desired)

**Today:** `AnalysisPipeline` runs ASR → matcher → segmenter → persists **`[CensorInterval]`** via `IntervalCache` only. `[TimedWord]` exists transiently in memory and is **not** stored. No transcript UI or tests (`grep transcript PodWashUITests` → empty).

**Desired:** `TranscriptCache` (or ADR-equivalent) persists `[TimedWord]` keyed by `episodeID` on analysis cache miss (and loads on hit). A `TranscriptView` sheet shows scrollable words with listened + skipped-ad styling. Entry from full player and episode list when a transcript file exists.

## Deliverables

- **ADR-022** — transcript persistence layout, cache key/invalidate rules (episode delete clears transcript; re-analyze overwrites), partial-append contract for Slice 25
- **`TranscriptCache`** — JSON `[TimedWord]` on disk under Application Support (injectable `baseDirectory` for tests)
- **`AnalysisPipeline`** — `store`/`load` transcript alongside interval cache on **full** analysis completion (not per-chunk partial writes)
- **`TranscriptViewModel`** — loads transcript + intervals + `playbackPosition`; computes per-word `listened` / `skippedAd` flags
- **`TranscriptView`** — scrollable transcript sheet; auto-scrolls to `playbackPosition` on open when `playbackPosition > 0`
- **Wiring** — `AppShellModel` / `PlaybackControlsView` / `EpisodeListView` (or table VC) present sheet; launch-arg fixture `-UITestFixtureTranscript`
- **UX spec** `docs/slices/slice-26-ux.md` — layout, highlight colors, a11y ids, scroll-to-position behavior
- **Tests (QA):** `PodWash/PodWashTests/TranscriptCacheTests.swift`, `PodWash/PodWashTests/TranscriptViewModelTests.swift`, `PodWash/PodWashUITests/TranscriptUITests.swift`

## Depends on

- Slice 24 (Done) — production `AnalysisPipeline` on device
- Slice 19 (Done) — `IntervalSource.unrelatedContent` in cached intervals
- Slice 25 — **not required**; complete-transcript-only affordance is independent of progressive playback UI

**Parallelizable:** No — touches shared pipeline cache + player + episode list.

## Out-of-scope

- Transcript for streaming-only episodes with no local analysis run
- In-transcript search, copy/share, speaker diarization, punctuation editing
- Tap word → seek / play from timestamp
- Highlighting profanity matches in transcript text (audio-only cleaning)
- CarPlay / lock-screen transcript
- Server-side or RSS-provided transcripts (ASR-only)
- Progressive / partial transcript display during in-flight analysis (Slice 25 territory — follow-up if desired)

## Acceptance criteria

Automatable only. **XCTSkip is not allowed on core ACs.**

- [ ] 1. Unit test (`TranscriptCacheTests`, fixture `spec-section8.input.json` transcript): `store` then `load` for episode `"fixture-spec-section8"` returns **5** words; deep equality on each `word`/`start`/`end` within **±0.0005 s**.
- [ ] 2. Unit test (`AnalysisPipelineTests` extension, injected transcript, temp cache dirs): after one `analyze` call, `TranscriptCache.load(episodeID:)` is **non-nil** with word count **equal** to injected transcript count; second `analyze` with same episode does **not** invoke ASR spy again and transcript unchanged.
- [ ] 3. Unit test (`TranscriptViewModelTests`, injected transcript **10** words spanning **0–20 s**, `playbackPosition = 12.0`, one unrelated skip interval **14.0–16.0 s**): exactly **words with `end ≤ 12.0`** flagged `listened`; exactly **words overlapping [14, 16]** flagged `skippedAd`; count of both sets **≥ 1** each.
- [ ] 4. UI test (`-UITestFixtureTranscript`, episode with cached transcript **≥ 20** words, `playbackPosition = 30.0` preset): tap `episode.viewTranscript` on row 0 → within **3.0 s**, `transcript.view` exists; `transcript.wordCount` `accessibilityValue` equals injected count; `transcript.listenedCount` `accessibilityValue` is **≥ 1**.
- [ ] 5. UI test (same fixture, unrelated skip span covering **≥ 3** words): `transcript.skippedAdCount` `accessibilityValue` is **≥ 3**.
- [ ] 6. UI test (same fixture, playing episode): expand full player → tap `playback.viewTranscript` → within **3.0 s**, `transcript.view` exists with **same** `transcript.wordCount` as AC4.
- [ ] 7. UI test (fixture with **no** transcript file): `episode.viewTranscript` and `playback.viewTranscript` are **absent** (not hittable).
- [ ] 8. Full suite green via `scripts/verify.sh` (**exit 0, failed 0, skipped 0**).

## Verification mapping

| AC# | Test file | Test method | Notes |
|-----|-----------|-------------|-------|
| 1 | `PodWash/PodWashTests/TranscriptCacheTests.swift` | `testStoreLoadRoundTrip` | TBD until QA test spec |
| 2 | `PodWash/PodWashTests/AnalysisPipelineTests.swift` | `testAnalyzePersistsTranscriptAndReusesCache` | TBD |
| 3 | `PodWash/PodWashTests/TranscriptViewModelTests.swift` | `testListenedAndSkippedAdWordFlags` | TBD |
| 4 | `PodWash/PodWashUITests/TranscriptUITests.swift` | `testEpisodeRowOpensTranscriptWithListenedCount` | TBD |
| 5 | `PodWash/PodWashUITests/TranscriptUITests.swift` | `testTranscriptShowsSkippedAdCount` | TBD |
| 6 | `PodWash/PodWashUITests/TranscriptUITests.swift` | `testFullPlayerOpensSameTranscript` | TBD |
| 7 | `PodWash/PodWashUITests/TranscriptUITests.swift` | `testTranscriptAffordanceHiddenWithoutCache` | TBD |
| 8 | — | full `scripts/verify.sh` | Done gate |

## Verification commands

```bash
# Fast inner loop (NOT sufficient for Done):
scripts/verify.sh -only-testing:PodWashTests/TranscriptCacheTests
scripts/verify.sh -only-testing:PodWashTests/TranscriptViewModelTests
scripts/verify.sh -only-testing:PodWashUITests/TranscriptUITests

# Done gate — FULL suite, zero failures, zero skips:
scripts/verify.sh
```

## Verification record (QA fills at Verify)

```
VERIFY RESULT: (pending)
```

## Plan review record (coordinator fills before downstream roles)

```
ADR review: (pending)
Test spec review: (pending)
```

## Done gate

- [ ] Every AC mapped to a test; all rows in the mapping table filled
- [ ] **Full suite green:** unfiltered `scripts/verify.sh` exit 0, failed 0, skipped 0
- [ ] Verification record pasted above (exit code + counts + `.xcresult` path)
- [ ] Auto-commit made on green: `slice-26: episode transcript viewer` (push only when the user asks)

## Role artifacts

| Role | Gate | Artifact path |
|------|------|---------------|
| Architect | **Required** | `docs/adr/022-transcript-cache.md` |
| UX | **Required** | `docs/slices/slice-26-ux.md` |
| QA | Test spec | `TranscriptCacheTests`, `TranscriptViewModelTests`, `TranscriptUITests` |
| Engineer | Implement | `TranscriptCache`, `TranscriptView`, `TranscriptViewModel`, pipeline + shell wiring |

## Human checklist (post-verify spot-check)

- [ ] Downloaded + analyzed episode: episode row shows transcript affordance; sheet shows readable text.
- [ ] Mid-episode resume: open transcript → scrolled near last listened position; earlier words visually distinct.
- Re-running ASR when opening viewer (read cache only)

- [ ] Episode with skipped ads: skipped span words visually distinct from main content.

## Intake note

Filed via forge-intake 2026-07-14. User confirmed entry points (player + episode row) and **complete-transcript-only** affordance (hidden until full ASR cached).
