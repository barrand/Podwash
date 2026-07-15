# Slice 29 cleaning-summary fixtures — provenance

**Hard QA rule:** goldens here have provenance **independent of the code under test**.
They are hand-computed from the pinned interval table in
`docs/slices/slice-29-episode-cleaning-summary.md` (AC1) and ADR-025 §3–§4 — **not**
generated from `CleaningSummaryModel` or any PodWash implementation.

## `cleaning-summary-pinned.intervals.json`

| # | start | end | action | source |
|---|-------|-----|--------|--------|
| 1 | 10.0 | 11.0 | mute | profanity |
| 2 | 20.0 | 21.5 | mute | profanity |
| 3 | 30.0 | 90.0 | skip | unrelatedContent |
| 4 | 100.0 | 130.0 | skip | unrelatedContent |

**Expected aggregation (hand-computed):**

- `profanitySectionCount` = 2 (all `.profanity`, any action)
- `adSectionCount` = 2 (all `.unrelatedContent`)
- `adDurationSeconds` = (90 − 30) + (130 − 100) = **90.0**
- `formattedAdMinutes` = **1.5 min** (90 / 60)
- `accessibilityValue` = **profanity:2,ads:2,adMinutes:1.5**

**Rounding pin (AC3, unit-only):** `adDurationSeconds = 45.0` → 45/60 = 0.75 → round half up to one decimal → **0.8 min**.
