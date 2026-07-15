# Task 021 — Transcript sentence paragraphs with start timestamps

| Field | Value |
|-------|-------|
| **ID** | 021 |
| **Title** | Transcript sentence paragraphs with start timestamps |
| **Status** | Done |
| **Done at** | 2026-07-15T18:19:48Z |
| **Kind** | tweak |
| **Priority** | P2 |
| **Area** | `PodWash/PodWash/TranscriptView.swift`, `PodWash/PodWash/TranscriptViewModel.swift`, `PodWash/PodWashTests/TranscriptViewModelTests.swift`, `PodWash/PodWashUITests/TranscriptUITests.swift` |
| **Crux** | The transcript sheet renders wrapping **sentence paragraphs** (break after words ending in `.` `?` `!`), each labeled with a **start timestamp** (`m:ss` / `mm:ss` from the paragraph’s first word `start`), not one word per line. |

## Outcome

**Current (Slice 26 ship):** `FlowTranscriptWords` is a `LazyVStack` — one ASR word per row — so a real episode transcript is nearly unreadable. Slice 26 UX asked for inline flow (“word₀ word₁ …”); the LazyVStack path won for `ScrollViewReader` stability.

**Desired:** Group words into paragraphs that end when a word’s text (trimmed) ends with `.`, `?`, or `!`. Within each paragraph, words wrap inline (space-separated). Above (or leading) each paragraph, show a non-interactive start timestamp derived from the first word’s `start` (whole seconds, `m:ss` when under 10 minutes, else `mm:ss` / `h:mm:ss` if ≥ 1 hour). Preserve per-word listened / skipped-ad styling and `transcript.word_<index>` ids. If no sentence-ending punctuation appears, the whole transcript is **one** paragraph.

**Framing:** If a ViewModel test splits on `Shit!` / `spaces.` and a UI test finds `transcript.paragraph_0.timestamp` plus two adjacent words sharing a midY, we never need to eyeball readability again.

## Acceptance criteria

- [ ] 1. Unit (`TranscriptViewModel`): words `["Hello", "there.", "Next", "bit.", "End"]` → **3** paragraphs with index ranges `[0…1]`, `[2…3]`, `[4…4]` (break after trimmed text ending in `.` `?` or `!`).
- [ ] 2. Unit (same helper): paragraph **0** start timestamp seconds = `Int(floor(firstWord.start))` for first word `start = 12.7` → **12**; formatted accessibility value / display string is **`0:12`** (minutes:seconds, no fractional).
- [ ] 3. Unit: transcript of **4** words with **no** trailing `.?!` on any word → paragraph count **1**; all **4** words in that paragraph.
- [ ] 4. UI (`-UITestFixtureTranscript`): open `transcript.view` → within **3.0** s, `transcript.paragraph_0.timestamp` exists; its `accessibilityValue` equals the fixture’s first-word start as `m:ss` / `mm:ss` (**`0:00`** for the current **24**-word fixture starting at **0.0**).
- [ ] 5. UI (same open): `transcript.word_0` and `transcript.word_1` frame midY differ by **≤ 8** points (same wrapped line — not stacked one-per-row).

## Surgical test scope

| AC# | Test id | New? |
|-----|---------|------|
| 1 | `PodWashTests/TranscriptViewModelTests/testParagraphsSplitAfterSentenceEndingPunctuation()` | yes |
| 2 | `PodWashTests/TranscriptViewModelTests/testParagraphTimestampUsesFirstWordStartWholeSeconds()` | yes |
| 3 | `PodWashTests/TranscriptViewModelTests/testNoPunctuationYieldsSingleParagraph()` | yes |
| 4 | `PodWashUITests/TranscriptUITests/testTranscriptShowsParagraphStartTimestamp()` | yes |
| 5 | `PodWashUITests/TranscriptUITests/testAdjacentTranscriptWordsShareLine()` | yes |

## Authorized test changes

Tweaks only — named existing assertions the human approved changing at intake. Empty unless an old assert conflicts.

- (none — existing Slice 26 tests assert aggregates / scroll / affordances, not one-word-per-line geometry; keep `transcript.word_<index>` and count hosts)

## Depends on

- None

## Out of scope

- Per-word timestamps in the visible UI (Slice 26 UX already excluded those)
- Tap paragraph / timestamp → seek (still follow-up)
- Pause-duration paragraph breaks (user chose sentence-end only)
- Punctuation repair / LLM reflow when ASR omits `.?!`
- Speaker diarization, search, copy/share
- Task 020 (missing transcript affordance when intervals cached) — unrelated

## Human checklist

(n/a — automatable)

## Verification record

> Loop writes `VERIFY RESULT:` here. For tasks, `tier=2` and `filtered=1` are valid for Done.

```
VERIFY RESULT: exit=0 total=13 passed=13 failed=0 skipped=0 filtered=1 bundle=build/test-results/verify-20260715-121700.xcresult tier=2 class=tests
```
