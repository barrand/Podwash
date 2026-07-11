//
//  PlaybackCoordinator.swift
//  PodWash
//
//  Slice 08 — Wires cached/pipeline intervals into PlaybackEngine with a swappable
//  action setting (ADR-006). Slice 19 remaps actions by IntervalSource (ADR-013 §3.5).
//

import Foundation

/// Wires cached/pipeline intervals into the player with swappable per-source actions.
@MainActor
final class PlaybackCoordinator {

    private let pipeline: any EpisodeAnalyzing
    private let engine: PlaybackEngine

    private(set) var cachedIntervals: [CensorInterval] = []
    private(set) var currentAction: CensorAction = .mute
    private(set) var unrelatedContentEnabled: Bool = false
    private(set) var unrelatedContentAction: CensorAction = .skip

    init(pipeline: any EpisodeAnalyzing, engine: PlaybackEngine) {
        self.pipeline = pipeline
        self.engine = engine
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

    /// Runs `analyze` once (cache hit or miss), stores returned bounds, applies schedule.
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
        cachedIntervals = intervals
        currentAction = action
        unrelatedContentEnabled = unrelatedContent.enabled
        unrelatedContentAction = unrelatedContent.action
        await applyCurrentSchedule()
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

    private func applyCurrentSchedule() async {
        let scheduled = cachedIntervals
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
        await engine.applySchedule(IntervalSchedule(intervals: scheduled))
    }
}
