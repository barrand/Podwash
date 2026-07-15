# Task 022 — Intro ad plays; seek bar yellow ≠ transcript ads

| Field | Value |
|-------|-------|
| **ID** | 022 |
| **Title** | Intro ad still plays; seek-bar yellow does not match transcript ad spans |
| **Status** | Done |
| **Done at** | 2026-07-15T18:45:59Z |
| **Kind** | fix |
| **Priority** | P1 |
| **Area** | `PodWash/PodWash/PlaybackEngine.swift`, `PodWash/PodWash/PlaybackCoordinator.swift`, `PodWash/PodWash/AppShellModel.swift`, `PodWash/PodWash/AnalysisPipeline.swift`, `PodWash/PodWash/TranscriptViewModel.swift`, `PodWash/PodWashTests/ProgressivePlaybackTests.swift`, `PodWash/PodWashTests/ProductionAnalysisWiringTests.swift` |
| **Crux** | With Clean Profanity + Skip ads on (dogfood defaults), analysis complete, and an intro `.unrelatedContent` `.skip` that the transcript marks `skippedAd`, that span must be skipped on `PlaybackEngine` and yellow on `playback.superSeekBar` must come only from the same applied skip set — not play the intro under a long yellow opening that does not match those words. |

## Outcome

**Observed (device, 2026-07-15, fresh build):** This American Life **891** (~**72:05**). Clean Profanity **on**, Skip ads **on** (standing dogfood — do not re-ask). Full-player `playback.superSeekBar` shows a long **yellow** opening (playhead at **2:07** still inside that yellow band), plus mid and end yellow — colors feel unrelated to real ads. **View transcript** correctly yellows only the **intro ad** for the **first few seconds**. That intro ad **still played** (was not skipped).

**Expected:** Intro unrelated skip fires (seek to interval end) so the ad is not heard. Yellow buckets on the completed bar are exactly the buckets that overlap **applied** `.unrelatedContent` skip intervals (same set the transcript uses for `skippedAd`). Host content after a short intro must not require the user to believe the first ~6–12 minutes are all ads unless applied intervals actually cover that span.

**Framing:** If a progressive fixture with intro skip **`[0.0, 8.0)`** proves (a) skip/catch-up lands playhead at the interval end before/at first audible play-through, (b) seek-bar yellow equals buckets overlapping that skip, and (c) `TranscriptViewModel` `skippedAd` words are exactly the words overlapping that same applied skip — we never need to re-listen TAL 891 for “transcript knew the intro ad, but audio + bar disagreed.”

**Standing dogfood (until revoked):** All device checks use **TAL 891**; Clean Profanity + Skip ads (global + channel) treated as **always on**.

**Related:** Done [task-019](task-019-super-seek-bar-yellow-vs-content.md) locked mid-episode paint↔skip with unit wiring; this ticket covers the **intro + progressive** miss and transcript↔schedule alignment that 019’s human checklist still fails on device.

## Debug notes (intake)

| Observation | Proves | Does not prove |
|-------------|--------|----------------|
| Transcript yellow only first few seconds | Interval set used for `skippedAd` overlaps a **short** intro span | That `PlaybackEngine` applied that skip |
| Intro ad still heard | Skip boundary/catch-up did not remove that audio | Detector false negative |
| Playhead **2:07** still in opening yellow on **72:05** bar | Opening yellow covers ≥ ~127 s (often whole first **~360 s** bucket = 72:05/12) | That applied `adRanges` span 10+ minutes vs 12-bucket coarseness |
| Mid + end yellow | Some applied/union unrelated overlaps those buckets | Those spans are true ads without Console dump |

**Ranked hypotheses**

1. **H1 — Progressive race:** `onChunkReady` starts play before an intro `.unrelatedContent` skip is on the schedule; playhead exits `[0, T)` before `catchUpSkipIfInsideInterval` / boundary can fire → ad heard; terminal paint may still yellow the opening bucket(s).
2. **H2 — Source split:** Transcript `skippedAd` from `IntervalCache` / cached union vs seek-bar `adRangePaintIntervals(playbackIntervals:)` / engine schedule disagree on the intro span.
3. **H3 — Coarse buckets only:** Short intro correctly paints bucket 0 yellow (~6 min) while 2:07 is post-ad content inside that bucket — explains “yellow while hearing show” but **not** “ad still played.” Fix skip first; file a **tweak** if product wants sub-bucket ad paint.

## Acceptance criteria

- [ ] 1. Progressive / wiring: Clean Profanity on, Skip ads on, local-file fixture with a single unrelated skip **`[0.0, 8.0)`** and duration **≥ 60.0 s**. Play is allowed to start **before** the terminal schedule is applied, but while the playhead is still inside the intro (or play must not start until that skip is scheduled). After schedule apply: `currentTime` is in **`[8.0 − 0.1, 8.0]`** (skip-seek contract) and an unrelated-content skip callback/observer for that interval has fired — intro audio is not left playing through.
- [ ] 2. Same fixture after terminal snapshot: `playback.superSeekBar` / `segmentColors` yellow set equals buckets overlapping **`[0.0, 8.0)`** only (no mid/end yellow without other applied skips).
- [ ] 3. Same applied skip set: `TranscriptViewModel.make` with the **engine-applied** (or coordinator-cached playback) intervals marks `skippedAd` for every word overlapping **`[0.0, 8.0)`** and for **no** word entirely outside all applied unrelated skips.
- [ ] 4. Human checklist (non-blocking for factory Done): re-dogfood TAL 891 from **0:00** without scrubbing; confirm intro is skipped; note whether opening yellow is only bucket coarseness vs multi-minute applied spans (Console / interval dump if still wrong after AC1–3 green).

## Surgical test scope

| AC# | Test id | New? |
|-----|---------|------|
| 1 | `PodWashTests/ProgressivePlaybackTests/testIntroUnrelatedSkipFiresWhenScheduleLandsDuringIntro()` | yes |
| 2 | `PodWashTests/ProductionAnalysisWiringTests/testSeekBarYellowMatchesIntroAppliedSkipOnly()` | yes |
| 3 | `PodWashTests/TranscriptViewModelTests/testSkippedAdMatchesAppliedIntroUnrelatedSkip()` | yes (or extend existing skipped-ad suite) |

## Authorized test changes

- (none) — bug fix; new tests only. Do not weaken task-019 mid-episode paint↔skip asserts or Slice 20 yellow-overlap rules.

## Depends on

- None

## Out of scope

- Changing the **12-bucket** equal-width / any-overlap→yellow contract (file a **tweak** if product wants finer ad paint so a few-second intro does not paint ~6 min).
- Permanently enabling Clean Profanity / Skip ads and **hiding Settings toggles** (product follow-up; intake separately if desired).
- Live Whisper / TAL segmenter precision as factory Done (human checklist + escalate if AC1–3 green and device still has multi-minute early `adRanges`).
- Profanity mute markers (slice-27); mini-player-only chrome; CarPlay.

## Human checklist

- [ ] iPhone: TAL **891** downloaded; Clean Profanity on; Skip ads on (defaults).
- [ ] Play from **0:00** (no scrub). Confirm intro ad is **skipped**, not heard.
- [ ] Open transcript: intro `skippedAd` yellow matches the short intro; seek-bar yellow buckets feel consistent with that span modulo 12-bucket coarseness.
- [ ] If intro still plays or bar still wildly wrong after AC1–3 green: capture Console `preparePlayback` unrelated counts / cached interval dump; Halt and escalate segmenter — do not weaken AC1–3.

## Verification record

> Loop writes `VERIFY RESULT:` here. For tasks, `tier=2` and `filtered=1` are valid for Done.

```
VERIFY RESULT: exit=0 total=26 passed=26 failed=0 skipped=0 filtered=1 bundle=build/test-results/verify-20260715-124506.xcresult tier=2 class=tests
```
