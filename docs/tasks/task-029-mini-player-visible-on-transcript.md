# Task 027 — Mini player visible on transcript screen

| Field | Value |
|-------|-------|
| **ID** | 027 |
| **Title** | Mini player visible on transcript screen |
| **Status** | Queued |
| **Kind** | tweak |
| **Priority** | P2 |
| **Area** | `PodWash/PodWash/AppShellView.swift`, `PodWash/PodWash/MiniPlayerBar.swift`, `PodWash/PodWash/TranscriptView.swift` (presentation only if needed), `PodWash/PodWashUITests/TranscriptUITests.swift` |
| **Crux** | With an active playback session, opening `transcript.view` keeps the **same** shell `miniPlayer` / `miniPlayerPlayPause` (and seek chrome) hittable — not covered or replaced by a different transport UI. |

## Outcome

**Current (Slice 26):** Transcript is presented as a `.sheet` over the app shell. `MiniPlayerBar` lives in the tab content `safeAreaInset`, so the sheet covers it. Listening while reading forces dismiss or rely on the nested full-player stack.

**Desired:** Same mini-player UI and identifiers as everywhere else. While `transcript.view` is presented and `isMiniPlayerVisible` would otherwise be true, `miniPlayer` and `miniPlayerPlayPause` exist and are hittable (user can pause/play and expand without dismissing the transcript first). Presentation may use detents, safe-area inset inside the transcript host, or re-parenting the existing `MiniPlayerBar` — Engineer/UX choice — but **must not** invent a second player chrome with different ids.

**Framing:** If a UITest opens transcript during play and asserts `miniPlayer` + `miniPlayerPlayPause` hittable alongside `transcript.view`, we never re-check device for a buried bar.

## Acceptance criteria

- [ ] 1. UI (`-UITestFixtureTranscript` or library play + transcript open): start / resume playback so mini would normally show → open transcript → within **3.0 s**, `transcript.view` exists **and** `miniPlayer` exists and is hittable.
- [ ] 2. UI (same session): `miniPlayerPlayPause` exists and is hittable while `transcript.view` is presented; toggling play/pause changes its `accessibilityValue` between `playing` and `paused` (or equivalent existing contract) within **3.0 s**.
- [ ] 3. UI: tap `miniPlayer` expand target (title/artwork — **not** play/pause) while transcript is open → within **5.0 s**, full-player chrome appears (`playback.playPause` or `playback.superSeekBar`) without requiring transcript dismiss first (Engineer may dismiss transcript as part of expand — assert full player, not that transcript stays).

## Surgical test scope

| AC# | Test id | New? |
|-----|---------|------|
| 1 | `PodWashUITests/TranscriptUITests/testMiniPlayerVisibleWhileTranscriptOpen()` | yes |
| 2 | `PodWashUITests/TranscriptUITests/testMiniPlayerPlayPauseHittableWhileTranscriptOpen()` | yes |
| 3 | `PodWashUITests/TranscriptUITests/testMiniPlayerExpandFromTranscriptOpensFullPlayer()` | yes |

## Authorized test changes

- None required for green Slice 26 tests (they do not assert mini absence under transcript). If a test currently dismisses transcript before touching mini, leave it; do not weaken transport asserts elsewhere.

## Depends on

- None

## Out of scope

- Follow-along karaoke, auto-scroll, snap-back (**Slice 32**)
- New transcript entry points (mini still has no `viewTranscript` affordance unless a later ticket asks)
- Replacing mini chrome with a transcript-only transport strip under different accessibility ids
- CarPlay / lock screen
- Changing Slice 30 mini seek-bar parity behavior beyond remaining visible under transcript

## Human checklist

(n/a — automatable)

## Verification record

> Loop writes `VERIFY RESULT:` here. For tasks, `tier=2` and `filtered=1` are valid for Done.

```
VERIFY RESULT: (pending)
```
