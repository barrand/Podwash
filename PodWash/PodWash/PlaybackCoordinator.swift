//
//  PlaybackCoordinator.swift
//  PodWash
//
//  Slice 08 — Wires cached/pipeline intervals into PlaybackEngine with a swappable
//  action setting (ADR-006). Slice 19 remaps actions by IntervalSource (ADR-013 §3.5).
//  Slice 16 — mute overlay via OverlayEngine (ADR-017).
//

import Foundation

/// Wires cached/pipeline intervals into the player with swappable per-source actions.
@MainActor
final class PlaybackCoordinator {

    /// `nonisolated(unsafe)`: released from `nonisolated deinit` without a MainActor hop
    /// (existentials of progress-handler owners otherwise crash boxed destroy).
    nonisolated(unsafe) private var pipeline: any EpisodeAnalyzing
    private let engine: PlaybackEngine
    private let settingsStore: SettingsStore?
    private let overlayEngine: OverlayEngine

    private(set) var cachedIntervals: [CensorInterval] = []
    /// Full analyze union (for timeline ad buckets independent of unrelated enablement).
    private(set) var lastAnalysisUnion: [CensorInterval] = []
    private(set) var currentAction: CensorAction = .mute
    private(set) var unrelatedContentEnabled: Bool = false
    private(set) var unrelatedContentAction: CensorAction = .skip
    /// Progressive prepare: true after first playable chunk (ADR-021 §4).
    private(set) var canStartPlayback: Bool = false
    /// Progressive prepare: latest chunk frontier in seconds.
    private(set) var processedEnd: Double = 0

    /// Intervals last projected onto `PlaybackEngine` (post enablement / action remap).
    var appliedPlaybackIntervals: [CensorInterval] {
        lastScheduledIntervals
    }

    /// Serializes progressive partial schedule applies (task-022 intro catch-up race).
    private var partialApplyChain: Task<Void, Never>?

    init(
        pipeline: any EpisodeAnalyzing,
        engine: PlaybackEngine,
        settingsStore: SettingsStore? = nil,
        eventRecorder: (any OverlayEventRecording)? = nil,
        overlayAssetBundle: Bundle = .main
    ) {
        self.pipeline = pipeline
        self.engine = engine
        self.settingsStore = settingsStore
        self.overlayEngine = OverlayEngine(
            player: engine.avPlayer,
            eventRecorder: eventRecorder,
            assetBundle: overlayAssetBundle
        )

        engine.onSeekCompleted = { [weak self] time in
            self?.overlayEngine.handleSeekCompleted(currentTime: time)
        }
    }

    /// Forwards `PlaybackEngine.onUnrelatedContentSkip` for banner / UI wiring (ADR-013 §3.5–3.6).
    var onUnrelatedContentSkip: ((CensorInterval, Double) -> Void)? {
        get { engine.onUnrelatedContentSkip }
        set { engine.onUnrelatedContentSkip = newValue }
    }

    /// Seek to the skipped unrelated segment start and suppress re-skip (ADR-013 §3.6).
    func overrideUnrelatedContentSkip(_ interval: CensorInterval) {
        engine.overrideUnrelatedContentSkip(interval)
    }

    /// Re-applies schedule from reconciled intervals without re-running analyze (task-019).
    func applyReconciledIntervals(_ intervals: [CensorInterval]) async {
        cachedIntervals = intervals
        await applySchedule(intervals: intervals)
    }

    /// Runs `analyze` once (cache hit or miss), applies schedule, then publishes bounds.
    /// `cachedIntervals` is assigned **after** the mix is applied so observers waiting on
    /// interval count (Slice 24 AC5) do not race ahead of a nil `audioMix`.
    func preparePlayback(
        episode: EpisodeIdentity,
        audioURL: URL,
        targetWords: Set<String>,
        action: CensorAction = .mute,
        unrelatedContent: UnrelatedContentOptions = UnrelatedContentOptions(),
        injectedTranscript: [TimedWord]? = nil
    ) async throws {
        canStartPlayback = false
        processedEnd = 0
        let intervals = try await pipeline.analyze(
            episode: episode,
            audioURL: audioURL,
            targetWords: targetWords,
            injectedTranscript: injectedTranscript,
            profanityAction: action,
            unrelatedContent: unrelatedContent
        )
        currentAction = action
        unrelatedContentEnabled = unrelatedContent.enabled
        unrelatedContentAction = unrelatedContent.action
        if let analysisPipeline = pipeline as? AnalysisPipeline {
            lastAnalysisUnion = analysisPipeline.lastAnalysisUnion
        } else {
            lastAnalysisUnion = Self.analysisUnion(from: pipeline, projected: intervals)
        }
        await applySchedule(intervals: intervals)
        cachedIntervals = intervals
        processedEnd = max(processedEnd, intervals.map(\.end).max() ?? 0)
        canStartPlayback = true
    }

    /// Cold progressive path: applies partial schedules as chunks complete;
    /// sets `canStartPlayback` after the first chunk without waiting for terminal analyze.
    func preparePlaybackProgressive(
        episode: EpisodeIdentity,
        audioURL: URL,
        targetWords: Set<String>,
        action: CensorAction = .mute,
        unrelatedContent: UnrelatedContentOptions = UnrelatedContentOptions(),
        injectedTranscript: [TimedWord]? = nil,
        onChunkReady: (@MainActor () -> Void)? = nil
    ) async throws {
        canStartPlayback = false
        processedEnd = 0
        cachedIntervals = []
        currentAction = action
        unrelatedContentEnabled = unrelatedContent.enabled
        unrelatedContentAction = unrelatedContent.action

        let chunkReadyGate = OnceFlag()
        partialApplyChain = nil
        let installation = installPartialIntervalsHandler { [weak self] intervals, snapshot in
            MainActor.assumeIsolated {
                guard let self else { return }
                let previous = self.partialApplyChain
                self.partialApplyChain = Task { @MainActor in
                    await previous?.value
                    await self.handleProgressivePartial(
                        intervals: intervals,
                        snapshot: snapshot,
                        chunkReadyGate: chunkReadyGate,
                        onChunkReady: onChunkReady
                    )
                }
            }
        }
        defer {
            installation.restore()
            partialApplyChain = nil
        }

        let intervals = try await pipeline.analyze(
            episode: episode,
            audioURL: audioURL,
            targetWords: targetWords,
            injectedTranscript: injectedTranscript,
            profanityAction: action,
            unrelatedContent: unrelatedContent
        )
        // Wait for chained partial applies before terminal schedule (task-022).
        await partialApplyChain?.value
        if let analysisPipeline = pipeline as? AnalysisPipeline {
            lastAnalysisUnion = analysisPipeline.lastAnalysisUnion
        } else {
            lastAnalysisUnion = Self.analysisUnion(from: pipeline, projected: intervals)
        }
        await applySchedule(intervals: intervals)
        cachedIntervals = intervals
        if snapshotProcessedEndHint(from: intervals) > processedEnd {
            processedEnd = snapshotProcessedEndHint(from: intervals)
        }
        if !canStartPlayback {
            canStartPlayback = true
            if chunkReadyGate.mark() {
                onChunkReady?()
            }
        }
    }

    /// Installs `onPartialIntervals` on concrete analyzer types (same pattern as
    /// `AnalysisProgressRelay`) so the protocol-extension no-op setter cannot
    /// swallow progressive callbacks through an `any EpisodeAnalyzing` existential.
    private func installPartialIntervalsHandler(
        _ handler: @escaping AnalysisPartialIntervalsHandler
    ) -> PartialHandlerInstallation {
        if let analysisPipeline = pipeline as? AnalysisPipeline {
            let previous = analysisPipeline.onPartialIntervals
            analysisPipeline.onPartialIntervals = { intervals, snapshot in
                previous?(intervals, snapshot)
                handler(intervals, snapshot)
            }
            return PartialHandlerInstallation {
                analysisPipeline.onPartialIntervals = previous
            }
        }
        if let stepped = pipeline as? SteppedEpisodeAnalyzer {
            let previous = stepped.onPartialIntervals
            stepped.onPartialIntervals = { intervals, snapshot in
                previous?(intervals, snapshot)
                handler(intervals, snapshot)
            }
            return PartialHandlerInstallation {
                stepped.onPartialIntervals = previous
            }
        }
        if let instant = pipeline as? InstantEpisodeAnalyzer {
            let previous = instant.onPartialIntervals
            instant.onPartialIntervals = { intervals, snapshot in
                previous?(intervals, snapshot)
                handler(intervals, snapshot)
            }
            return PartialHandlerInstallation {
                instant.onPartialIntervals = previous
            }
        }
        // Test doubles with a real stored property (e.g. ProgressiveSteppedTestAnalyzer).
        let previous = pipeline.onPartialIntervals
        pipeline.onPartialIntervals = { intervals, snapshot in
            previous?(intervals, snapshot)
            handler(intervals, snapshot)
        }
        return PartialHandlerInstallation { [weak self] in
            self?.pipeline.onPartialIntervals = previous
        }
    }

    private func handleProgressivePartial(
        intervals: [CensorInterval],
        snapshot: AnalysisProgressSnapshot,
        chunkReadyGate: OnceFlag,
        onChunkReady: (@MainActor () -> Void)?
    ) async {
        processedEnd = snapshot.processedEnd
        cachedIntervals = intervals
        if let pipeline = pipeline as? AnalysisPipeline {
            lastAnalysisUnion = pipeline.lastAnalysisUnion
        } else {
            lastAnalysisUnion = Self.analysisUnion(from: pipeline, projected: intervals)
        }
        await applySchedule(intervals: intervals)
        let ready = snapshot.processedEnd >= AnalysisChunking.chunkSize
            || snapshot.processedEnd >= snapshot.episodeDuration
        guard ready else { return }
        if !canStartPlayback {
            canStartPlayback = true
        }
        if chunkReadyGate.mark() {
            onChunkReady?()
        }
    }

    private func snapshotProcessedEndHint(from intervals: [CensorInterval]) -> Double {
        intervals.map(\.end).max() ?? 0
    }

    /// Remaps **profanity** intervals only. Does not call `analyze`.
    func setAction(_ action: CensorAction) async {
        guard action != currentAction else { return }
        currentAction = action
        await applyCurrentSchedule()
    }

    /// Remaps **unrelatedContent** intervals only. Does not call `analyze`.
    func setUnrelatedContentAction(_ action: CensorAction) async {
        guard action != unrelatedContentAction else { return }
        unrelatedContentAction = action
        await applyCurrentSchedule()
    }

    /// Filters unrelated intervals and re-applies schedule. Does not call `analyze`.
    func setUnrelatedContentEnabled(_ enabled: Bool) async {
        guard enabled != unrelatedContentEnabled else { return }
        unrelatedContentEnabled = enabled
        await applyCurrentSchedule()
    }

    /// Re-applies overlay from the current settings store mode without re-analysis.
    func refreshOverlayFromSettings() {
        applyOverlay(to: lastScheduledIntervals)
    }

    private var lastScheduledIntervals: [CensorInterval] = []

    private func applyCurrentSchedule() async {
        await applySchedule(intervals: cachedIntervals)
    }

    private func applySchedule(intervals: [CensorInterval]) async {
        let scheduled = intervals
            .filter { $0.source != .unrelatedContent || unrelatedContentEnabled }
            .map { interval -> CensorInterval in
                switch interval.source {
                case .profanity:
                    return CensorInterval(
                        start: interval.start,
                        end: interval.end,
                        action: currentAction,
                        source: .profanity
                    )
                case .unrelatedContent:
                    return CensorInterval(
                        start: interval.start,
                        end: interval.end,
                        action: unrelatedContentAction,
                        source: .unrelatedContent
                    )
                }
            }
        lastScheduledIntervals = scheduled
        await engine.applySchedule(IntervalSchedule(intervals: scheduled))
        applyOverlay(to: scheduled)
    }

    private func applyOverlay(to scheduled: [CensorInterval]) {
        let mode = settingsStore?.muteOverlayMode ?? .off
        let muteIntervals = scheduled
            .filter { $0.action == .mute }
            .map { (start: $0.start, end: $0.end) }
        overlayEngine.apply(muteIntervals: muteIntervals, mode: mode)
    }

    /// Full analyze union when the pipeline is wrapped (e.g. test spies forwarding 4-arg analyze).
    private static func analysisUnion(
        from pipeline: any EpisodeAnalyzing,
        projected: [CensorInterval]
    ) -> [CensorInterval] {
        let mirror = Mirror(reflecting: pipeline)
        if let inner = mirror.children.first(where: { $0.label == "inner" })?.value as? AnalysisPipeline {
            return inner.lastAnalysisUnion
        }
        return projected
    }

    // Avoid MainActor/TaskLocal deinit crash under SWIFT_DEFAULT_ACTOR_ISOLATION
    // (XCTest teardown otherwise SIGABRT via swift_task_deinitOnExecutorImpl).
    nonisolated deinit {}
}

/// One-shot gate for progressive `onChunkReady` (Sendable across partial callbacks).
private final class OnceFlag: @unchecked Sendable {
    private let lock = NSLock()
    private var value = false

    /// Returns `true` the first time only.
    func mark() -> Bool {
        lock.lock()
        defer { lock.unlock() }
        if value { return false }
        value = true
        return true
    }
}

/// Restores a prior `onPartialIntervals` handler after progressive prepare.
private struct PartialHandlerInstallation {
    let restore: () -> Void
}
