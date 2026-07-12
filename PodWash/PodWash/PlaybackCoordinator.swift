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

    private let pipeline: any EpisodeAnalyzing
    private let engine: PlaybackEngine
    private let settingsStore: SettingsStore?
    private let overlayEngine: OverlayEngine

    private(set) var cachedIntervals: [CensorInterval] = []
    private(set) var currentAction: CensorAction = .mute
    private(set) var unrelatedContentEnabled: Bool = false
    private(set) var unrelatedContentAction: CensorAction = .skip

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
        await applySchedule(intervals: intervals)
        cachedIntervals = intervals
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
}
