# Task 023 — Hide channel Clean Profanity / Skip ads toggles; default both on

| Field | Value |
|-------|-------|
| **ID** | 023 |
| **Title** | Hide channel Clean Profanity / Skip ads toggles; default both on |
| **Status** | In Progress |
| **Kind** | tweak |
| **Priority** | P2 |
| **Area** | `PodWash/PodWash/PodcastDetailView.swift`, `PodWash/PodWash/CleaningToggleStore.swift`, `PodWash/PodWash/PodcastStore.swift`, `PodWash/PodWash/PersistenceController.swift` (or one-shot migrate helper), `PodWash/PodWashUITests/AnalysisProgressUITests.swift`, `PodWash/PodWashUITests/SkipOverrideUITests.swift`, UI helpers that tap `channelCleaningToggle` |
| **Crux** | Podcast detail exposes **no** `channelCleaningToggle` / `channelUnrelatedContentToggle` / `channelCleaningCaption`; every persisted `CDPodcast` (migrated + newly subscribed) has `channelCleaningEnabled == true` and `channelUnrelatedContentEnabled == true`. |

## Outcome

**Current:** `PodcastDetailView` header shows **Clean Profanity** (`channelCleaningToggle`) and **Skip ads on channel** (`channelUnrelatedContentToggle`). New subscriptions and `CleaningToggleStore.requirePodcast*` seed both flags **false**. Dogfood already treats both as always-on (task-022 standing assumption); the detail toggles are noise.

**Desired:** Remove both channel-detail toggle rows (and the Clean Profanity caption). Default **on** for new podcasts. **Migrate all stored channels** so existing Core Data rows flip both flags to **on** on first launch after the change. **Settings** global **Skip ads** (`unrelatedContentToggle` / `SettingsStore.unrelatedContentEnabled`) and word-category / mute-action controls **stay** — user confirmed leave Settings alone.

**Framing:** If a UI test opens podcast detail and asserts those three identifiers are absent, and a unit test proves subscribe + one-shot migrate leave both channel flags true, we never re-check “did I flip the channel switches?” by eye.

## Acceptance criteria

- [ ] 1. UI test (Library fixture → podcast detail / episode list): `channelCleaningToggle`, `channelUnrelatedContentToggle`, and `channelCleaningCaption` **do not exist** within **5 s** of detail appearing.
- [ ] 2. Unit test: after `PodcastStore` subscribe/upsert of a **new** feed (isolated Core Data), `CleaningToggleStore.isChannelCleaningEnabled(forFeedURL:)` and `isChannelUnrelatedContentEnabled(forFeedURL:)` are both **`true`**.
- [ ] 3. Unit test: seed ≥ **2** `CDPodcast` rows with both flags **`false`**, run the one-shot migrate (same entry point production uses on launch), then every podcast has both flags **`true`** (and a second migrate call is a no-op / still all true).
- [ ] 4. Settings UI still exposes `unrelatedContentToggle` (fresh Settings fixture: control **exists**; default value may remain off — not in scope to flip Settings default).

## Surgical test scope

| AC# | Test id | New? |
|-----|---------|------|
| 1 | `PodWashUITests/AnalysisProgressUITests/testChannelDetailCleaningTogglesAbsent()` | yes (replaces `testChannelCleaningToggleAccessibilityLabelIsCleanProfanity` / presence half of `testEpisodeCleaningTogglesAbsentChannelTogglePresent`) |
| 2 | `PodWashTests/PersistenceMigrationTests/testNewSubscriptionDefaultsChannelCleaningAndUnrelatedOn()` | yes |
| 3 | `PodWashTests/PersistenceMigrationTests/testMigrateAllChannelsCleaningAndUnrelatedOn()` | yes |
| 4 | `PodWashUITests/SkipOverrideUITests/testUnrelatedContentGlobalDefaultOff()` | no — keep existence; must still pass |

## Authorized test changes

- `PodWashUITests/AnalysisProgressUITests.swift` — **bend/remove** asserts that require `channelCleaningToggle` / `channelCleaningCaption` existence or label **Clean Profanity**; `testToggleBadges` / `testAnalysisProgressLifecycle` must not tap a removed switch (enable via defaults / store seed / launch arg only).
- `PodWashUITests/SkipOverrideUITests.swift` — **bend** `testChannelToggleDefaultOff()` to assert channel toggle **absent** (or delete that method if AC1 covers it); do **not** change `testUnrelatedContentGlobalDefaultOff` default-off assert.
- `PodWashUITests/LibraryUITests.swift`, `AnalysisTimelineUITests.swift`, `TranscriptUITests.swift`, `SuperSeekBarUITests.swift`, `ProgressivePlaybackUITests.swift` — helpers that **tap** `channelCleaningToggle` to turn cleaning on: remove the tap / wait-for-switch; rely on migrated/default-on channel flags (authorized bend of those helpers only).
- Unit tests that **explicitly** call `setChannelCleaning(..., enabled: false)` to assert off-path behavior remain valid and are **not** authorized to be weakened.

## Depends on

- None

## Out of scope

- Hiding or flipping Settings **Skip ads** / word categories / cleaning action (stay as today).
- Removing Core Data attributes or accessibility **identifier** names from the codebase forever (identifiers simply must not appear in the detail hierarchy).
- Changing ADR-013 / PRD §4 global “unrelated off by default” for Settings (channel always-on is the dogfood product delta; document in forge-fix / PRD follow-up if needed).
- Intro-ad skip / seek-bar correctness (already filed separately).
- Re-adding per-episode cleaning toggles.

## Human checklist

- (none — automatable)

## Verification record

> Loop writes `VERIFY RESULT:` here. For tasks, `tier=2` and `filtered=1` are valid for Done.

```
VERIFY RESULT: exit=0 total=11 passed=11 failed=0 skipped=0 filtered=1 bundle=build/test-results/verify-20260715-162250.xcresult tier=2 class=tests
```
