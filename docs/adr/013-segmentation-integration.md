# ADR-013 — Segmentation integration: pipeline merge, cache, independent actions, skip override

| Field | Value |
|-------|-------|
| **Status** | Accepted |
| **Date** | 2026-07-10 |
| **Supersedes** | — (revises [ADR-006](006-playback-integration.md) §2 `applyCurrentSchedule` behavior only — see §3.5; does **not** replace ADR-006) |
| **Builds on** | [ADR-000](000-foundations.md) §2/§4; [ADR-002](002-interval-scheduler.md) skip landing `[end − 0.1, end]`; [ADR-005](005-analysis-pipeline.md) transcript injection + cache; [ADR-006](006-playback-integration.md) `PlaybackCoordinator` / `EpisodeAnalyzing`; [ADR-010](010-settings-word-lists.md) `SettingsStore`; [ADR-012](012-content-segmentation-approach.md) `ContentSegmenting` / `HeuristicContentSegmenter`; [ADR-007](007-persistence-core-data.md) / [ADR-009](009-queue-resume.md) `CDPodcast` / `CleaningToggleStore` |
| **Resolves** | Slice 19 — wire Differentiator 2 into analyze → cache → playback with off-by-default toggles, independent actions, and overridable skip |

## Context

Slice 18 proved `heuristic-cue-v1` behind `ContentSegmenting` (ADR-012). Slice 19
must ship the production path:

- Segment bounds persist through `AnalysisPipeline` → `IntervalCache` →
  `PlaybackCoordinator` / `IntervalScheduler`.
- Profanity and unrelated-content intervals carry **independent** `CensorAction`
  values (AC1: mute vs skip on the same schedule).
- Unrelated-content handling is **off by default** (global Settings + per-channel
  toggle); when off, **0** unrelated intervals reach `applySchedule` (AC2/AC5).
- Skip seeks land in `[end − 0.1 s, end]` (existing ADR-002); override seeks to
  `[start ± 0.05 s]` and a transient banner exposes tap-to-play (AC3/AC4).

Binding constraints from the slice:

- **AC1** — enabled path: ≥ 3 intervals; exactly 2 unrelated matching golden
  segments ±0.001 s; ≥ 1 profanity ±0.0005 s; independent actions; 2nd analyze
  → ASR spy **0** additional calls.
- **AC2** — default settings → 0 unrelated at scheduler; enabled → ≥ 2.
- **AC3** — skip `[2.0, 5.0]` → `currentTime ∈ [4.9, 5.0]` still playing;
  override → `currentTime ∈ [1.95, 2.05]` within 2.0 s.
- **AC4** — `-UITestFixtureSkipOverride`; banner `accessibilityValue` contains
  `"3"`; tap → elapsed in `[2.0, 5.0]`.
- **AC5** — fresh `SettingsStore` defaults; UI toggles `"0"`.
- **AC6** — full `scripts/verify.sh` green, skipped = 0.

ADR-006’s `applyCurrentSchedule` currently maps **every** cached bound to
`currentAction`, which would destroy independent segment actions. That mapping
must be revised for multi-source intervals without breaking Slice 08’s
profanity-only `setAction` contract.

## Decision

### 3.1 Module layout / file boundaries

| File | Target | Status | Responsibility |
|------|--------|--------|----------------|
| `PodWash/PodWash/IntervalBuilder.swift` | app | **changed** | Add `IntervalSource`; extend `CensorInterval` with `source` (default `.profanity`). `IntervalBuilder` continues to emit `.profanity` only. |
| `PodWash/PodWash/AnalysisPipeline.swift` | app | **changed** | Inject `ContentSegmenting`; merge segment intervals; filter/stamp on return; cache full union. |
| `PodWash/PodWash/IntervalCache.swift` | app | **changed (additive)** | Encode/decode `source` on intervals; optional cache-format version in fingerprint (§3.4). No change to `(episodeID, targetWords)` call sites’ public shape beyond fingerprint internals. |
| `PodWash/PodWash/EpisodeAnalyzing.swift` | app | **changed** | Extend `analyze` with unrelated-content options (default off / `.skip`) so spies and `InstantEpisodeAnalyzer` stay compilable. |
| `PodWash/PodWash/PlaybackCoordinator.swift` | app | **changed** | Stop blanket `currentAction` overwrite; filter unrelated by enablement; remap actions **by source**; expose skip-override wiring. |
| `PodWash/PodWash/PlaybackEngine.swift` | app | **changed (additive)** | Skip-override callback + per-interval override suppression after a skip fires / user overrides (§3.6). Public play/pause/seek surface unchanged. |
| `PodWash/PodWash/SettingsStore.swift` | app | **changed** | `unrelatedContentEnabled` (default `false`), `unrelatedContentAction` (default `.skip`). |
| `PodWash/PodWash/SettingsView.swift` | app | **changed** | `unrelatedContentToggle` / `unrelatedContentActionControl` accessibility contract. |
| `PodWash/PodWash/CleaningToggleStore.swift` (+ adapter / in-memory shim) | app | **changed** | Channel unrelated-content flag API. |
| `PodWash/PodWash/PodWash.xcdatamodeld` | app | **changed** | `CDPodcast.channelUnrelatedContentEnabled: Bool` default `NO` (lightweight add). |
| `PodWash/PodWash/PodcastDetailView.swift` | app | **changed** | `channelUnrelatedContentToggle` (default off). |
| `PodWash/PodWash/SkipOverrideBanner.swift` (or player chrome host) | app | **new** | Transient banner; identifier `skipOverrideBanner`. UX owns copy/layout (`slice-19-ux.md`). |
| `PodWash/PodWash/FixtureSkipOverride.swift` | app | **new** | `-UITestFixtureSkipOverride` routing: 10.0 s local asset + stubbed unrelated skip `[2.0, 5.0]`. |
| `ContentSegmenting.swift` / `HeuristicContentSegmenter.swift` | app | **unchanged** | Consume only; no threshold retune (slice OOS). |
| `PodWash/PodWashTests/SegmentationIntegrationTests.swift` | test | **new (QA)** | AC1–AC3, AC5 unit. |
| `PodWash/PodWashUITests/SkipOverrideUITests.swift` | test | **new (QA)** | AC4 + AC5 channel toggle. |
| Fixtures under `Fixtures/segmentation/` | test | **new (QA)** | `integration_transcript.json`, `integration_golden.json`; provenance note. |

**Unchanged public math:** `WordMatcher`, `IntervalBuilder` padding/merge,
`IntervalScheduler.makeAudioMix` / skip landing tolerances, ADR-012 segmenter
thresholds, Core Data episode/queue entities beyond the one Bool on `CDPodcast`.

### 3.2 Key types — `IntervalSource` + `CensorInterval`

```swift
/// Discriminant so profanity and unrelated-content intervals keep independent
/// actions and can be filtered without re-running ASR.
enum IntervalSource: String, Codable, Equatable, Sendable {
    case profanity
    case unrelatedContent
}

struct CensorInterval: Codable, Equatable {
    var start: Double
    var end: Double
    var action: CensorAction
    var source: IntervalSource

    init(
        start: Double,
        end: Double,
        action: CensorAction = .mute,
        source: IntervalSource = .profanity
    ) { ... }
}
```

**Codable compatibility:** missing `source` key decodes as `.profanity` so older
cache files from Slices 07–08 remain valid. New writes always emit `source`.

**Invariants**

- `IntervalBuilder.buildIntervals` always sets `source: .profanity`.
- Segment mapping always sets `source: .unrelatedContent`.
- Sort-and-merge inside `IntervalBuilder` remains **profanity-only** (spec §6).
  Unrelated spans are **not** fed through `IntervalBuilder.merge` with profanity
  intervals — sources stay separate even if times overlap (fixture places
  profanity in an on-topic region; overlap handling is best-effort, not a
  product guarantee this slice).

### 3.3 Pipeline merge algorithm

```swift
struct UnrelatedContentOptions: Equatable, Sendable {
    var enabled: Bool          // default false
    var action: CensorAction   // default .skip
}

final class AnalysisPipeline: @unchecked Sendable {
    private let transcriber: any ASRTranscribing
    private let cache: IntervalCache
    private let segmenter: any ContentSegmenting

    init(
        transcriber: any ASRTranscribing,
        cache: IntervalCache,
        segmenter: any ContentSegmenting = HeuristicContentSegmenter()
    )

    func analyze(
        episode: EpisodeIdentity,
        audioURL: URL,
        targetWords: Set<String>,
        injectedTranscript: [TimedWord]? = nil,
        profanityAction: CensorAction = .mute,
        unrelatedContent: UnrelatedContentOptions = .init(enabled: false, action: .skip)
    ) async throws -> [CensorInterval]
}
```

**Algorithm** (both overloads / `EpisodeAnalyzing` converge here):

1. Compute target fingerprint (ADR-005). Cache key remains
   `(episodeID, targetFingerprint)` plus the format token in §3.4.
2. **Cache load:** if a full union file exists → decode `[CensorInterval]`
   (includes both sources when previously analyzed). **Do not** call ASR.
3. **Cache miss:**
   1. Obtain transcript (injection or `transcriber.transcribe`).
   2. `profanity = IntervalBuilder.buildIntervals(...)` then stamp
      `action = profanityAction`, `source = .profanity`.
   3. `segments = segmenter.segments(in: transcript)` → map each
      `ContentSegment` → `CensorInterval(start:end:action:unrelatedContent.action,
      source: .unrelatedContent)`. **Always run the segmenter on miss** (heuristic
      is cheap; analyze-once stores both classes).
   4. `union = profanity + segmentIntervals` (concatenate; sort by `start` for
      stable cache bytes; **no cross-source merge**).
   5. `cache.store(union, ...)`.
4. **Return projection:** start from cached/fresh union; remap actions by source
   (`profanity` → `profanityAction`, `unrelatedContent` → `unrelatedContent.action`);
   if `unrelatedContent.enabled == false`, **drop** all `.unrelatedContent`
   intervals before return.

**Why always segment on miss, filter on return**

| Concern | Choice |
|---------|--------|
| AC1 cache hit | Same `(episodeID, targetWords)` file; 2nd call skips ASR |
| AC2 off-by-default | Return projection drops unrelated; coordinator also filters (§3.5) |
| Toggle on later | Same cache file; re-analyze with `enabled: true` returns segments without ASR |
| Action change | Remap on return / at playback — no re-ASR (mirrors ADR-006) |

`EpisodeAnalyzing` and `InstantEpisodeAnalyzer` gain the same defaulted
`profanityAction` / `unrelatedContent` parameters so existing call sites compile
unchanged (defaults = mute + unrelated off).

**Effective enablement at app call sites** (not inside the segmenter):

```text
effectiveUnrelated =
  settings.unrelatedContentEnabled
  && cleaningStore.isChannelUnrelatedContentEnabled
```

Pass `UnrelatedContentOptions(enabled: effectiveUnrelated,
action: settings.unrelatedContentAction mapped to CensorAction)` into
`analyze` / `preparePlayback`. Unit tests that only exercise Settings may pass
`enabled:` directly; channel gating is asserted in UI/store tests (AC5).

### 3.4 Cache key / fingerprint

**Public load/store signatures stay** `episodeID` + `targetWords` (ADR-005).

**Internal file name** adds a format token so Slice 19’s sourced intervals do not
collide with pre-source JSON if a hash ever differed only by payload shape:

```text
fingerprintMaterial = targetFingerprint + "\n" + "interval-format:v2"
file = {episodeID}__{sha256(fingerprintMaterial)}.json
```

- `interval-format:v1` = legacy unsourced arrays (treated as all `.profanity` on
  decode if ever read); **v2** = sourced union including unrelated spans.
- Changing `HeuristicContentSegmenter.approachIdentifier` in a **future** quality
  slice should bump a `seg-approach:` token into the material (not required this
  slice — approach is frozen at `heuristic-cue-v1`).
- **Do not** put `unrelatedContent.enabled` or actions into the cache key —
  enablement is a return/playback filter; actions are remapped.

### 3.5 PlaybackCoordinator — preserve actions by source

Revises ADR-006 §2 `applyCurrentSchedule` only:

```swift
@MainActor
final class PlaybackCoordinator {
    private(set) var cachedIntervals: [CensorInterval] = []  // full union from analyze
    private(set) var currentAction: CensorAction = .mute     // profanity only
    private(set) var unrelatedContentEnabled: Bool = false
    private(set) var unrelatedContentAction: CensorAction = .skip

    func preparePlayback(
        episode: EpisodeIdentity,
        audioURL: URL,
        targetWords: Set<String>,
        action: CensorAction = .mute,
        unrelatedContent: UnrelatedContentOptions = .init(enabled: false, action: .skip),
        injectedTranscript: [TimedWord]? = nil
    ) async throws

    /// Remaps **profanity** intervals only. Does not call analyze.
    func setAction(_ action: CensorAction) async

    /// Remaps **unrelatedContent** intervals only. Does not call analyze.
    func setUnrelatedContentAction(_ action: CensorAction) async

    func setUnrelatedContentEnabled(_ enabled: Bool) async  // filter + re-apply; no analyze
}
```

**`preparePlayback`:**

1. `cachedIntervals = try await pipeline.analyze(..., profanityAction: action,
   unrelatedContent: unrelatedContent)` — store the **returned** list (already
   filtered if disabled). For AC2 contrast tests that need the full union in
   memory while toggling enablement without re-analyze, coordinator may request
   analyze with `enabled: true` once and filter locally via
   `setUnrelatedContentEnabled` — **preferred production path:** pass effective
   options into analyze so the returned cache projection matches the schedule.
2. Store `currentAction`, `unrelatedContentEnabled`, `unrelatedContentAction`.
3. `applyCurrentSchedule()`.

**`applyCurrentSchedule` (replacement):**

```text
scheduled = cachedIntervals
  .filter { $0.source != .unrelatedContent || unrelatedContentEnabled }
  .map { interval in
      switch interval.source {
      case .profanity:
        return CensorInterval(..., action: currentAction, source: .profanity)
      case .unrelatedContent:
        return CensorInterval(..., action: unrelatedContentAction, source: .unrelatedContent)
      }
  }
engine.applySchedule(IntervalSchedule(intervals: scheduled))
```

**Slice 08 compatibility:** when no unrelated intervals are present (or enabled is
false), behavior matches ADR-006 — all scheduled intervals use `currentAction`.

Wire `PlaybackEngine.onUnrelatedSkip` (or equivalent) to a coordinator/UI
callback that presents the banner (§3.6 / UX spec).

### 3.6 Skip override seam (`PlaybackEngine`)

Existing skip path (ADR-002) is unchanged for landing:
`skipSeek` → `currentTime ∈ [end − 0.1, end]`, `timeControlStatus` stays
`.playing`.

**Additive API:**

```swift
extension PlaybackEngine {
    /// Fired after an unrelated-content `.skip` boundary seek completes.
    /// `skippedSeconds` = end − start (for banner accessibilityValue rounding).
    var onUnrelatedContentSkip: ((CensorInterval, Double) -> Void)?

    /// Seek to interval.start (tolerance → [start ± 0.05]) and suppress that
    /// interval’s skip until playback passes interval.end (or schedule re-applied).
    func overrideUnrelatedContentSkip(_ interval: CensorInterval)
}
```

**Rules**

1. Invoke `onUnrelatedContentSkip` only when the fired skip interval has
   `source == .unrelatedContent` (profanity skips do not show the Differentiator 2
   banner).
2. `overrideUnrelatedContentSkip` seeks with tight tolerances so AC3’s
   `[start ± 0.05]` holds; keeps `.playing`.
3. **Suppression:** add the overridden interval’s identity `(start, end, source)`
   to an internal `overriddenSkipKeys` set consulted by `handleSkipBoundary` so
   the player does not immediately re-skip the same span. Clear a key when
   `currentTime >= end` or on `applySchedule` rebuild (full reset of override set
   on schedule replace is acceptable and simplest).
4. Banner `accessibilityValue` = `String(Int((end - start).rounded()))` (e.g. 3.0
   → `"3"`); UX may show friendlier copy — value contract is numeric string.

**UITest fixture (`-UITestFixtureSkipOverride`):**

- Local **10.0 s** sine (or speech) — no network/ASR.
- Stub schedule: one unrelated `.skip` interval `[2.0, 5.0]` (`source:
  .unrelatedContent`).
- Root routes to a minimal player hosting `skipOverrideBanner`.
- Parallelization off (Slice 03/13 precedent).

### 3.7 Settings + per-channel toggles

**`SettingsStore` (UserDefaults, ADR-010 pattern):**

| Property | Fresh default | Accessibility |
|----------|---------------|---------------|
| `unrelatedContentEnabled: Bool` | `false` | `unrelatedContentToggle` → `"1"` / `"0"` |
| `unrelatedContentAction: SettingsCleaningAction` | `.skip` | `unrelatedContentActionControl` → `"skip"` / `"mute"` |

Keys under `podwash.settings.*`; include in `Keys.all` / fixture clear helpers.

**`CleaningToggleStore` + Core Data:**

| API | Persistence | Default |
|-----|-------------|---------|
| `isChannelUnrelatedContentEnabled` / `setChannelUnrelatedContent(_:)` | `CDPodcast.channelUnrelatedContentEnabled` | `false` |

UI: `channelUnrelatedContentToggle` on `PodcastDetailView` (sibling of
`channelCleaningToggle`). Fresh install / new podcast row →
`accessibilityValue == "0"`.

Lightweight model attribute add with default `NO` — same single-model MVP
discipline as ADR-009 (no multi-version migration pack required unless Engineer
hits a store incompatibility; then add a versioned model following ADR-007).

### 3.8 Verification architecture

| AC | Mechanism |
|----|-----------|
| 1 | Injected `integration_transcript.json`; golden bounds; ASR spy; dual actions |
| 2 | `preparePlayback` / schedule spy; default vs enabled contrast |
| 3 | `PlaybackEngine` + temp `sine-300hz-5s.wav`; skip + `overrideUnrelatedContentSkip` |
| 4 | UITest fixture launch arg; banner identifier + tap |
| 5 | Isolated `UserDefaults`; fixture settings + podcast detail toggles |
| 6 | Unfiltered `scripts/verify.sh` |

No new slow / WhisperKit path. Segmenter quality remains frozen at ADR-012
artifact — this slice does **not** re-benchmark precision/recall.

### 3.9 Rejected alternatives

| Alternative | Why rejected |
|-------------|--------------|
| Blanket `currentAction` overwrite (ADR-006 as-is) | Breaks independent mute/skip (AC1) |
| Separate cache files per source | Extra invalidation surface; analyze-once wants one union |
| Put `enabled` in cache key | Forces ASR on every toggle; conflicts with AC1 cache-hit intent |
| Cross-source IntervalBuilder.merge | Would collapse profanity into long segment spans and lose discriminant |
| Override without skip suppression | Immediate re-skip; AC3/AC4 fail |
| Banner for all `.skip` (including profanity) | Out of PRD §4 Differentiator 2 scope; short word skips are noisy |
| Retune `HeuristicContentSegmenter` | Explicitly OOS; ADR-012 frozen |

## Empirical validation

No new opaque framework spike. Claims reuse measured/prior art:

| Claim | Evidence |
|-------|----------|
| Skip lands in `[end − 0.1, end]`, stays playing | ADR-002 AC4 / engine `skipSeek` |
| Mute mix / scheduler consume `[CensorInterval]` | ADR-002 / ADR-006 |
| Segment bounds from `[TimedWord]` | ADR-012 committed benchmark (`heuristic-cue-v1`) |
| Override seek ±0.05 s | Same `AVPlayer.seek` tolerance pattern as ADR-001/002; asserted in AC3 |
| Settings persistence | ADR-010 injectable `UserDefaults` |
| Banner / toggles | UITest identifiers only — no perceptual gate |

QA may write tests directly against this ADR; Engineer implements to the seams
above.

## Cross-cutting impact

| Area | Impact |
|------|--------|
| `CensorInterval` Codable | **Additive** `source` — all interval JSON readers must tolerate the field; default `.profanity` |
| `PlaybackCoordinator.applyCurrentSchedule` | **Behavior change** vs ADR-006 blanket remap — document call-site awareness |
| `EpisodeAnalyzing.analyze` signature | **Additive** defaulted params — update spies/`InstantEpisodeAnalyzer` |
| `PlaybackEngine` | Additive callback + override; lock-screen / CarPlay banner surfacing **OOS** (Slices 14/15) |
| `TimedWord` / matcher math | **None** |
| Parallel slices 20/22/23 | Serialize on `PodcastDetailView` / Settings / player chrome if concurrent; interval model change is shared — prefer this slice landing first on those types |
| Slice 16 beep/quack | Untouched |
| Legal ship gate | Unchanged — attorney review pre-launch, not factory Done |

## Benchmark results

Filled from the committed Slice 18 execution-evidence artifact
`PodWash/PodWashTests/Fixtures/segmentation/segmentation-benchmark-results.json`
(frozen — this slice does **not** re-benchmark precision/recall). Values match
the artifact / recomputed IoU score within ±0.001:

| Field | Value |
|-------|-------|
| **approach** | `heuristic-cue-v1` |
| **precision** | 1.000 |
| **recall** | 1.000 |
| **segmentCount** | 2 |
| **durationSeconds / inferenceSeconds** | 0.022 / 0.022 |

**AC1 segment pin** (`integration_golden.json` ↔ artifact `segments`, ±0.001 s):

| # | start | end |
|---|-------|-----|
| 1 | 14.130 | 27.510 |
| 2 | 54.450 | 65.600 |

Profanity golden (hand-computed, ±0.0005 s asserts): **41.500–41.950**.

## Consequences

- Engineer implements sourced intervals, pipeline injection, settings/channel
  toggles, coordinator-by-source mapping, and skip-override seam **after** QA
  test spec + Architect test-spec review.
- UX authors `docs/slices/slice-19-ux.md` for banner states and toggle placement.
- ADR-012 remains the segmenter authority; ADR-005 cache identity gains only the
  `interval-format:v2` material token; ADR-006’s prepare/setAction story stands
  for profanity with the §3.5 remap revision.
- Dark-factory Done = ACs 1–6 green via `scripts/verify.sh` (skipped = 0); no
  listening session.
