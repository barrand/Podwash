# Task 014 — Done column recency and closed-at timestamp

| Field | Value |
|-------|-------|
| **ID** | 014 |
| **Title** | Done column recency and closed-at timestamp |
| **Status** | Done |
| **Kind** | tweak |
| **Priority** | P2 |
| **Area** | `scripts/factory_floor/server.py`, `scripts/task_ticket.py`, `scripts/slice_pipeline.py`, `scripts/test_forge_floor_board.py` |
| **Crux** | Forge Floor **Done** column lists most-recently-closed tickets first and shows a **closed-at** datetime on cards that have it — without guessing timestamps for legacy Done items. |

## Outcome

**Current:** The Done column renders tasks (and optional slices) in filename order from `board_snapshot()` with no closed-at display on cards.

**Desired:** Done-column cards sort by closure time descending (newest at top). Cards show a human-readable closed-at line when the ticket has a recorded **Done at** metadata field. Legacy Done items without that field sort after dated items (stable tie-break by id) and show no closed-at line.

## Acceptance criteria

- [ ] 1. When `set_task_status(path, "Done")` or `set_slice_status(..., "Done")` runs, the ticket metadata table gains or updates `| **Done at** | <ISO-8601 UTC, e.g. 2026-07-13T23:23:00Z> |` in the same edit as the Status flip. Re-marking Done refreshes **Done at** to the new transition time.
- [ ] 2. `board_snapshot()` includes `done_at` (ISO string or `null`) on each task and slice item parsed from metadata **Done at**; no backfill from events or file mtime.
- [ ] 3. Forge Floor client sorts Done-column items by `done_at` descending; items with `null` `done_at` appear below all dated items, stable tie-break by numeric id ascending.
- [ ] 4. Done-column cards with non-null `done_at` render a meta line containing the literal substring `closed` and a locale-neutral datetime (e.g. `2026-07-13 17:23` local browser time or `Jul 13, 5:23 PM`); cards with `null` `done_at` omit that line (no placeholder dash).
- [ ] 5. Drawer detail for a Done ticket with **Done at** shows the same timestamp in ticket meta (chip or labeled row).
- [ ] 6. Non-Done columns keep existing ordering unchanged.

## Surgical test scope

| AC# | Test id | New? |
|-----|---------|------|
| 1 | `scripts.test_forge_floor_board.DoneColumnTests/test_set_task_status_done_writes_done_at` | yes |
| 2 | `scripts.test_forge_floor_board.DoneColumnTests/test_board_snapshot_includes_done_at` | yes |
| 3 | `scripts.test_forge_floor_board.DoneColumnTests/test_done_sort_newest_first` | yes |
| 4 | `scripts.test_forge_floor_board.DoneColumnTests/test_done_card_html_includes_closed_at` | yes |

## Authorized test changes

- (none)

## Depends on

- None

## Out of scope

- Backfilling **Done at** for existing Done tickets from events, git, or file mtime.
- Changing Queued / In Progress / Halted / Needs-human column sort.
- App (`PodWash/`) or XCTest targets.

## Human checklist

- (n/a — automatable tweak)

## Verification record

> Loop writes `VERIFY RESULT:` here. For tasks, `tier=2` and `filtered=1` are valid for Done.

```
VERIFY RESULT: exit=0 total=4 passed=4 failed=0 skipped=0 filtered=1 bundle=scripts-unittest tier=2 class=unittest
```
