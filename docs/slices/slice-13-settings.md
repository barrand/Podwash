# Slice 13 — Settings + word-list management

| Field | Value |
|-------|-------|
| **ID** | 13 |
| **Title** | Settings + word-list management |
| **Status** | Draft |
| **Crux** | A settings screen persists cleaning defaults (action, categories, custom words) and playback defaults, all assertable through injected stores and accessibility identifiers. |

## PRD / spec references

- PRD §5 — Category/word selection, custom words, faith/family default profile
- PRD §11 — ⚠️ Halt-and-ask items surface here if reached: **default word/category profile**, **default action (mute vs skip)**, **analysis timing** — surface to the user rather than deciding.
- `docs/specs/matching-spec.md` §7 — seeded category lists

## Goal

User-facing configuration for cleaning and playback defaults.

## Deliverables

- Settings screen (SwiftUI): default action (mute/skip), category toggles, custom word add/remove, default speed, auto-download/auto-delete stubs
- Word-list store feeding `WordMatcher` (Slice 02 lists as seeds)
- Injected `UserDefaults`/store for tests
- `SettingsStoreTests`, `SettingsUITests`

## Depends on

- Slices 02, 11

**Parallelizable:** Yes — with Slices 12, 14.

## Out-of-scope

- Paywall/entitlement gating of settings (Slice 17)
- Re-analysis orchestration on word change (covered by Slice 07 AC3)

## Acceptance criteria

- [ ] 1. Unit test: category toggle changes the active target set passed to `WordMatcher` (normalized per spec §3).
- [ ] 2. Unit test: adding a custom word normalizes it and includes it in matching; removing excludes it; both persist across store reload.
- [ ] 3. Unit test: default action and default speed persist via injected store.
- [ ] 4. UI test: toggling a category switch (identifier `categoryToggle_<name>`) updates its accessibility value; adding a custom word appears in the list.
- [ ] 5. Full suite green via `scripts/verify.sh`.

## Verification mapping

| AC# | Test file | Test method | Notes |
|-----|-----------|-------------|-------|
| 1 | `PodWash/PodWashTests/SettingsStoreTests.swift` | `testCategoryToggleUpdatesTargetSet` | TBD |
| 2 | `PodWash/PodWashTests/SettingsStoreTests.swift` | `testCustomWordLifecycle` | TBD |
| 3 | `PodWash/PodWashTests/SettingsStoreTests.swift` | `testDefaultsPersist` | TBD |
| 4 | `PodWash/PodWashUITests/SettingsUITests.swift` | `testCategoryAndCustomWordUI` | TBD |
| 5 | — | — | Command-level |

## Verification commands

```bash
scripts/verify.sh -only-testing:PodWashTests/SettingsStoreTests -only-testing:PodWashUITests/SettingsUITests
scripts/verify.sh    # Done gate
```

## Verification record (QA fills at Verify)

```
VERIFY RESULT: (pending)
```

## Done gate

- [ ] Every AC mapped to a test; all rows filled
- [ ] **Full suite green:** unfiltered `scripts/verify.sh` exit 0, failed 0, skipped 0
- [ ] Verification record pasted above
- [ ] Auto-commit on green: `slice-13: <short description>`

## Role artifacts

| Role | Gate | Artifact path |
|------|------|---------------|
| Architect | Waived | — |
| UX | Required | `docs/slices/slice-13-ux.md` (TBD) |
