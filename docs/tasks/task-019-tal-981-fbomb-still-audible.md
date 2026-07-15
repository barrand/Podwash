# Task 019 — TAL 981 F-bomb still audible with Clean Profanity on

| Field | Value |
|-------|-------|
| **ID** | 019 |
| **Title** | TAL 981 F-bomb still audible at ~2:07 with Clean Profanity on |
| **Status** | Done |
| **Done at** | 2026-07-15T18:25:00Z |
| **Kind** | needs-human |
| **Priority** | P1 |
| **Area** | `PodWash/PodWash/AnalysisPipeline.swift`, `PodWash/PodWash/PlaybackCoordinator.swift`, `PodWash/PodWash/WhisperKitASRTranscriber.swift`, `PodWash/PodWash/WordMatcher.swift`, `PodWash/PodWash/IntervalBuilder.swift`, `PodWash/PodWash/TranscriptCache.swift` |
| **Crux** | On device, with Clean Profanity on and analysis complete for TAL **981 The Test Case**, the spoken F-word near **2:07** (~**127 s**) is muted — **or** transcript/Console evidence proves ASR emitted no matching target token (`profanity=0` / missing word), ready to escalate to an ASR slice without bending mute wiring tests. |

## Outcome

**Observed (device, 2026-07-15):** Listening to **This American Life — 981 The Test Case**; **Clean Profanity** on; episode downloaded; analysis complete (super seek bar **green + yellow**). At **~2:07** an F-bomb was clearly audible.

**Human resolution (2026-07-15):** After Task 020 transcript backfill, **View transcript** showed the ASR token at ~**2:07** (~**127 s**) as **`Buck`**, not an F-word / target-set match. Mute plumbing is not implicated — exact `WordMatcher` never saw a matching token. **Escalate ASR model upgrade** → [Slice 28](../slices/slice-28-device-whisper-base-en.md). Do **not** weaken task-015 mute wiring tests.

**Expected:** Matched F-words from the active Settings target set are muted during playback; if ASR never heard the word, that failure is documented for an ASR follow-up (not a mute-plumbing reopen).

**Duplicate nudge:** Continues the open **human / ASR** path from [task-015](task-015-profanity-mute-with-channel-cleaning.md) (Done — wiring ACs green). Do **not** reopen or weaken task-015 mute tests.

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
- Implementing the model upgrade (Slice 28)

## Human checklist

- [x] Confirm **Clean Profanity** on; Settings **F-word** on; cleaning action **Mute**.
- [x] After **Task 020** Done: open **View transcript** for 981; find words near **2:07** (~**127 s**). Recorded ASR token: **`Buck`**.
- [x] Outcome: F-bomb still audible **and** no matching target token near 127 s → **escalate ASR slice** (do not bend mute tests) → Slice 28.

## Verification record

> Human / Floor writes outcome here. No automated `VERIFY RESULT` required for Needs-human.

```
VERIFY RESULT: needs-human done — ASR token "Buck" @ ~127s; escalate slice-28 device base.en
```
