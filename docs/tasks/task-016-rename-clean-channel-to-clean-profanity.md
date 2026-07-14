# Task 016 — Rename “Clean channel” to “Clean Profanity”

| Field | Value |
|-------|-------|
| **ID** | 016 |
| **Title** | Rename Clean channel toggle to Clean Profanity |
| **Status** | Queued |
| **Kind** | tweak |
| **Priority** | P2 |
| **Area** | `PodWash/PodWash/PodcastDetailView.swift`, `PodWash/PodWashUITests/AnalysisProgressUITests.swift`, `PodWash/PodWashUITests/LibraryUITests.swift`, `PodWash/PodWashUITests/AnalysisTimelineUITests.swift` |
| **Crux** | Podcast detail channel-cleaning control displays **Clean Profanity** and exposes accessibility label **Clean Profanity** (no “Clean channel” / “Channel cleaning” copy on that control). |

## Outcome

**Current:** `PodcastDetailView` header shows visible `Text("Clean channel")` and `Toggle` with `.accessibilityLabel("Channel cleaning")` / id `channelCleaningToggle`.

**Desired:** Same control, same identifier `channelCleaningToggle`, copy **Clean Profanity** for both the visible caption and VoiceOver label (user-confirmed title case). Behavior and id unchanged.

**Framing:** If a UI test asserts `channelCleaningToggle.accessibilityLabel == "Clean Profanity"` (and no leftover “Clean channel” / “Channel cleaning” on that switch), we never re-check the label by eye.

## Acceptance criteria

- [ ] 1. UI test (fixture Library → show detail): `channelCleaningToggle` exists; its `accessibilityLabel` equals **`Clean Profanity`** (exact).
- [ ] 2. UI test or unit/view assert: visible caption string for the toggle row is **`Clean Profanity`** (exact) — no `Clean channel` string remains in `PodcastDetailView` for that control.
- [ ] 3. Existing UI tests that only use `channelCleaningToggle` by identifier still pass without depending on the old label strings.

## Surgical test scope

| AC# | Test id | New? |
|-----|---------|------|
| 1 | `PodWashUITests/AnalysisProgressUITests/testChannelCleaningToggleAccessibilityLabelIsCleanProfanity()` | yes |
| 2 | same method or paired assert in that test | yes |
| 3 | `PodWashUITests/AnalysisProgressUITests/testEpisodeCleaningTogglesAbsentChannelTogglePresent()` | no — authorized bend if it asserted old copy |
| 3 | `PodWashUITests/LibraryUITests` / `AnalysisTimelineUITests` helpers that mention old label in messages only | no — authorized bend |

## Authorized test changes

- `PodWashUITests/AnalysisProgressUITests.swift` — may assert new a11y label; update failure messages that say “Channel cleaning” / “Clean channel”.
- `PodWashUITests/LibraryUITests.swift`, `PodWashUITests/AnalysisTimelineUITests.swift` — update string literals in messages/comments only; keep querying `channelCleaningToggle` by id.
- Do **not** rename `channelCleaningToggle` accessibility **identifier** (stable id).

## Depends on

- None

## Out of scope

- Renaming `channelCleaningToggle` identifier or Core Data `channelCleaningEnabled`
- Changing “Skip ads on channel” copy
- Profanity mute correctness (task-015)

## Human checklist

- (none — automatable)

## Verification record

> Loop writes `VERIFY RESULT:` here. For tasks, `tier=2` and `filtered=1` are valid for Done.

```
VERIFY RESULT: (pending)
```
