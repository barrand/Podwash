# Task 024 — Distinguish download vs delete affordances

| Field | Value |
|-------|-------|
| **ID** | 024 |
| **Title** | Distinguish download vs delete affordances |
| **Status** | Queued |
| **Kind** | tweak |
| **Priority** | P2 |
| **Area** | `PodWash/PodWash/EpisodeListView.swift`, `PodWash/PodWashTests/` (download affordance layout/unit tests), `docs/slices/slice-10-downloads-ux.md` (icon/tint note only) |
| **Crux** | Episode-row `downloadButton_*` in `.notDownloaded` vs `.downloaded` uses **different SF Symbols and different tints**, so a layout/unit test on the cell seam proves the two states are visually distinct without relying on VoiceOver labels. |

## Outcome

**Current:** One trailing control toggles download ↔ delete. Both states use outline circle SF Symbols at the same size and **accent** tint (`arrow.down.circle` → `trash.circle`), so at a glance they look almost identical. Accessibility already differs (`Download episode` / `Delete download`; values `notDownloaded` / `downloaded`).

**Desired:** Keep the single-button contract and existing a11y identifier/value/label/hint strings. Make delete glanceably different: **non-matching trash glyph** (no paired circle outline — e.g. `trash` or `trash.fill`) plus **`.systemRed`** tint. Download / downloading keep `arrow.down.circle` + accent/`tintColor`. Failed stays red `exclamationmark.circle`.

**Framing:** If a unit test configures the cell for both states and asserts unequal images plus red tint only when downloaded, we never re-check “is that download or trash?” by eye.

## Acceptance criteria

- [ ] 1. Unit/layout test: configure `EpisodeTableViewCell` download affordance for `.notDownloaded` → button image uses SF Symbol **`arrow.down.circle`** (or equivalent resolved `UIImage(systemName:)`), and `tintColor` is **not** `.systemRed` (accent / `tintColor` path).
- [ ] 2. Unit/layout test: same seam for `.downloaded` → button image SF Symbol is **`trash` or `trash.fill`** (not `trash.circle` / not equal to the not-downloaded image), and `tintColor` equals **`.systemRed`**.
- [ ] 3. Existing UI flow still holds: `PodWashUITests/DownloadUITests/testDownloadAndDeleteButtonFlow()` remains green (`notDownloaded` → tap → `downloaded` → tap → `notDownloaded`; labels/hints unchanged from Slice 10).

## Surgical test scope

| AC# | Test id | New? |
|-----|---------|------|
| 1 | `PodWashTests/EpisodeDownloadAffordanceTests/testNotDownloadedUsesArrowDownCircleWithNonRedTint()` | yes |
| 2 | `PodWashTests/EpisodeDownloadAffordanceTests/testDownloadedUsesTrashGlyphWithSystemRedTint()` | yes |
| 3 | `PodWashUITests/DownloadUITests/testDownloadAndDeleteButtonFlow()` | no |

## Authorized test changes

Tweaks only — named existing assertions the human approved changing at intake. Empty unless an existing assert locks the old icons.

- (none) — `DownloadUITests` keys off `accessibilityValue` only; Slice 10 UX already allows icon change. New tests assert the new visual contract. Update `docs/slices/slice-10-downloads-ux.md` icon examples to match (doc, not XCTest).

## Depends on

- None

## Out of scope

- Separate delete button or confirmation sheet
- Checkmark-for-downloaded / different delete interaction
- Changing `downloadButton_*` identifier, `accessibilityValue` strings, or VoiceOver labels/hints
- Queue / transcript accessory icons
- Device download reliability (task-001 / task-007)

## Verification record

> Loop writes `VERIFY RESULT:` here. For tasks, `tier=2` and `filtered=1` are valid for Done.

```
VERIFY RESULT: (pending)
```
