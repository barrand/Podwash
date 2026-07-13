# Task 002 — Remove redundant “Channel on” badge under Clean channel toggle

| Field | Value |
|-------|-------|
| **ID** | 002 |
| **Title** | Remove redundant “Channel on” badge under Clean channel toggle |
| **Status** | Done |
| **Kind** | tweak |
| **Priority** | P2 |
| **Area** | `PodWash/PodWash/PodcastDetailView.swift`, `PodWash/PodWashUITests/AnalysisProgressUITests.swift` |
| **Crux** | Channel cleaning on/off is conveyed solely by `channelCleaningToggle` — no separate “Channel on” pill repeats the same state. |

## Outcome

**Current:** On the podcast detail screen (Library → show), the header shows a “Clean channel” row with `channelCleaningToggle`. When channel cleaning is enabled, an additional capsule badge labeled “Channel on” (`cleaningBadge_channelOn`) appears directly below the toggle.

**Desired:** Remove the “Channel on” badge. The toggle’s visual on-state and `accessibilityValue` (`on` / `off`) are sufficient; the badge duplicates information already shown in the toggle row.

**Framing:** If `channelCleaningToggle.accessibilityValue == "on"` and no `cleaningBadge_channelOn` exists, we never need to manually confirm “channel cleaning is on” from a second label.

## Acceptance criteria

- [ ] 1. With channel cleaning **off** (fixture feed default), `cleaningBadge_channelOn` is **not** in the accessibility tree.
- [ ] 2. After tapping `channelCleaningToggle` on, `channelCleaningToggle.accessibilityValue == "on"` within **2 s** and `cleaningBadge_channelOn` is **not** in the tree.
- [ ] 3. After tapping `channelCleaningToggle` off again, `channelCleaningToggle.accessibilityValue == "off"` within **2 s** and `cleaningBadge_channelOn` remains absent.

## Surgical test scope

| AC# | Test id | New? |
|-----|---------|------|
| 1–3 | `PodWashUITests/AnalysisProgressUITests/testToggleBadges()` | no (extend/replace channel-badge asserts) |

## Authorized test changes

- `PodWashUITests/AnalysisProgressUITests/testToggleBadges()` — **remove** assertions that `cleaningBadge_channelOn` exists after channel toggle on; **replace** with `channelCleaningToggle` `accessibilityValue` `on`/`off` asserts. Episode-badge asserts (`cleaningBadge_episodeOn`) stay unchanged.

## Depends on

- None

## Out of scope

- Episode-row “Episode on” badge (`cleaningBadge_episodeOn`) — same redundancy pattern on episode toggles; file a separate task if desired.
- Slice UX doc updates (`docs/slices/slice-09-ux.md`, `slice-20-ux.md`) — optional follow-up; not required for Done.
- Changing toggle label copy, layout of “Skip ads on channel”, or cleaning behavior.

## Human checklist

- (none — automatable tweak)

## Verification record

> Loop writes `VERIFY RESULT:` here. For tasks, `tier=2` and `filtered=1` are valid for Done.

```
VERIFY RESULT: exit=0 total=1 passed=1 failed=0 skipped=0 filtered=1 bundle=build/test-results/verify-20260713-085722.xcresult tier=2 class=tests
```
