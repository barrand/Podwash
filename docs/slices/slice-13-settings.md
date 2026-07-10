# Slice 13 — Settings + word-list management

| Field | Value |
|-------|-------|
| **ID** | 13 |
| **Title** | Settings + word-list management |
| **Status** | Ready |
| **Crux** | `SettingsStore` (injectable `UserDefaults`) persists the PRD default profile, category toggles, custom words, and playback/cleaning defaults; the composed normalized target set it exposes to `WordMatcher` changes predictably when categories toggle — all assertable without network, ASR, or manual review. |

## PRD / spec references

- PRD §2 — Auto-download and auto-delete-after-played settings; variable speed defaults
- PRD §5 — Category/word selection, custom words, faith/family default profile
- PRD §11 — ✅ **Resolved 2026-07-10** (see § Product decisions below)
- `docs/specs/matching-spec.md` §3 — `normalize_word` (target-set composition uses the same rules)
- `docs/specs/matching-spec.md` §7 — seeded category starting lists (extend beyond the two Slice 02 profiles)
- `docs/adr/000-foundations.md` §4 — `TimedWord` / matcher inputs unchanged
- Slice 12 — supported playback rates `[0.75, 1.0, 1.25, 1.5, 2.0, 3.0]` (default-speed setting must use this set)

## Product decisions (user, 2026-07-10 — unblocks this slice)

| Decision | Choice |
|----------|--------|
| Default word/category profile | **Profanity (F/S/D-word) + racial/hate slurs ON**; other categories OFF until user opts in |
| Default cleaning action | **Mute** (skip remains user-selectable in settings) |
| Analysis timing | **First play with cleaning enabled** — toggling cleaning on then playing triggers one-time analysis |
| Interval retention | **Until episode deleted** — purge cached intervals with download/cache removal |
| Skipper-style timeline UI | **New slice 20** — not in Slice 13 scope (blue/green/yellow/grey segment colors) |

## Goal

Ship a Settings screen and backing store so users can persist cleaning defaults (action, categories, custom words) and playback defaults (speed, auto-download/auto-delete toggles) on-device, with the composed word list feeding `WordMatcher` per the matching spec.

## Deliverables

- `WordCategories.swift` (or extend `WordProfiles.swift`) — stable seeded category IDs and word lists:
  - **`fWord`**, **`sWord`**, **`dWord`**, **`racialSlurs`** — **ON** by default (PRD §5 / §11)
  - **`godsName`**, **`otherProfanity`** — **OFF** by default (minimum **2** opt-in categories; add more only if PRD groupings require)
  - Pin **`sWord`** seed to **exactly 4** words: `"shit"`, `"shits"`, `"shitty"`, `"bullshit"` (spec §7 S-word subset; inflections enumerated, no stemming)
  - Pin **`fWord`** seed to **≥ 1** word including `"fuck"` (full F-word list committed; tests assert via `"fuck"` / `"shit"` only)
  - **`racialSlurs`** — committed seed list with **≥ 1** word (exact list in code; tests need not assert slur tokens — count delta on disable is enough)
- `SettingsStore.swift` — injectable `UserDefaults` suite; APIs at minimum:
  - `activeNormalizedTargetSet() -> Set<String>` — union of enabled category words + custom words, each passed through `WordMatcher.normalize(_:)` / `WordMatcher.normalizedTargetSet`
  - `defaultCleaningAction`, `defaultPlaybackRate`, `autoDownloadEnabled`, `autoDeleteAfterPlayedEnabled`
  - Category enable/disable + custom-word add/remove with persistence
- `SettingsView.swift` — SwiftUI settings screen reachable from app chrome; accessibility identifiers:
  - `categoryToggle_<categoryID>` — e.g. `categoryToggle_sWord`; `accessibilityValue` **`"1"`** when enabled, **`"0"`** when disabled
  - `defaultActionControl` — `accessibilityValue` **`"mute"`** or **`"skip"`**
  - `defaultSpeedButton` — `accessibilityValue` decimal rate string (`"0.75"` … `"3.0"`, same set as Slice 12)
  - `customWordTextField`, `customWordAddButton`, `customWordRow_<index>` (0-based; label contains the stored word)
  - `autoDownloadToggle`, `autoDeleteToggle` — `accessibilityValue` **`"1"`** / **`"0"`**
- Launch argument **`-UITestFixtureSettings`** — opens Settings directly (no RSS/network); parallelization off per Slice 03 precedent
- Wire `SettingsStore.activeNormalizedTargetSet()` into the analysis/playback path where Slice 07/08 currently take a raw target word array (minimal seam — no re-analysis orchestration)
- `PodWash/PodWashTests/SettingsStoreTests.swift`
- `PodWash/PodWashUITests/SettingsUITests.swift`
- Architect decision (if public API or persistence boundary is non-trivial): `docs/adr/010-settings-word-lists.md`

## Fixture strategy (pinned)

| Asset | Role |
|-------|------|
| In-memory / isolated `UserDefaults` suite per test | No cross-test leakage; reload = new `SettingsStore(userDefaults: same suite)` |
| Custom-word token **`"xyzzy!"`** | Normalizes to **`"xyzzy"`** per spec §3 (unique vs seeded lists) |
| Category **`sWord`** | Exactly **4** words; disabling drops set size by **4** and removes `"shit"` membership |
| Default playback rate | **`1.0`** fresh; persist test uses **`2.0`** (member of Slice 12 supported set) |

## Depends on

- Slice 02 — `WordMatcher`, `WordProfiles` / normalization semantics
- Slice 11 — durable on-device persistence stack (settings use **`UserDefaults`**, not Core Data entities — no schema migration in this slice)

**Parallelizable:** Yes — with Slices 12, 14 (parallel group B/C boundary). No queue-order, download-bytes, or lock-screen behavior changes.

## Out-of-scope

- Paywall/entitlement gating of settings (Slice 17)
- Re-analysis orchestration when word lists change (Slice 07 AC3 — cache miss on fingerprint change only; this slice does not trigger analysis)
- Skipper-style analysis timeline UI (Slice 20)
- Auto-download network fetches, auto-delete file deletion, or RSS subscription side effects (boolean stubs persist only)
- Subjective “sensible defaults” listening or visual polish reviews
- Expanding ASR models, changing matcher padding math, or editing golden interval JSON
- Cross-device sync (PRD §9)
- Lock screen / CarPlay settings surfacing (Slices 14–15)
- Attorney-gated skip **feature ship** decision (PRD §11 open item) — settings exposes skip as a selectable default action; shipping policy is not decided here

## Acceptance criteria

Automatable only. **XCTSkip is not allowed on core ACs** — a mapped test that cannot run must fail.

- [ ] 1. Unit test (`SettingsStore`, fresh isolated `UserDefaults`): **`enabledCategoryIDs == ["dWord", "fWord", "racialSlurs", "sWord"]`** (sorted set equality — exactly **4** categories ON); **`godsName`** and **`otherProfanity`** (and any other seeded categories) OFF; `defaultCleaningAction == .mute`; `defaultPlaybackRate == 1.0` (± **0.001**); `autoDownloadEnabled == false`; `autoDeleteAfterPlayedEnabled == false`.
- [ ] 2. Unit test (`SettingsStore` + `WordMatcher`): with defaults, `WordMatcher.matches("shit", in: store.activeNormalizedTargetSet()) == true`; after `setCategoryEnabled("sWord", false)`, `matches("shit", ...) == false` and `matches("fuck", ...) == true`; `activeNormalizedTargetSet().count` decreases by exactly **4**; re-enable `sWord` → `"shit"` matches again; new `SettingsStore` on the **same** `UserDefaults` suite retains disabled state and set size.
- [ ] 3. Unit test (`SettingsStore` custom words): `addCustomWord("  xyzzy!  ")` → `activeNormalizedTargetSet()` contains **`"xyzzy"`**; `removeCustomWord("xyzzy")` → not contained; after new store instance on same suite, word stays removed; add again → persists as **`"xyzzy"`** (normalized per spec §3).
- [ ] 4. Unit test (`SettingsStore` playback/cleaning defaults): set `defaultCleaningAction = .skip`, `defaultPlaybackRate = 2.0`, `autoDownloadEnabled = true`, `autoDeleteAfterPlayedEnabled = true`; new store on same suite → action **`.skip`**, rate **`2.0 ± 0.001`**, both booleans **`true`**.
- [ ] 5. UI test (`-UITestFixtureSettings`): `categoryToggle_sWord` `accessibilityValue == "1"`; **1** tap → `"0"`; **1** more tap → `"1"`.
- [ ] 6. UI test (`-UITestFixtureSettings`): enter **`"testword"`** in `customWordTextField`, tap `customWordAddButton`; `customWordRow_0` exists and its label contains **`"testword"`** (case-insensitive substring match).
- [ ] 7. Full suite green via `scripts/verify.sh` (**exit 0, failed 0, skipped 0**).

## Verification mapping

| AC# | Test file | Test method | Notes |
|-----|-----------|-------------|-------|
| 1 | `PodWash/PodWashTests/SettingsStoreTests.swift` | `testFreshStoreMatchesPRDDefaultProfile` | 4 ON categories; mute; rate 1.0; auto toggles false |
| 2 | `PodWash/PodWashTests/SettingsStoreTests.swift` | `testCategoryToggleUpdatesTargetSet` | `"shit"`/`"fuck"` membership; count −4; reload retains |
| 3 | `PodWash/PodWashTests/SettingsStoreTests.swift` | `testCustomWordLifecycle` | `"xyzzy!"` → `"xyzzy"`; remove + reload |
| 4 | `PodWash/PodWashTests/SettingsStoreTests.swift` | `testDefaultsPersist` | skip + 2.0 + auto toggles true survive reload |
| 5 | `PodWash/PodWashUITests/SettingsUITests.swift` | `testCategoryToggleAccessibilityValue` | 2 taps; `"1"` ↔ `"0"` |
| 6 | `PodWash/PodWashUITests/SettingsUITests.swift` | `testCustomWordAppearsInList` | `customWordRow_0` label contains `testword` |
| 7 | — | — | Command-level: unfiltered `scripts/verify.sh` exit 0, failed 0, skipped 0 |

## Verification commands

```bash
# Fast inner loop (NOT sufficient for Done):
scripts/verify.sh -only-testing:PodWashTests/SettingsStoreTests -only-testing:PodWashUITests/SettingsUITests

# Done gate — FULL suite, zero failures, zero skips:
scripts/verify.sh
```

## Verification record (QA fills at Verify)

> Paste the `VERIFY RESULT:` line from the full-suite `scripts/verify.sh` run here.
> A slice without a recorded full-suite green artifact is not Done.

```
VERIFY RESULT: (pending)
```

## Plan review record (coordinator fills before downstream roles)

> Record readonly review outcomes before QA writes tests (ADR review) and before
> Engineer starts (test spec review). No record = next role must not spawn.
> See [`multitask-workflow.md`](../multitask-workflow.md) § Plan review gates.

```
ADR review: (pending)
Test spec review: (pending)
```

## Done gate

- [ ] Every AC mapped to a test; all rows in the mapping table filled
- [ ] **Full suite green:** unfiltered `scripts/verify.sh` exit 0, failed 0, skipped 0
- [ ] Verification record pasted above (exit code + counts + `.xcresult` path)
- [ ] Auto-commit made on green: `slice-13: <short description>` (push only when the user asks)

## Role artifacts

| Role | Gate | Artifact path |
|------|------|---------------|
| PM | Required | `docs/slices/slice-13-settings.md` (this file) |
| Architect | Required | `docs/adr/010-settings-word-lists.md` (category IDs, `SettingsStore` API, matcher seam) |
| UX | Required | `docs/slices/slice-13-settings-ux.md` (states, identifiers, UI scenarios) |
| QA | Required | `SettingsStoreTests.swift`, `SettingsUITests.swift` |
| Engineer | Required | `WordCategories`, `SettingsStore`, `SettingsView`, matcher wiring |
