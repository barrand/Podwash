# Slice 26 — Episode transcript viewer

| Field | Value |
|-------|-------|
| **ID** | 26 |
| **Title** | Episode transcript viewer |
| **Status** | Ready |
| **Crux** | Terminal analysis persists `[TimedWord]` to disk and a transcript sheet exposes **listened** words (`end ≤ playbackPosition`) and **skipped-ad** words (overlap `IntervalSource.unrelatedContent` + `.skip`) — assertable via cache round-trip, view-model counts, and UI accessibility aggregates without device listening. |

## PRD / spec references

- PRD §2 — episode preview / library browsing (transcript as text preview of episode content)
- PRD §3 — unrelated-content skip visibility ("skipped ~30s — tap to play"); transcript surfaces what was skipped
- PRD §11 (2026-07-10) — analysis on first play; cache until episode deleted
- `docs/adr/000-foundations.md` §4 — `TimedWord` schema (`word`, `start`, `end`)
- `docs/adr/005-analysis-pipeline.md` — `AnalysisPipeline` + `IntervalCache` (today: intervals only, transcript discarded)
- `docs/adr/013-segmentation-integration.md` — `IntervalSource.unrelatedContent` on `CensorInterval`
- `docs/adr/021-progressive-playback-super-seek-bar.md` §Consequences — terminal-only transcript store; partial ASR must not unlock viewer affordance

## Goal

Let users read the episode transcript when analysis has produced one — to preview an episode, review what they have already heard, and see which ad/superfluous spans were skipped during playback.

## Product decisions (resolved at intake — do not re-litigate)

| Decision | Choice |
|----------|--------|
| Entry points | **Full player** toolbar button `playback.viewTranscript` when transcript exists; **episode row** trailing affordance `episode.viewTranscript` on analyzed episodes (same sheet) |
| When affordance hidden | No **complete** cached transcript on disk — includes in-flight progressive analysis (partial ASR does **not** show affordance until full episode transcribed and persisted) |
| Partial transcript (in-flight analysis) | **Complete only** — hide affordance until full `[TimedWord]` array is persisted; no progressive append in this slice |
| "Listened" marking | Words with `end ≤ playbackPosition` (from `ResumePositionStore` / `CDEpisode.playbackPosition`) carry per-word `accessibilityValue` suffix or aggregate `transcript.listenedCount` |
| "Skipped ad" marking | Words whose time range overlaps any cached interval with `source == unrelatedContent` **and** `action == skip` (`word.start < interval.end && word.end > interval.start`); profanity intervals **not** highlighted |
| Profanity in display | Show **raw ASR words** — audio cleaning does not redact transcript text |
| Tap word → seek | **Out of scope** (follow-up) |
| Cache key | `episodeID` only (ASR output independent of word-list fingerprint); episode delete removes transcript file; full re-analyze overwrites on terminal completion |

## Background (current vs desired)

**Today:** `AnalysisPipeline` runs ASR → matcher → segmenter → persists **`[CensorInterval]`** via `IntervalCache` only. `[TimedWord]` exists transiently in memory and is **not** stored. No transcript UI or tests (`grep -i transcript PodWashUITests` → empty).

**Desired:** `TranscriptCache` (or ADR-equivalent) persists `[TimedWord]` keyed by `episodeID` on **terminal** analysis completion (not per-chunk). A `TranscriptView` sheet shows scrollable words with listened + skipped-ad styling, auto-scrolls near `playbackPosition` on open, and is reachable from the episode row and full player when a transcript file exists.

## Deliverables

- **ADR-022** — transcript persistence layout, `episodeID` key, invalidate rules (episode delete clears transcript; terminal re-analyze overwrites); **explicit terminal-only write** (no partial-append — aligned with ADR-021 §Slice 26)
- **`TranscriptCache`** — JSON `[TimedWord]` on disk under Application Support (injectable `baseDirectory` for tests); `remove(episodeID:)` for delete invalidation
- **`AnalysisPipeline`** — `store` transcript on terminal analysis completion alongside interval cache; skip transcript write on interval cache hit
- **`TranscriptViewModel`** — loads transcript + intervals + `playbackPosition`; computes per-word `listened` / `skippedAd` flags
- **`TranscriptView`** — scrollable transcript sheet; auto-scrolls to `playbackPosition` on open when `playbackPosition > 0`; aggregate + per-word accessibility identifiers per UX spec
- **Wiring** — `AppShellModel` / `PlaybackControlsView` / `EpisodeListView` present sheet; launch-arg fixture `-UITestFixtureTranscript`
- **UX spec** `docs/slices/slice-26-ux.md` — layout, highlight colors, a11y ids (`transcript.view`, `transcript.wordCount`, `transcript.listenedCount`, `transcript.skippedAdCount`, `transcript.scrollAnchor`, `transcript.word_<index>`), scroll-to-position behavior
- **Tests (QA):** `PodWash/PodWashTests/TranscriptCacheTests.swift`, `PodWash/PodWashTests/TranscriptViewModelTests.swift`, `PodWash/PodWashTests/AnalysisPipelineTests.swift` (extension), `PodWash/PodWashUITests/TranscriptUITests.swift`

## Fixture strategy (pinned — PM / QA)

| Asset | Value | Role |
|-------|-------|------|
| Fast cache round-trip | `Fixtures/transcripts/spec-section8.input.json` | **5** words; episode `"fixture-spec-section8"`; ±**0.0005** s (Slice 07 provenance) |
| ViewModel synthetic transcript | **10** words, **2.0** s each, span **0.0–20.0** s (`word[i]` = `[2i, 2i+2)`) | AC3: `playbackPosition = 12.0` → **6** listened (`end ≤ 12.0`); unrelated skip **12.0–18.0** s → **3** skippedAd (words **12–14**, **14–16**, **16–18** overlap) |
| UI fixture transcript | **24** words, **2.5** s each, span **0.0–60.0** s | AC4–AC6: `transcript.wordCount == 24`; preset `playbackPosition = 30.0` → **12** listened; unrelated skip **35.0–42.5** s → **3** skippedAd words |
| UI fixture launch arg | `-UITestFixtureTranscript` | Seeds cached transcript + intervals + preset resume position; implies Library/feed path per ADR-022 |
| No-transcript control | Same fixture family with transcript file omitted | AC7 affordance absent |
| Progressive negative | `-UITestFixtureProgressivePlayback` (Slice 25) | AC9: while `playback.superSeekBar` is `ready:3,processing:1,pending:8`, transcript affordance absent |
| Overlap rule | `word.start < interval.end && word.end > interval.start` | ViewModel + UI skippedAd counts |

## Depends on

- Slice 24 (Done) — production `AnalysisPipeline` on device
- Slice 19 (Done) — `IntervalSource.unrelatedContent` in cached intervals
- Slice 23 (Done) — `EpisodeListView` / full-player chrome entry points
- Slice 11 (Done) — `ResumePositionStore` / `CDEpisode.playbackPosition` for listened marking
- Slice 25 (Done) — progressive analysis; AC9 asserts terminal-only affordance during in-flight analysis

**Parallelizable:** No — touches shared pipeline cache + player + episode list.

## Out-of-scope

- Transcript for streaming-only episodes with no local analysis run
- In-transcript search, copy/share, speaker diarization, punctuation editing
- Tap word → seek / play from timestamp
- Highlighting profanity matches in transcript text (audio-only cleaning)
- CarPlay / lock-screen transcript
- Server-side or RSS-provided transcripts (ASR-only)
- Progressive / partial transcript display or persistence during in-flight analysis (ADR-021 defers; follow-up slice if desired)
- Mini-player transcript entry (full player + episode row only)

## Acceptance criteria

Automatable only. **XCTSkip is not allowed on core ACs** — a mapped test that cannot run must fail.

- [ ] 1. Unit test (`TranscriptCacheTests`, `spec-section8.input.json`): `store` then `load` for episode `"fixture-spec-section8"` returns **5** words; each `word`/`start`/`end` equals fixture within **±0.0005** s.
- [ ] 2. Unit test (`AnalysisPipelineTests` extension, injected transcript count **5**, temp cache dirs): after one `analyze` call, `TranscriptCache.load(episodeID:)` is **non-nil** with word count **5**; second `analyze` with same episode: ASR spy records **0** additional `transcribe` calls and loaded transcript is **byte-identical** (or `Equatable`) to the first.
- [ ] 3. Unit test (`TranscriptViewModelTests`, synthetic **10**-word fixture per table, `playbackPosition = 12.0`, unrelated skip **12.0–18.0** s): `listenedCount == 6`; `skippedAdCount == 3`; no word flagged both listened and skippedAd.
- [ ] 4. UI test (`-UITestFixtureTranscript`, preset `playbackPosition = 30.0`): tap `episode.viewTranscript` on row 0 → within **3.0** s, `transcript.view` exists; `transcript.wordCount` `accessibilityValue` is **`24`**; `transcript.listenedCount` is **`12`**.
- [ ] 5. UI test (same fixture): `transcript.skippedAdCount` `accessibilityValue` is **`3`**.
- [ ] 6. UI test (same fixture, playing episode): expand full player → tap `playback.viewTranscript` → within **3.0** s, `transcript.view` exists; `transcript.wordCount` is **`24`** (same as AC4).
- [ ] 7. UI test (fixture with **no** transcript file on disk): `episode.viewTranscript` and `playback.viewTranscript` are **absent** (not hittable) on row 0 and in expanded full player.
- [ ] 8. UI test (same fixture as AC4, `playbackPosition = 30.0`): on first open, `transcript.scrollAnchor` `accessibilityValue` parsed as `Int` is **≥ 28** and **≤ 32**.
- [ ] 9. UI test (`-UITestFixtureProgressivePlayback`, cleaning on): tap play → within **5.0** s, `playback.superSeekBar` `accessibilityValue` is **`ready:3,processing:1,pending:8`** while `episode.viewTranscript` is **absent** (terminal transcript not yet persisted).
- [ ] 10. Unit test (`TranscriptCacheTests`): after `store` for episode `"fixture-delete"`, `remove(episodeID:)` then `load` returns **nil**.
- [ ] 11. Full suite green via `scripts/verify.sh` (**exit 0, failed 0, skipped 0**).

## Verification mapping

| AC# | Test file | Test method | Notes |
|-----|-----------|-------------|-------|
| 1 | `PodWash/PodWashTests/TranscriptCacheTests.swift` | `testStoreLoadRoundTrip` | §8 fixture; 5 words; ±0.0005 s |
| 2 | `PodWash/PodWashTests/AnalysisPipelineTests.swift` | `testAnalyzePersistsTranscriptAndReusesCache` | ASR spy 0 on 2nd call; count 5 |
| 3 | `PodWash/PodWashTests/TranscriptViewModelTests.swift` | `testListenedAndSkippedAdWordFlags` | listened 6; skippedAd 3; mutual exclusion |
| 4 | `PodWash/PodWashUITests/TranscriptUITests.swift` | `testEpisodeRowOpensTranscriptWithCounts` | wordCount 24; listenedCount 12 |
| 5 | `PodWash/PodWashUITests/TranscriptUITests.swift` | `testTranscriptShowsSkippedAdCount` | skippedAdCount 3 |
| 6 | `PodWash/PodWashUITests/TranscriptUITests.swift` | `testFullPlayerOpensSameTranscript` | wordCount 24 |
| 7 | `PodWash/PodWashUITests/TranscriptUITests.swift` | `testTranscriptAffordanceHiddenWithoutCache` | not hittable |
| 8 | `PodWash/PodWashUITests/TranscriptUITests.swift` | `testTranscriptScrollsNearPlaybackPosition` | scrollAnchor Int 28–32 |
| 9 | `PodWash/PodWashUITests/TranscriptUITests.swift` | `testTranscriptHiddenDuringProgressiveAnalysis` | reuses Slice 25 fixture |
| 10 | `PodWash/PodWashTests/TranscriptCacheTests.swift` | `testRemoveClearsTranscript` | load nil after remove |
| 11 | — | — | Command-level: unfiltered `scripts/verify.sh` exit 0, failed 0, skipped 0 |

## Verification commands

```bash
# Fast inner loop (NOT sufficient for Done):
scripts/verify.sh -only-testing:PodWashTests/TranscriptCacheTests
scripts/verify.sh -only-testing:PodWashTests/TranscriptViewModelTests
scripts/verify.sh -only-testing:PodWashTests/AnalysisPipelineTests
scripts/verify.sh -only-testing:PodWashUITests/TranscriptUITests

# AC9 cross-fixture spot (still run full TranscriptUITests before Done):
scripts/verify.sh -only-testing:PodWashUITests/TranscriptUITests/testTranscriptHiddenDuringProgressiveAnalysis

# Done gate — FULL suite, zero failures, zero skips:
scripts/verify.sh
```

## Verification record (QA fills at Verify)

```
VERIFY RESULT: exit=0 total=189 passed=189 failed=0 skipped=0 filtered=0 bundle=build/test-results/verify-20260715-103521.xcresult tier=3 class=tests
```

## Plan review record (coordinator fills before downstream roles)

```
ADR review (2026-07-15): (pending — artifact authored: docs/adr/022-transcript-cache.md) QA cleared — pipeline worker finished PM cleared — pipeline worker finished
Test spec review (2026-07-15): Architect cleared — pipeline worker finished
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
| QA | Test spec | `TranscriptCacheTests`, `TranscriptViewModelTests`, `AnalysisPipelineTests` extension, `TranscriptUITests` |
| Engineer | Implement | `TranscriptCache`, `TranscriptView`, `TranscriptViewModel`, pipeline + shell wiring |

## Human checklist (optional post-verify spot-check — not a Done gate)

- [ ] Downloaded + analyzed episode: episode row shows transcript affordance; sheet shows readable text.
- [ ] Mid-episode resume: open transcript → scrolled near last listened position; earlier words visually distinct.
- [ ] Episode with skipped ads: skipped span words visually distinct from main content.
- [ ] Opening viewer does not re-run ASR (reads cache only).

## Intake note

Filed via forge-intake 2026-07-14. User confirmed entry points (player + episode row) and **complete-transcript-only** affordance (hidden until full ASR cached). Slice 25 Done — AC9 pins progressive in-flight negative case per ADR-021.
