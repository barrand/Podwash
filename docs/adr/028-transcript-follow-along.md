# ADR-028 — Transcript follow-along (karaoke + auto-scroll)

| Field | Value |
|-------|-------|
| **Status** | Accepted |
| **Date** | 2026-07-15 |
| **Supersedes** | — (lifts **“no live scroll sync while sheet stays open”** from [ADR-022](022-transcript-cache.md) §Out of scope / follow-ups and from `slice-26-ux.md` §Scroll-to-position. Does **not** change transcript cache keying, terminal-only persist, listened/skipped-ad classification, or open-time `transcript.scrollAnchor` AC8 band.) |
| **Builds on** | [ADR-000](000-foundations.md) §2/§4 (AX / offline verify; `TimedWord`); [ADR-001](001-playback-engine.md) / [ADR-006](006-playback-integration.md) (`PlaybackEngine.currentTime`); [ADR-015](015-app-shell-navigation.md) (`AppShellModel` transcript sheet); [ADR-022](022-transcript-cache.md) (`TranscriptViewModel`, `TranscriptView`, fixture) |
| **Slice** | [slice-32-transcript-follow-along.md](../slices/slice-32-transcript-follow-along.md) |

## Context

Slice 26 shipped a read-only transcript sheet: open-time listened / skipped-ad
flags, one-shot scroll to resume position, then **no** playhead sync while the
sheet stays open (`slice-26-ux.md`).

Slice 32 product pins (intake — do not re-litigate):

| Pin | Choice |
|-----|--------|
| Highlight grain | **Per-word** karaoke — active word contains live playhead in `[start, end)` |
| Past / future | Keep Slice 26 **listened** + **skippedAd** styling; active is an **additional** state that wins for the current word only |
| Follow broken | Highlight **still updates**; only auto-scroll freezes until snap-back |
| Break trigger | User-initiated vertical scroll/drag on `transcript.view` (not programmatic follow scrolls) |
| Snap-back | `transcript.snapToFollow` — visible/hittable **only when follow is off**; tap → follow **on** + scroll to active word |
| Live position | Engine / shell playhead while sheet is open (not a one-shot resume snapshot) |
| Mini under transcript | **OOS** — Task 027 |

Acceptance is unit active-index (ACs 1–2) + UITest AX / viewport / follow (ACs 3–8).
No device listening.

## Empirical validation

**No throwaway spike required.** Claims are:

| Claim | Already proven / how verified |
|-------|-------------------------------|
| Containing-word / boundary index | Same pure `Double` rule as ADR-022 `scrollAnchor` (unit-testable) |
| Live playhead sampling while UI open | `TimelineView(.periodic(…))` + `PlaybackEngine` / `avPlayer.currentTime` — Slice 03/25 `PlaybackControlsView` |
| Follow break vs programmatic scroll | App-owned seam (`noteUserScrollInteraction`) driven by SwiftUI `onScrollPhaseChange` (`.interacting` only); UITests own end-to-end swipe → `followMode` off (AC5). Adapter-only if phase mapping needs Mechanic tweak |
| Active / follow AX | Same XCTest identifier/value pattern as ADR-022 |

No new AVFoundation mix, ASR, StoreKit, CarPlay, or networking behavior.

## Decision

### 1. Lift live-sync OOS (ADR-022 / slice-26-ux)

Live playhead → active-word highlight + optional follow auto-scroll **while
`transcript.view` is presented** is in scope for Slice 32.

**Unchanged from ADR-022:**

- Open-time `transcript.scrollAnchor` contract (Slice 26 AC8 band **28…32** for
  position **30.0**) — first-appear scroll may reuse the same index helper; do
  **not** weaken or redefine the published open-time seconds value.
- Cache / pipeline / affordance gate / paragraph layout (Task 021).
- Tap-word → seek, mini-player under sheet, CarPlay / lock-screen transcript.

### 2. Module layout / file boundaries

| File | Target | Status | Responsibility |
|------|--------|--------|----------------|
| `PodWash/PodWash/TranscriptViewModel.swift` | app | **changed** | Add pure `activeWordIndex(transcript:playhead:)` (shared rule with scroll-anchor index); **no SwiftUI** |
| `PodWash/PodWash/TranscriptView.swift` | app | **changed** | Follow flag, live active overlay, `TimelineView` sampling, follow auto-scroll, snap-back control, user-scroll break seam, new AX ids |
| `PodWash/PodWash/AppShellView.swift` | app | **changed (minimal)** | Pass live `PlaybackEngine?` (or playhead provider) into `TranscriptView` while sheet presented |
| `PodWash/PodWash/AppShellModel.swift` | app | **changed (minimal)** | Keep open-time `TranscriptViewModel.make` for listened/skippedAd; do **not** rebuild the whole VM every tick for follow |
| `PodWash/PodWash/FixtureTranscript.swift` | app | **changed (minimal)** | Ensure follow UITests can open transcript **during playing / advancing** session (reuse library audio path; no new launch arg required unless QA needs a dedicated freeze/play helper) |
| `PodWash/PodWashTests/TranscriptViewModelTests.swift` | test | **changed (QA)** | AC1–AC2 |
| `PodWash/PodWashUITests/TranscriptUITests.swift` | test | **changed (QA)** | AC3–AC8 |

**Unchanged:** `TimedWord`, `TranscriptCache`, `AnalysisPipeline` transcript persist,
matcher / segmenter, open-time scroll-anchor seconds semantics.

**Serialize with Task 027** on `AppShellView` / transcript presentation if both are
In Progress.

### 3. Active-word rule (pinned — same helper as scroll-anchor index)

Expose a pure function (name flexible; behavior fixed):

```swift
/// Index of the word that should be “current” for playhead `t`.
/// Half-open contain first; else last word with `end <= t`; else `0`.
static func activeWordIndex(
    transcript: [TimedWord],
    playhead: TimeInterval
) -> Int
```

**Algorithm** (must match ADR-022 `scrollAnchor` **index** selection; seconds
rounding remains open-time-only):

1. If `transcript` is empty → `0`.
2. If some word has `start <= playhead < end` → that word’s index (**containing**).
3. Else if some word has `end <= playhead` → **last** such index (**boundary /
   gap fallback**).
4. Else → `0`.

**Boundary pin (AC2):** playhead exactly at word *i*’s `end`:

| Layout | Result |
|--------|--------|
| Contiguous (`end[i] == start[i+1]`) | Containing selects **i+1** (`start[i+1] <= t < end[i+1]`) |
| Gap (`end[i] < start[i+1]`) or last word | Fallback selects **i** (`end[i] <= t`) |

Document this table in the unit test; assert a concrete index (no “approximately”).

Open-time scroll still uses this index for `scrollTo`; `scrollAnchorSeconds`
stays `Int(round(anchorWord.start))` / existing empty / `playbackPosition <= 0`
rules from ADR-022.

### 4. Open-time VM vs live overlay

| Concern | Source | Updates while sheet open? |
|---------|--------|---------------------------|
| `listened` / `skippedAd` / aggregate counts / `scrollAnchor*` | `TranscriptViewModel.make(…, playbackPosition:)` at **present** (resume / open snapshot) | **No** — frozen for the presentation |
| `activeWordIndex` | Live playhead via §5 | **Yes** every sample tick |
| `isFollowModeOn` | `TranscriptView` `@State` (default **`true`** on appear) | User scroll → `false`; snap → `true` |

**Active wins styling** for the current word only (UX pins pixels in
`slice-32-ux.md`). Accessibility: active word’s `transcript.word_<i>` value
**includes** `active` (may combine with `listened` / `skippedAd`), **and/or**
publish dedicated `transcript.activeWord` with `accessibilityValue == "\(index)"`.
QA picks one primary assert; ADR requires at least one of the two.

### 5. Live playhead wiring

While the transcript sheet is presented:

1. Prefer the **now-playing** `PlaybackEngine` when
   `transcriptSheetEpisodeID == nowPlayingEpisodeID` and an engine exists.
2. Sample with `TimelineView(.periodic(from:by:))` at **≤ 0.25 s** (same family
   as `PlaybackControlsView`) reading `engine.currentTime` (or
   `avPlayer.currentTime().seconds` if that is what the shell already trusts for
   chrome).
3. If no engine / wrong episode (row open without session): hold playhead at the
   open-time resume position — active index stable; follow scroll is a no-op
   after first appear. Follow UITests **must** use a playing session.

Do **not** drive live sync from a one-shot `ResumePositionStore` read after open.

### 6. Follow mode + scroll break + snap-back

| Event | Follow | Scroll |
|-------|--------|--------|
| Sheet appear | `true` | One-shot open-time `scrollTo(scrollAnchorIndex)` (Slice 26); then live follow scrolls |
| `activeWordIndex` changes and follow **on** | stays `true` | `ScrollViewReader.scrollTo(activeIndex, anchor: .center)` (or UX-equivalent keep-on-screen) |
| User scroll interaction | → `false` | No further programmatic follow scrolls |
| Programmatic follow / open `scrollTo` | stays `true` | Must **not** clear follow |
| Tap `transcript.snapToFollow` (only when off) | → `true` | Scroll to current `activeWordIndex` |

**User vs programmatic:**

- Maintain `@State isFollowModeOn` and a short-lived
  `isProgrammaticScrollInFlight` (set `true` immediately before `scrollTo`, clear
  after the animation tick / next run-loop).
- On `ScrollView.onScrollPhaseChange`, when the new phase is **`.interacting`**
  (user finger) **and** `!isProgrammaticScrollInFlight` → call
  `noteUserScrollInteraction()` → `isFollowModeOn = false`.
- Do **not** clear follow on `.animating` / `.decelerating` alone when the
  programmatic gate is set.

This keeps the break rule unit-testable at the seam and AC5 assertable via UITest
swipe on `transcript.view`.

**Snap control:** present `transcript.snapToFollow` in the view tree only when
follow is off (prefer absence over disabled — AC6). Placement/copy: UX spec.

### 7. Accessibility contract (additive)

| Identifier | Role |
|------------|------|
| `transcript.followMode` | `accessibilityValue` = `on` \| `off` |
| `transcript.snapToFollow` | Snap-back control; **exists/hittable iff follow off** |
| `transcript.activeWord` | Optional dedicated host; `accessibilityValue` = `"\(activeWordIndex)"` |
| `transcript.word_<i>` | Existing; when active, value includes `active` (e.g. `active`, `listened,active`) |

Retain all ADR-022 ids (`transcript.view`, counts, `scrollAnchor`, entry
affordances). Visual active / follow chrome: `docs/slices/slice-32-ux.md`.

### 8. Verification architecture

| AC | Proof |
|----|-------|
| 1–2 | `TranscriptViewModelTests` — synthetic transcript; containing + end-boundary pins |
| 3–8 | `TranscriptUITests` + `-UITestFixtureTranscript` with **playing / advancing** playhead (open from full-player session or play then present); viewport midY + follow AX within **1.0 s**; manual scroll freeze ≥ **2.0 s**; snap restore |
| 9 | Full `scripts/verify.sh` |

No XCTSkip on core ACs. No live ASR / device listening gates.

## Consequences

- **Cross-cutting:** `TranscriptView`, `AppShellView` (engine pass-through) —
  serialize with Task 027 on shared presentation files.
- **ADR-022:** cache and open-time contracts stand; live follow is additive chrome
  owned by this ADR.
- **Performance:** 0.25 s `TimelineView` ticks only while the sheet is presented;
  do not rebuild `TranscriptViewModel.make` every tick.
- **Follow-ups (still OOS):** tap word → seek; mini under transcript (Task 027);
  live recompute of listened counts; CarPlay / lock-screen transcript.

## Out of scope (explicit)

- Mini player visibility under / beside the transcript sheet (Task 027)
- Tap word / paragraph → seek
- Sentence-only highlight
- Profanity highlighting, search, copy/share, speaker diarization
- CarPlay / lock-screen transcript
- Changing open-time `transcript.scrollAnchor` AC8 band
- Rebuilding listened/skippedAd from live playhead during the same presentation
