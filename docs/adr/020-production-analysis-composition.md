# ADR-020 — Production analysis composition (model bundle + shell wiring)

| Field | Value |
|-------|-------|
| **Status** | Accepted |
| **Date** | 2026-07-11 |
| **Supersedes** | — (does **not** replace [ADR-003](003-asr-stack-choice.md) / [ADR-005](005-analysis-pipeline.md) / [ADR-006](006-playback-integration.md) / [ADR-015](015-app-shell-navigation.md); composes them at the installable shell) |
| **Builds on** | [ADR-000](000-foundations.md) §3 (download-before-clean), §6 (`verify.sh`); [ADR-003](003-asr-stack-choice.md) (`openai_whisper-tiny.en` pin, `cpuOnly`); [ADR-005](005-analysis-pipeline.md) (`AnalysisPipeline`, `IntervalCache`); [ADR-006](006-playback-integration.md) (`EpisodeAnalyzing`, `PlaybackCoordinator.preparePlayback`); [ADR-008](008-episode-downloads.md) (local-file gate); [ADR-010](010-settings-word-lists.md) (`activeNormalizedTargetSet()`, `censorAction()`); [ADR-013](013-segmentation-integration.md) (`UnrelatedContentOptions`); [ADR-015](015-app-shell-navigation.md) (`AppShellModel.playEpisode`, fixture vs production) |
| **Slice** | [slice-24-production-analysis-wiring.md](../slices/slice-24-production-analysis-wiring.md) |

## Context

Slice 23 shipped the production shell (`AppShellModel` / `AppShellView`) but left
analysis on the UITest stub:

- `AppShellModel.playEpisode` constructs `PlaybackCoordinator(pipeline:
  InstantEpisodeAnalyzer(), …)` and calls `preparePlayback(…, targetWords: [])`.
- `LibraryPodcastDetailView` constructs `AnalysisUIViewModel(analyzer:
  InstantEpisodeAnalyzer(), …)`.

The verified cleaning stack (`AnalysisPipeline` → `IntervalCache` →
`preparePlayback` → `PlaybackEngine` mute mix) therefore never runs on the
installable path. Phone dogfood cannot mute profanity on downloaded episodes
until the composition root uses the real pipeline with Settings-derived targets
and a **bundled** WhisperKit model (no first-run HuggingFace download — OOS).

Product pins (slice, 2026-07-10): first play with cleaning on → analyze once →
cache; default profile via `SettingsStore.activeNormalizedTargetSet()`; default
action mute via `censorAction()`; local downloaded files only; keep Instant /
stepped analyzers for launch-argument fixtures only.

**Gap this ADR closes:** how the app target resolves the pinned model at runtime,
when production vs stub analyzers are chosen, how tests inject spies / transcripts
without live ASR, and how cleaning + local-file gates + Settings feed
`preparePlayback` from one shared analyzer.

## Decision

### 1. Module layout / file boundaries

| File | Target | Status | Responsibility |
|------|--------|--------|----------------|
| `PodWash/PodWash/WhisperModelLocator.swift` | app | **new** | Resolves the bundled `openai_whisper-tiny.en` folder; asserts the **3** required `.mlmodelc` subdirectories; throws / surfaces setup message when incomplete |
| `PodWash/PodWash/ProductionAnalyzerFactory.swift` | app | **new** | Builds production `AnalysisPipeline` (`WhisperKitASRTranscriber` + `IntervalCache`) or returns fixture stubs; **only** non-test factory for the shell |
| `PodWash/PodWash/AppShellModel.swift` | app | **changed** | Owns shared `episodeAnalyzer`; injectable test seam; cleaning + local-file gates; Settings → `preparePlayback` |
| `PodWash/PodWash/AppShellView.swift` | app | **changed** | `LibraryPodcastDetailView` takes `model.episodeAnalyzer` (not a fresh `InstantEpisodeAnalyzer`) |
| `PodWash/PodWash/CleaningToggleStore.swift` | app | **changed (additive)** | Podcast-scoped channel cleaning / unrelated lookups by `feedURL` so Library multi-sub play is correct (see §5) |
| `scripts/setup-asr-models.sh` | repo | **unchanged pin** | Still downloads into gitignored `Models/`; ADR documents the **build-phase copy** that follows |
| Xcode project build phase | app | **new** | Copy pinned model folder from `Models/` into app resources (see §2) |
| `PodWash/PodWashTests/ProductionAnalysisWiringTests.swift` | test | **new (QA)** | AC1–AC8; spy + injected transcript; no live WhisperKit |
| `PodWash/PodWashSlowTests/ProductionAnalysisSlowTests.swift` | slow | **optional (QA)** | Bundled-model live smoke; **not** a Done gate |

**Unchanged public contracts:** `EpisodeAnalyzing`, `AnalysisPipeline.analyze`,
`PlaybackCoordinator.preparePlayback` signatures, `WhisperKitASRTranscriber`
compute options API, matcher / interval math, download path layout (ADR-008).

**Do not** invent a first-run network model download, larger Whisper models, or
ANE compute retuning in this slice.

### 2. Model-in-bundle policy (build-phase copy)

**Choice: build-phase copy from gitignored `Models/`** after
`scripts/setup-asr-models.sh` — **not** a committed Core ML tree under
`PodWash/PodWash/Resources/`.

| Factor | Build-phase copy (chosen) | Committed Resources subset |
|--------|---------------------------|----------------------------|
| Repo size | Model stays gitignored | +~73–146 MB in git forever |
| Pin sync | Same folder `setup-asr-models.sh` already writes | Duplicate pin / drift risk |
| CI / release | Run setup before `xcodebuild`; fail loudly if missing | Always present after clone |
| Dogfood IPA | Model lands in `.app` via Copy Files / script phase | Same |

**Pinned identity (binding — identical to ADR-003 / setup script):**

| Field | Value |
|-------|-------|
| Model | `openai_whisper-tiny.en` |
| HF repo | `argmaxinc/whisperkit-coreml` |
| HF revision | `97a5bf9bbc74c7d9c12c755d04dea59e672e3808` |
| Source on disk | `Models/whisperkit-coreml/openai_whisper-tiny.en/` |
| Bundle resource name | `openai_whisper-tiny.en` (folder resource in the app target) |

**What to copy into the app bundle** (omit `.mlpackage` sources — runtime needs
compiled bundles only):

- `AudioEncoder.mlmodelc/`
- `TextDecoder.mlmodelc/`
- `MelSpectrogram.mlmodelc/`
- `config.json`
- `generation_config.json`

**IPA size estimate (measured on a local setup tree, 2026-07-11):** the three
`.mlmodelc` directories total **~73 MB** (AudioEncoder ~16 MB, TextDecoder ~57 MB,
MelSpectrogram ~0.4 MB). JSON configs are negligible. Full tree including
`.mlpackage` is ~146 MB — **do not** copy packages. Expect roughly **+70–80 MB**
IPA / `.app` growth for this model.

**Build phase contract:**

1. Developer / CI runs `scripts/setup-asr-models.sh` once (idempotent).
2. App target **Run Script** (or Copy Files) phase copies the folder above into
   the app’s resource bundle as `openai_whisper-tiny.en`.
3. If any of the three `.mlmodelc` directories is missing at build time, the script
   **fails the build** with a message citing `scripts/setup-asr-models.sh` and
   this ADR — never silently ship an empty model folder.
4. Fast suite AC1 (`testBundledWhisperModelFolderIsComplete`) resolves via
   `WhisperModelLocator` against the **app** bundle and **FAILS** (never
   `XCTSkip`) if incomplete, with the same setup citation.

**Out of scope:** first-run HuggingFace download UX, progress UI for model fetch,
Application Support one-shot unpack from a compressed archive (unnecessary if the
build phase copies `.mlmodelc` directly).

### 3. `WhisperModelLocator` + `ProductionAnalyzerFactory`

```swift
enum WhisperModelLocator {
    static let modelFolderResourceName = "openai_whisper-tiny.en"
    static let requiredMLModelcNames = [
        "AudioEncoder.mlmodelc",
        "TextDecoder.mlmodelc",
        "MelSpectrogram.mlmodelc",
    ]

    /// Returns the bundled model folder URL. Throws if the folder or any required
    /// `.mlmodelc` subdirectory is missing. Error / failure text MUST mention
    /// `scripts/setup-asr-models.sh` and ADR-020 (AC1).
    static func resolvedModelFolder(in bundle: Bundle = .main) throws -> URL

    /// Non-throwing completeness check for tests (AC1).
    static func requiredSubdirectories(in modelFolder: URL) -> [String: Bool]
}

enum ProductionAnalyzerFactory {
    /// Fixture shell / exclusive UITest modes → Instant (or stepped when a
    /// fixture helper already supplies one). Production → AnalysisPipeline.
    /// - Parameter fixtureLibraryMode: when non-nil, overrides ProcessInfo-backed
    ///   `FixtureLibrary.isEnabled` / `isEmptyEnabled` for analyzer choice (unit tests).
    ///   `nil` = read real launch args (production / UITest).
    static func makeAnalyzer(
        bundle: Bundle = .main,
        cacheBaseDirectory: URL? = nil,
        fixtureLibraryMode: Bool? = nil
    ) -> any EpisodeAnalyzing

    /// Explicit production path (AC2). Must not return InstantEpisodeAnalyzer.
    static func makeProductionPipeline(
        bundle: Bundle = .main,
        cacheBaseDirectory: URL? = nil
    ) throws -> AnalysisPipeline
}
```

**`makeProductionPipeline` algorithm:**

1. `let folder = try WhisperModelLocator.resolvedModelFolder(in: bundle)`.
2. `let transcriber = WhisperKitASRTranscriber(modelFolder: folder)` —
   **keep ADR-003 `cpuOnly`** for mel / audioEncoder / textDecoder (see §9).
3. `let cache = IntervalCache(baseDirectory: cacheBaseDirectory ??
   Application Support/IntervalCache/)`.
4. `return AnalysisPipeline(transcriber: transcriber, cache: cache)` (existing
   segmenter injection unchanged from ADR-013).

**`makeAnalyzer` branching:** compute
`effectiveFixtureLibrary = fixtureLibraryMode ?? (FixtureLibrary.isEnabled || FixtureLibrary.isEmptyEnabled)`.
If `effectiveFixtureLibrary` is true, **or** other **exclusive** RootView fixture
flags that must keep stubs (`FixtureAnalysis`, `FixtureAnalysisTimeline`,
`FixtureFeed`, `FixtureQueue`, `FixtureSkipOverride`, …) apply to the current
process, return `InstantEpisodeAnalyzer()` (timeline fixture continues to use
`FixtureAnalysisTimeline.makeSteppedAnalyzer()` in `RootView` — unchanged).
Otherwise return `try!` / failable production pipeline; production launch after a
successful model-bearing build must not hit Instant.

### 4. Fixture vs production branching

| Mode | Analyzer | `preparePlayback` / analyze |
|------|----------|-------------------------------|
| Production cold launch (no UITest fixture args) | `AnalysisPipeline` via factory | Real path when cleaning + local file (§5–§6) |
| `-UITestFixtureLibrary` / `-UITestFixtureLibraryEmpty` | `InstantEpisodeAnalyzer` | **Skip** analysis (AC8); play bundled fixture audio |
| Unit test with `fixtureLibraryModeForTesting = true` | Instant (or Instant via factory); play skips prepare | **Skip** `preparePlayback` even if cleaning is on (AC8) |
| Exclusive RootView fixtures (Feed / Analysis / Timeline / Queue / SkipOverride / …) | Existing Instant / stepped wiring in `RootView` | Unchanged — do **not** route through production factory |
| Unit tests (non-fixture override) | Injected `EpisodeAnalyzing` spy (or factory under test) | Injected transcript via seam (§5) |

**Why an injectable fixture-branch seam:** `FixtureLibrary.isEnabled` /
`isEmptyEnabled` read `ProcessInfo` launch arguments fixed at process start and
**cannot** be toggled per XCTest method. Injecting Instant via
`init(episodeAnalyzer:)` alone does **not** satisfy AC8 — the non-fixture play
path still calls `preparePlayback` when cleaning is on. Production and UITest
launches leave the override `nil` and continue to use real
`FixtureLibrary.isEnabled` / `isEmptyEnabled`.

Do not remove Instant / stepped types — they remain the deterministic UITest
doubles.

### 5. Injectable test seam (`AppShellModel`)

```swift
@MainActor @Observable
final class AppShellModel {
    /// Shared by play path and LibraryPodcastDetailView / AnalysisUIViewModel.
    private(set) var episodeAnalyzer: any EpisodeAnalyzing

    /// Test-only: forwarded to `preparePlayback` so AC4/AC5 avoid live ASR.
    /// Production leaves this `nil`.
    var injectedTranscriptForTesting: [TimedWord]? = nil

    /// Test-only override for downloads directory (local-file gate).
    var downloadsDirectoryForTesting: URL? = nil

    /// Test-only fixture-branch override (AC8).
    /// - `nil` (production / UITest): use `FixtureLibrary.isEnabled || isEmptyEnabled`
    /// - `true`: treat as Library fixture mode — Instant analyzer path **and**
    ///   **skip `preparePlayback`** regardless of cleaning (same as production
    ///   `-UITestFixtureLibrary` path today)
    /// - `false`: force non-fixture play path (analyze when cleaning + local file)
    ///
    /// Binding: mutating ProcessInfo launch args is not required and not supported
    /// for per-method unit tests.
    var fixtureLibraryModeForTesting: Bool? = nil

    /// Effective Library-fixture gate used by `playEpisode` and default analyzer choice.
    var isFixtureLibraryMode: Bool {
        fixtureLibraryModeForTesting
            ?? (FixtureLibrary.isEnabled || FixtureLibrary.isEmptyEnabled)
    }

    init(
        persistence: PersistenceController,
        remoteCommands: RemoteCommandCoordinator,
        episodeAnalyzer: (any EpisodeAnalyzing)? = nil,
        settingsStore: SettingsStore? = nil,  // optional inject for target-set pins
        fixtureLibraryModeForTesting: Bool? = nil
    )

    /// Factory used when `episodeAnalyzer` init arg is nil (AC2 / production).
    static func makeDefaultAnalyzer(
        fixtureLibraryMode: Bool? = nil
    ) -> any EpisodeAnalyzing {
        ProductionAnalyzerFactory.makeAnalyzer(
            fixtureLibraryMode: fixtureLibraryMode
        )
    }

    func playEpisode(_ episode: Episode, podcastTitle: String, feedURL: URL? = nil)
}
```

**AC mapping to the seam:**

| AC | Seam usage |
|----|------------|
| 1 | Call `WhisperModelLocator.resolvedModelFolder` / completeness helpers on app bundle |
| 2 | `ProductionAnalyzerFactory.makeProductionPipeline()` / `makeDefaultAnalyzer(fixtureLibraryMode: false)` → type or behavior **not** Instant |
| 3–7 | Construct `AppShellModel(…, episodeAnalyzer: spy)` with `fixtureLibraryModeForTesting = false` (or `nil` in a non-fixture process); configure cleaning + local vs remote URL; await prepare task; assert spy `analyze` count / `targetWords` / `cachedIntervals` |
| 4–5 | Set `injectedTranscriptForTesting` from `spec-section8.input.json`; assert intervals vs `e2e_intervals.json` (±0.0005 s) and mute ramp bounds (±0.001 s) |
| 8 | Set `fixtureLibraryModeForTesting = true` (do **not** rely on ProcessInfo). Use Instant (factory default or explicit Instant inject). Call `playEpisode` with cleaning **on** + local file; assert **no** `preparePlayback` / spy `analyze` count **== 0**, analyzer is Instant (or not production pipeline), `cachedIntervals.count == 0` |

**Spy shape (test target only — do not ship in app):**

```swift
final class EpisodeAnalyzeSpy: EpisodeAnalyzing, @unchecked Sendable {
    private(set) var analyzeCallCount = 0
    private(set) var lastTargetWords: Set<String> = []
    var intervalsToReturn: [CensorInterval] = []
    // Or wrap a real AnalysisPipeline with injectedTranscript forwarded.
}
```

For AC4’s golden path, prefer a spy that **delegates** to a real
`AnalysisPipeline` with an `ASRSpyTranscriber` / injected transcript so interval
math stays production code (same pattern as ADR-006 `PipelineAnalyzeSpy`), while
still recording call count and `targetWords`.

**Play orchestration (replaces Instant + empty targets):**

1. Resolve audio URL (`isFixtureLibraryMode` → `FixtureAudio`; else `PlaybackSourceResolver`).
2. Determine `isLocalFile` = URL is `file:` **and** file exists (downloaded path
   or test temp copy). Streaming / remote `http(s)` → **not** local.
3. Determine `cleaningApplies` =
   `cleaningStore.isEpisodeCleaningEnabled(episode.id)`
   **OR** channel cleaning for the episode’s podcast (`feedURL` / subscription
   lookup — see additive API below).
4. Create `PlaybackEngine` + `PlaybackCoordinator(pipeline: episodeAnalyzer, …)`.
5. If `isFixtureLibraryMode` → **do not** call `preparePlayback` (AC8),
   **regardless of cleaning** — same as today’s Library fixture path.
6. Else if `cleaningApplies && isLocalFile` → `Task` /
   awaitable prepare:
   ```swift
   try await coordinator.preparePlayback(
       episode: EpisodeIdentity(id: episode.id),
       audioURL: audioURL,
       targetWords: settingsStore.activeNormalizedTargetSet(),
       action: settingsStore.censorAction(),
       unrelatedContent: UnrelatedContentOptions(
           enabled: settingsStore.unrelatedContentEnabled
               && cleaningStore.isChannelUnrelatedContentEnabled(forFeedURL:),
           action: settingsStore.unrelatedCensorAction()
       ),
       injectedTranscript: injectedTranscriptForTesting
   )
   ```
7. Else (cleaning off **or** streaming-only) → **do not** call `preparePlayback`
   (AC3, AC7); leave `cachedIntervals` empty.
8. Bind remote commands / queue / mini-player as today (ADR-015).

**Additive `CleaningToggleStore` (multi-sub correctness):**

```swift
func isChannelCleaningEnabled(forFeedURL feedURL: URL) -> Bool
func isChannelUnrelatedContentEnabled(forFeedURL feedURL: URL) -> Bool
```

`playEpisode` must use the episode’s show `feedURL` (pass from
`LibraryPodcastDetailView` / CarPlay lookup), not “first podcast in the store”
(ADR-015 first-podcast deferral is insufficient once Library has multiple
subscriptions).

### 6. Cleaning + local-file gates (AC3, AC6, AC7)

| Condition | Analyze / `preparePlayback` |
|-----------|-----------------------------|
| Episode cleaning **off** and channel cleaning **off** | Skip (AC3) |
| Episode cleaning **on**, local file | Run (AC4) |
| Channel cleaning **on**, episode cleaning **off**, local file | Run (AC6) |
| Cleaning on, audio is streaming-only remote URL (no download on disk) | Skip (AC7) — ADR-000 §3 / ADR-008 |

Local-file test stand-in: copy `sine-300hz-5s.wav` (or any bundled `.wav`) into an
injectable downloads directory at
`DownloadPaths.localFileURL(episodeID:downloadsDirectory:)` so the resolver
returns a `file:` URL without network.

### 7. Settings wiring

| Input | Source | `preparePlayback` argument |
|-------|--------|----------------------------|
| Target words | `settingsStore.activeNormalizedTargetSet()` | `targetWords` |
| Profanity action | `settingsStore.censorAction()` | `action` |
| Unrelated options | global `unrelatedContentEnabled` ∧ channel unrelated flag; `unrelatedCensorAction()` | `unrelatedContent` |

Do **not** hardcode `{ "shit", "damn" }` in production. Tests may pin a
`SettingsStore` (injected UserDefaults) whose active set equals that subset when
asserting AC4 set-equality against the spy’s recorded `targetWords`.

### 8. Shared analyzer (shell + detail UI)

`AppShellModel` owns one `episodeAnalyzer` instance for the session.

- `playEpisode` always constructs `PlaybackCoordinator(pipeline: episodeAnalyzer, …)`.
- `LibraryPodcastDetailView` initializes
  `AnalysisUIViewModel(…, analyzer: model.episodeAnalyzer, …)` —
  **never** a second `InstantEpisodeAnalyzer()` while play uses production.

Exclusive fixture shells in `RootView` keep their local Instant / stepped
instances (unchanged). Only the production / Library-fixture `AppShellView`
path shares the model’s analyzer.

### 9. Compute on device (this slice)

**Keep ADR-003 `cpuOnly`** for `WhisperKitASRTranscriber` used by the production
factory on **both** simulator and device for Slice 24.

Rationale: one code path; simulator correctness already proven only under
`cpuOnly`; larger models / ANE tuning are explicitly **out of scope**. A future
ADR may allow ANE on device for `tiny.en` or larger models after a measured
spike — **not** this slice.

### 10. Empirical / verification notes

| Claim | Validation |
|-------|------------|
| Composition gates, Settings targets, interval bounds, mute ramps | Fast `ProductionAnalysisWiringTests` — injected transcript + spy; offline mix inspector (ADR-000 §2 / Slice 08) |
| Bundled model completeness | AC1 structural assert on app-bundle folder |
| Library fixture skip of prepare (AC8) | Unit test sets `fixtureLibraryModeForTesting = true` — **not** ProcessInfo mutation |
| Live WhisperKit on device / full episodes | **Optional** slow suite only; **not** a Done gate |
| Phone dogfood mute quality | **User validation after green** — never a slice Done criterion |
| Done | Unfiltered `scripts/verify.sh` exit 0, failed 0, skipped 0 (ADR-000 §6) |

**CI / local verify prerequisite:** once the app-target build-phase model copy
exists, run `scripts/setup-asr-models.sh` **before** `scripts/verify.sh` (and
before any `xcodebuild` that builds the PodWash app for tests). Otherwise the
copy phase fails the build and/or AC1 fails. Document this in CI job steps and
Engineer handoff — do not rely on an already-populated local `Models/` tree.

No new audio/ASR framework spike is required beyond ADR-003 measurements: this
slice wires existing types. Build-phase copy size (~73 MB `.mlmodelc`) is
measured above for IPA planning.

### 11. Cross-cutting impact

| Area | Impact |
|------|--------|
| `AppShellModel` / `AppShellView` | Central wiring change — serialize with other shell editors |
| IPA / CI | +~70–80 MB; **run `setup-asr-models.sh` before verify/xcodebuild** once copy phase exists |
| `RootView` exclusive fixtures | Unchanged stub analyzers |
| CarPlay play path | Uses same `AppShellModel.playEpisode` gates once feedURL is passed |
| Matcher / cache fingerprint | Unchanged — Settings set flows in as `targetWords` |

### 12. Out of scope (binding)

- First-run HuggingFace download or model-progress UI
- Larger Whisper models / ANE compute retuning
- Streaming cleaned playback
- Changing word lists or matching algorithm
- New analysis progress UI (reuse Slices 09/20)
- Manual listening or physical-device Done gate
- Live WhisperKit in the **fast** suite

## Consequences

- Production play + detail analysis share one non-stub `EpisodeAnalyzing`
  instance when not in UITest fixture modes.
- Model availability is a **build/setup** concern (`setup-asr-models.sh` + copy
  phase), asserted by AC1 without network at runtime. **CI must run
  `scripts/setup-asr-models.sh` before `verify.sh`** once the build-phase copy
  is wired, or AC1 / the app build will fail.
- Fast Done gate stays free of live ASR via injection seams; phone dogfood is
  post-Done human validation.
- AC8 is unit-testable via `fixtureLibraryModeForTesting` without mutating
  ProcessInfo; Instant inject alone is insufficient — fixture mode also skips
  `preparePlayback` when cleaning is on.
- QA maps AC1–AC8 to `ProductionAnalysisWiringTests` against the APIs above;
  Engineer must not leave `LibraryPodcastDetailView` on Instant while play uses
  the real pipeline.
- Plan review (QA + PM) should confirm: build-phase copy (not committed
  Resources), `cpuOnly` retained, fixture Instant preserved for Library UITests,
  injectable fixture-branch + spy / transcript coverage for AC2–AC8 without
  weakening local-file or cleaning gates.
