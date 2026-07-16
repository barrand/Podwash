# Slice 32 — Transcript follow-along (karaoke + auto-scroll)

| Field | Value |
|-------|-------|
| **ID** | 32 |
| **Title** | Transcript follow-along (karaoke + auto-scroll) |
| **Status** | Implemented |
| **Priority** | P3 |
| **Crux** | While `transcript.view` is open and playback advances, the **current word** is marked active and (in follow mode) the list auto-scrolls to it; a **manual scroll** turns follow **off** without freezing the active highlight; **`transcript.snapToFollow`** restores follow and scrolls to the live word. |

## PRD / spec references

- PRD — transcript / listen-along reading (product intent; no dedicated § yet)
- `docs/adr/000-foundations.md` — AX / offline verify over device listening
- `docs/adr/022-transcript-cache.md` — `TimedWord`, `TranscriptViewModel` listened/skipped-ad classification, open-time scroll anchor (live sync was OOS)
- Slice 26 — shipped read-only viewer; UX explicitly deferred live scroll sync

## Goal

Let a listener read along with karaoke-style **per-word** highlighting, keep the viewport on the playhead when follow mode is on, break follow by scrolling manually, and snap back with one control — without requiring tap-to-seek or a second transcript chrome.

## Intake decisions (locked)

| Decision | Choice |
|----------|--------|
| Highlight grain | **Per-word** (karaoke) — active word is the one whose `[start, end)` contains the live playhead (same containing-word rule as open-time scroll anchor) |
| Past / future | Keep Slice 26 **listened** (de-emphasized) and **skippedAd** styling; active word is an additional state that wins for the current word only |
| Follow broken | **Highlight still updates** with playback; only auto-scroll is frozen until snap-back |
| Break trigger | User-initiated vertical scroll / drag on the transcript `ScrollView` (not programmatic follow scrolls) |
| Snap-back | Button `transcript.snapToFollow` — **visible and hittable only when follow mode is off**; tap sets follow **on** and scrolls to the active word |
| Live position source | Engine / shell playhead while sheet is open (not a one-shot resume snapshot) |
| Mini player on transcript | **Out of scope** — filed as Task 027 (same shell `miniPlayer`) |

## Deliverables

- ADR — [`docs/adr/028-transcript-follow-along.md`](../adr/028-transcript-follow-along.md) (lifts live scroll sync OOS from ADR-022 / slice-26-ux; new ADR, does not rewrite 022)
- UX spec `docs/slices/slice-32-ux.md` — active-word styling, follow-mode AX, snap-back placement, scroll-break semantics, fixture scenarios
- `TranscriptView` / `TranscriptViewModel` (or thin follow-mode host) — live active index, follow flag, snap-back control
- Shell wiring so open transcript receives playhead updates while presented
- Unit + UI tests per AC mapping below

## Depends on

- Slice 26 (Done) — transcript viewer + paragraph layout (Task 021)

**Parallelizable:** Yes vs Task 027 (mini player under transcript) if workers do not both edit `AppShellView` / transcript presentation at once — serialize those files if both are In Progress.

## Out-of-scope

- Mini player visibility under / beside the transcript sheet (**Task 027**)
- Tap word / paragraph → seek
- Sentence-only highlight (intake chose per-word)
- Profanity highlighting, search, copy/share, speaker diarization
- CarPlay / lock-screen transcript
- Changing open-time `transcript.scrollAnchor` contract for first appear (may reuse helper; do not weaken Slice 26 AC8 band)

## Acceptance criteria

Automatable only. **XCTSkip is not allowed on core ACs.**

- [ ] 1. Unit (`TranscriptViewModel` or follow helper): for a synthetic transcript and playhead inside word *i*’s `[start, end)`, `activeWordIndex == i`.
- [ ] 2. Unit: playhead exactly at word *i*’s `end` (and before next `start` if any) selects the next containing word or the last listened rule consistent with ADR scroll-anchor fallback — document the pinned rule in the test; assert a concrete index (no “approximately”).
- [ ] 3. UI (`-UITestFixtureTranscript` + playing / advancing position fixture): with follow **on**, within **1.0 s** of playhead entering a later word, that word’s accessibility element reports active state (e.g. `transcript.word_<i>` `accessibilityValue` includes `active`, or dedicated `transcript.activeWord` value equals `"<i>"`).
- [ ] 4. UI: while follow **on**, after playhead advances across ≥ **2** word boundaries, the active word’s frame midY is within the transcript scroll viewport (on-screen) within **1.0 s** of each boundary (auto-scroll).
- [ ] 5. UI: perform a user scroll on `transcript.view` → within **1.0 s**, `transcript.followMode` `accessibilityValue` is `off`; with playback still advancing for **≥ 2.0 s**, scroll offset does **not** jump back to the active word (follow frozen).
- [ ] 6. UI: while follow is **off**, `transcript.snapToFollow` exists and is hittable; while follow is **on**, `transcript.snapToFollow` does **not** exist (or is not hittable).
- [ ] 7. UI: with follow **off**, tap `transcript.snapToFollow` → within **1.0 s**, `transcript.followMode` is `on` and the active word is on-screen (midY in viewport).
- [ ] 8. UI: with follow **off** and playback advancing, the active-word AX still updates within **1.0 s** of a word boundary (highlight continues without scroll).
- [ ] 9. Full suite green via `scripts/verify.sh` (**exit 0, failed 0, skipped 0**).

## Verification mapping

| AC# | Test file | Test method | Notes |
|-----|-----------|-------------|-------|
| 1 | `PodWash/PodWashTests/TranscriptViewModelTests.swift` | `testActiveWordIndexMatchesPlayheadContainingWord` | TBD until QA test spec |
| 2 | `PodWash/PodWashTests/TranscriptViewModelTests.swift` | `testActiveWordIndexAtWordEndBoundary` | Pinned boundary rule |
| 3 | `PodWash/PodWashUITests/TranscriptUITests.swift` | `testActiveWordUpdatesWithPlayback` | Live position fixture |
| 4 | `PodWash/PodWashUITests/TranscriptUITests.swift` | `testFollowModeAutoScrollsActiveWordOnScreen` | Viewport midY |
| 5 | `PodWash/PodWashUITests/TranscriptUITests.swift` | `testManualScrollDisablesFollowMode` | No scroll jump ≥ 2 s |
| 6 | `PodWash/PodWashUITests/TranscriptUITests.swift` | `testSnapToFollowVisibleOnlyWhenFollowOff` | Button gate |
| 7 | `PodWash/PodWashUITests/TranscriptUITests.swift` | `testSnapToFollowRestoresFollowAndScroll` | Tap snap-back |
| 8 | `PodWash/PodWashUITests/TranscriptUITests.swift` | `testActiveWordStillUpdatesWhenFollowOff` | Highlight without scroll |
| 9 | — | — | Unfiltered `scripts/verify.sh` |

## Verification commands

```bash
# Fast inner loop (NOT sufficient for Done):
scripts/verify.sh -only-testing:PodWashTests/TranscriptViewModelTests
scripts/verify.sh -only-testing:PodWashUITests/TranscriptUITests

# Done gate — FULL suite, zero failures, zero skips:
scripts/verify.sh
```

## Verification record (QA fills at Verify)

```
VERIFY RESULT: exit=0 total=0 passed=0 failed=0 skipped=0 filtered=1 bundle=build/test-results/verify-20260715-233729.xcresult tier=2 class=tests
```

## Plan review record (coordinator fills before downstream roles)

```
ADR review (2026-07-15): (pending) QA cleared — pipeline worker finished PM cleared — pipeline worker finished
Test spec review (2026-07-15): Architect cleared — pipeline worker finished
```

## Done gate

- [ ] Every AC mapped to a test; all rows in the mapping table filled
- [ ] **Full suite green:** unfiltered `scripts/verify.sh` exit 0, failed 0, skipped 0
- [ ] Verification record pasted above
- [ ] Auto-commit on green: `slice-32: transcript follow-along`

## Tickets (optional)

| Ticket | Owner role | AC subset | Depends on |
|--------|------------|-----------|------------|
| — | — | — | — |

## Role artifacts

| Role | Gate | Artifact path |
|------|------|---------------|
| UX | Before Engineer | `docs/slices/slice-32-ux.md` |
| Architect | Before QA tests | [`docs/adr/028-transcript-follow-along.md`](../adr/028-transcript-follow-along.md) |
| QA | Test spec | mapping table above |
| Engineer | Implement | `PodWash/PodWash/**` only |
