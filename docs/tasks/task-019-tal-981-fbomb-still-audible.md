# Task 019 — TAL 981 F-bomb still audible with Clean Profanity on

| Field | Value |
|-------|-------|
| **ID** | 019 |
| **Title** | TAL 981 F-bomb still audible at ~2:07 with Clean Profanity on |
| **Status** | Needs-human |
| **Kind** | needs-human |
| **Priority** | P1 |
| **Area** | `PodWash/PodWash/AnalysisPipeline.swift`, `PodWash/PodWash/PlaybackCoordinator.swift`, `PodWash/PodWash/WhisperKitASRTranscriber.swift`, `PodWash/PodWash/WordMatcher.swift`, `PodWash/PodWash/IntervalBuilder.swift`, `PodWash/PodWash/TranscriptCache.swift` |
| **Crux** | On device, with Clean Profanity on and analysis complete for TAL **981 The Test Case**, the spoken F-word near **2:07** (~**127 s**) is muted — **or** transcript/Console evidence proves ASR emitted no matching target token (`profanity=0` / missing word), ready to escalate to an ASR slice without bending mute wiring tests. |

## Outcome

**Observed (device, 2026-07-15):** Listening to **This American Life — 981 The Test Case**; **Clean Profanity** on; episode downloaded; analysis complete (super seek bar **green + yellow**). At **~2:07** an F-bomb was clearly audible. Transcript UI was **absent** (see related task under Out of scope), so ASR tokens at that timestamp could not be inspected in-app. Ads skip during this play was **uncertain**.

**Expected:** Matched F-words from the active Settings target set are muted during playback; if ASR never heard the word, that failure is documented for an ASR follow-up (not a mute-plumbing reopen).

**Duplicate nudge:** Continues the open **human / ASR** path from [task-015](task-015-profanity-mute-with-channel-cleaning.md) (Done — wiring ACs green). Do **not** reopen or weaken task-015 mute tests.

**Framing:** After transcript backfill (related task), if the word at ~127 s is visible and matches the target set but audio still isn’t muted → mute-apply bug; if the word is missing or mistimed → ASR slice. Console `profanity=N` remains the quick signal.

## Acceptance criteria

Needs-human — factory never auto-Dones. Checklist below is the Done gate (human Mark done on Floor).

## Surgical test scope

| AC# | Test id | New? |
|-----|---------|------|
| — | (none — Needs-human; no fake VERIFY_SLICE_TESTS) | — |

## Authorized test changes

- (none)

## Depends on

- Task 020

## Out of scope

- Transcript affordance / backfill when intervals exist without a transcript file (**Task 020**)
- Super seek bar mute markers (**slice-27**)
- Weakening `ProductionAnalysisWiringTests` mute ACs from task-015
- Whisper model upgrade until this checklist documents `profanity=0` or a missing/mismatched ASR token at ~127 s

## Human checklist

- [ ] Confirm **Clean Profanity** on; Settings **F-word** on; cleaning action **Mute**.
- [ ] After **Task 020** Done (or manual cold re-analyze that creates a transcript): open **View transcript** for 981; find words near **2:07** (~**127 s**). Record the ASR token(s) (exact strings) in the verification notes below or a comment on Floor.
- [ ] Console on play/prepare: capture `profanity=N` (and unrelated count if logged).
- [ ] Re-play through ~2:07: F-bomb **muted** → Mark done (device confirm). **Or** F-bomb still audible **and** (`profanity=0` **or** no matching token near 127 s) → Mark done with note **escalate ASR slice** (do not bend mute tests). **Or** token matches target set + `profanity≥1` but still audible → refile as **fix** (mute apply) with Console + transcript evidence.

## Verification record

> Human / Floor writes outcome here. No automated `VERIFY RESULT` required for Needs-human.

```
VERIFY RESULT: (pending — needs-human)
```
