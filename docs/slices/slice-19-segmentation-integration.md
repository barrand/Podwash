# Slice 19 — Unrelated-content integration (Differentiator 2)

| Field | Value |
|-------|-------|
| **ID** | 19 |
| **Title** | Segmentation integration |
| **Status** | Done |
| **Crux** | When unrelated-content handling is **enabled**, Slice 18 segment bounds persist through `AnalysisPipeline` → cache → `PlaybackCoordinator` with an action **independent** of profanity intervals, skip seeks land in **`[end − 0.1 s, end]`**, and `skipOverrideBanner` tap-to-play returns to **`[start ± 0.05 s]`**; when **off by default**, **0** unrelated-content intervals reach the scheduler. |

## Product decisions (user, 2026-07-10 — unblocks this slice)

| Decision | Choice |
|----------|--------|
| Ad / unrelated-content skip at MVP | **Yes** — ship Differentiator 2 at MVP (after Slice 18 spike) |
| Default state | **Off by default**; per-channel + settings toggles |
| Unrelated-content default action | **Skip** (PRD §4 — long spans; mute remains user-selectable) |
| Legal framing | Content curation per PRD §4/§8; attorney review before App Store launch |

## PRD / spec references

- PRD §4 — Skip/mute segments; visible + overridable skips ("skipped ~30 s — tap to play"); off by default
- PRD §6 — Analyze once → interval list (segmentation consumes `[TimedWord]` from Slice 07)
- PRD §8 — Content-curation framing; attorney review before ship
- PRD §11 — ✅ **Resolved 2026-07-10** (see § Product decisions above)
- `docs/adr/012-content-segmentation-approach.md` — `ContentSegmenting` / `HeuristicContentSegmenter` public surface
- `docs/adr/005-analysis-pipeline.md` — transcript injection + cache seam
- `docs/adr/006-playback-integration.md` — `PlaybackCoordinator` / `EpisodeAnalyzing` wiring
- `docs/adr/010-settings-word-lists.md` — `SettingsStore` persistence pattern

## Goal

Wire Slice 18 segmentation into the production analysis → cache → playback path with independent actions, off-by-default toggles, and an overridable skip affordance.

## Deliverables

- **Integration fixtures** (committed, independent provenance):
  - `PodWash/PodWashTests/Fixtures/segmentation/integration_transcript.json` — `[TimedWord]` spanning **≥ 60 s** with **≥ 1** profanity match for target set `{"shit", "damn"}` **and** **≥ 2** unrelated-content spans labelable per `golden_segments.json` bounds (may fork `spike_transcript.json` with a profanity token inserted in an on-topic region; times relabeled in golden if bounds shift)
  - `PodWash/PodWashTests/Fixtures/segmentation/integration_golden.json` — `{ "profanity": [{start, end}], "segments": [{start, end}] }` hand-labeled; provenance note in `segmentation-provenance.md`
  - Reuse Slice 18 `golden_segments.json` for segment bounds when `integration_transcript` preserves the same positive spans (±0.001 s)
- **Pipeline:** inject `ContentSegmenting` (production `HeuristicContentSegmenter`) into `AnalysisPipeline`; merge profanity + segment intervals into cache with per-interval `action` and a discriminant (`IntervalSource` or equivalent — Architect ADR) so profanity and unrelated content can carry **different** actions
- **Settings:** extend `SettingsStore` — `unrelatedContentEnabled` (**default `false`**), `unrelatedContentAction` (**default `.skip`**); accessibility identifier `unrelatedContentToggle` (`accessibilityValue` **`"1"`** / **`"0"`**); `unrelatedContentActionControl` (`"skip"` / `"mute"`)
- **Per-channel toggle:** extend cleaning toggle store / UI — `channelUnrelatedContentToggle` on podcast detail (**default off**, `accessibilityValue` **`"0"`** on fresh install)
- **Playback:** preserve stored per-interval `action` through `PlaybackCoordinator` → `IntervalScheduler` (stop overwriting all intervals with `currentAction`); skip boundary + **override callback** on `PlaybackEngine` (or thin coordinator) to replay from segment `start`
- **Skip-override UI:** transient banner with identifier `skipOverrideBanner`; `accessibilityValue` is rounded skipped seconds as a decimal string (e.g. `"13"` for a 13.4 s skip); tap invokes override callback
- **Launch argument** `-UITestFixtureSkipOverride` — local **10.0 s** sine (or speech) fixture with a **stubbed** unrelated skip interval **`[2.0, 5.0]`**; no network/ASR
- `PodWash/PodWashTests/SegmentationIntegrationTests.swift`, `PodWash/PodWashUITests/SkipOverrideUITests.swift`
- Architect ADR `docs/adr/013-segmentation-integration.md` (pipeline merge, cache key/fingerprint, `IntervalSource`, override seam)
- UX spec `docs/slices/slice-19-ux.md` (override affordance states + UI scenarios)

## Depends on

- Slices 08, 09, 13, 18

**Parallelizable:** No — final integration slice of this track.

## Out-of-scope

- Improving detection quality or retuning `HeuristicContentSegmenter` thresholds (future slices)
- Server-side segmentation or remote interval lists
- Skipper-style analysis timeline colors (Slice 20)
- Beep/quack overlay (Slice 16)
- Perceptual listening or subjective "sounds like an ad" review
- CarPlay / lock-screen surfacing of the override banner (Slice 14/15)
- Attorney-gated **ship** decision (legal review remains pre-launch, not a factory gate)
- Re-benchmarking Slice 18 precision/recall (frozen at ADR-012 artifact)

## Fixture strategy (pinned — Architect / QA)

| Asset | Path | Role |
|-------|------|------|
| Integration transcript | `Fixtures/segmentation/integration_transcript.json` | Injected ASR bypass; ≥1 profanity + ≥2 segment spans |
| Integration golden | `Fixtures/segmentation/integration_golden.json` | Hand-labeled profanity bounds (±0.0005 s asserts) + segment bounds (±0.001 s when aligned with Slice 18 golden) |
| Segment golden (reuse) | `Fixtures/segmentation/golden_segments.json` | **≥ 2** segments, each duration **≥ 5.0 s** |
| Profanity golden (reuse) | `Fixtures/analysis/e2e_intervals.json` | Cross-check when integration transcript embeds spec-section8 profanity tokens |
| Skip UI stub | `-UITestFixtureSkipOverride` | Fixed skip **`[2.0, 5.0]`** on **10.0 s** asset; banner expects **`"3"`** in `accessibilityValue` (±**1** s rounding) |
| Engine unit audio | `Fixtures/audio/sine-300hz-5s.wav` (temp copy) | Slice 04/08 pattern for skip/override engine spy |

**Independence:** `integration_golden.json` profanity bounds are hand-computed from the transcript + matching spec **before** pipeline implementation; segment bounds follow `segmentation-provenance.md`, not segmenter output.

## Acceptance criteria

Automatable only. **XCTSkip is not allowed on core ACs** — mapped tests fail if prerequisites are missing.

- [ ] 1. Integration test: with `unrelatedContentEnabled == true`, injected `integration_transcript.json`, and configured `profanityAction == .mute` / `segmentAction == .skip`, `analyze` returns **≥ 3** intervals total: **exactly 2** unrelated-content intervals whose `start`/`end` each match `integration_golden.json` segment entries within **±0.001 s**, and **≥ 1** profanity interval matching golden profanity bounds within **±0.0005 s**; profanity-tagged intervals assert `action == .mute`, segment-tagged intervals assert `action == .skip`. Second identical `analyze` call: ASR/transcribe spy **0** additional calls (cache hit).
- [ ] 2. Unit test: fresh `SettingsStore` → `unrelatedContentEnabled == false` and `unrelatedContentAction == .skip`. After `preparePlayback` with default settings on `integration_transcript.json`, intervals passed to `applySchedule` include **0** with source unrelated-content (and **≥ 2** such intervals when the same path runs with `unrelatedContentEnabled == true`).
- [ ] 3. Unit test (`PlaybackEngine` or coordinator spy on `sine-300hz-5s.wav`): schedule includes one `.skip` unrelated interval **`[2.0, 5.0]`**; after boundary fires, `currentTime ∈ [4.9, 5.0]` and `timeControlStatus == .playing`; invoking the skip-override callback for that interval yields `currentTime ∈ [1.95, 2.05]` within **2.0 s**, still `.playing`.
- [ ] 4. UI test (`-UITestFixtureSkipOverride`): within **5.0 s** of the stubbed skip event, `skipOverrideBanner` exists and `accessibilityValue` contains **`"3"`** (±**1** s rounding tolerance); **1** tap on `skipOverrideBanner` → within **3.0 s**, player elapsed accessibility or time readout is **≥ 2.0 s** and **≤ 5.0 s** (inside the stubbed segment).
- [ ] 5. Unit test: fresh isolated `UserDefaults` → `unrelatedContentEnabled == false`, `unrelatedContentAction == .skip`. UI test (`-UITestFixtureSettings`): `unrelatedContentToggle` `accessibilityValue == "0"`; on fixture podcast detail, `channelUnrelatedContentToggle` `accessibilityValue == "0"`.
- [ ] 6. Full suite green via `scripts/verify.sh` (**exit 0, failed 0, skipped 0**).

## Verification mapping

| AC# | Test file | Test method | Notes |
|-----|-----------|-------------|-------|
| 1 | `PodWash/PodWashTests/SegmentationIntegrationTests.swift` | `testSegmentsAndProfanityCachedWithIndependentActions` | Injected transcript + dual actions; cache hit on 2nd analyze |
| 2 | `PodWash/PodWashTests/SegmentationIntegrationTests.swift` | `testOffByDefaultExcludesSegmentIntervals` | Default-off vs enabled contrast on same fixture |
| 3 | `PodWash/PodWashTests/SegmentationIntegrationTests.swift` | `testSkipAndOverrideReplay` | Engine spy; Slice 04 skip landing + override seek |
| 4 | `PodWash/PodWashUITests/SkipOverrideUITests.swift` | `testOverrideBannerAppearsAndReplay` | `-UITestFixtureSkipOverride`; stub `[2.0, 5.0]` |
| 5 | `PodWash/PodWashTests/SegmentationIntegrationTests.swift` | `testUnrelatedContentDefaultsOff` | SettingsStore fresh defaults |
| 5 | `PodWash/PodWashUITests/SkipOverrideUITests.swift` | `testChannelToggleDefaultOff` | `-UITestFixtureSettings` or fixture feed |
| 6 | — | — | Command-level: unfiltered `scripts/verify.sh` |

## Verification commands

```bash
# Fast inner loop (NOT sufficient for Done):
scripts/verify.sh -only-testing:PodWashTests/SegmentationIntegrationTests -only-testing:PodWashUITests/SkipOverrideUITests

# Done gate — FULL suite, zero failures, zero skips:
scripts/verify.sh
```

## Verification record (QA fills at Verify)

```
VERIFY RESULT: exit=0 total=77 passed=77 failed=0 skipped=0 filtered=0 bundle=build/test-results/verify-20260710-215615.xcresult tier=3 class=tests
```

## Plan review record (coordinator fills before downstream roles)

```
ADR review (2026-07-10): (pending) QA cleared — pipeline worker finished PM cleared — pipeline worker finished
Test spec review (2026-07-10): Architect cleared — pipeline worker finished
```

## Done gate

- [ ] Every AC mapped to a test; all rows filled
- [ ] **Full suite green:** unfiltered `scripts/verify.sh` exit 0, failed 0, skipped 0
- [ ] Verification record pasted above (exit code + counts + `.xcresult` path)
- [ ] Auto-commit on green: `slice-19: <short description>`

## Design note (Architect)

Durable decisions: [`docs/adr/013-segmentation-integration.md`](../adr/013-segmentation-integration.md).

| Concern | Pin |
|---------|-----|
| Discriminant | `IntervalSource` on `CensorInterval` (`.profanity` / `.unrelatedContent`) |
| Pipeline | Always segment on cache miss; cache full union; filter unrelated on return when disabled |
| Cache key | `(episodeID, targetWords)` + internal `interval-format:v2` token — **not** enablement/actions |
| Playback | Remap actions **by source**; stop ADR-006 blanket `currentAction` overwrite |
| Effective enable | `settings.unrelatedContentEnabled && channelUnrelatedContentEnabled` |
| Override | Engine callback + seek to `start ± 0.05` + skip suppression until past `end` |

## Role artifacts

| Role | Gate | Artifact path |
|------|------|---------------|
| Architect | Required | `docs/adr/013-segmentation-integration.md` |
| UX | Required | `docs/slices/slice-19-ux.md` (override affordance) |
