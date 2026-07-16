//
//  InstantEpisodeAnalyzer.swift
//  PodWash
//
//  Slice 09 — Stub analyzer for UI tests (-UITestFixtureAnalysis).
//  Slice 20 — Publishes at least one timeline snapshot while analyzing (ADR-018).
//

import Foundation

/// Returns immediately with an empty interval list for deterministic UI tests.
final class InstantEpisodeAnalyzer: EpisodeAnalyzing, @unchecked Sendable {
    var onProgress: AnalysisProgressHandler?
    /// `nonisolated(unsafe)`: cleared from `nonisolated deinit` without a MainActor TaskLocal hop.
    nonisolated(unsafe) var onMainActorProgress: MainActorAnalysisProgressHandler?
    var onPartialIntervals: AnalysisPartialIntervalsHandler?

    // Avoid MainActor/TaskLocal deinit crash under SWIFT_DEFAULT_ACTOR_ISOLATION
    // (boxed as `any EpisodeAnalyzing` in PlaybackCoordinator teardown).
    nonisolated deinit {}

    func analyze(
        episode: EpisodeIdentity,
        audioURL: URL,
        targetWords: Set<String>,
        injectedTranscript: [TimedWord]?
    ) async throws -> [CensorInterval] {
        try await analyze(
            episode: episode,
            audioURL: audioURL,
            targetWords: targetWords,
            injectedTranscript: injectedTranscript,
            profanityAction: .mute,
            unrelatedContent: UnrelatedContentOptions()
        )
    }

    func analyze(
        episode: EpisodeIdentity,
        audioURL: URL,
        targetWords: Set<String>,
        injectedTranscript: [TimedWord]?,
        profanityAction: CensorAction,
        unrelatedContent: UnrelatedContentOptions
    ) async throws -> [CensorInterval] {
        _ = episode
        _ = audioURL
        _ = targetWords
        _ = injectedTranscript
        _ = profanityAction
        _ = unrelatedContent

        let duration: Double
        let seededIntervals: [CensorInterval]
        if FixturePrerollAdBands.isAnyEnabled {
            duration = FixturePrerollAdBands.episodeDuration
            seededIntervals = FixturePrerollAdBands.makeIntervals()
        } else if FixtureMuteMarkers.isAnyEnabled {
            duration = FixtureAnalysisTimeline.episodeDuration
            seededIntervals = FixtureMuteMarkers.makeIntervals()
        } else {
            duration = FixtureAnalysisTimeline.episodeDuration
            seededIntervals = []
        }
        let start = AnalysisProgressSnapshot(
            episodeDuration: duration,
            processedEnd: 0,
            processingStart: 0,
            processingEnd: min(FixtureAnalysisTimeline.bucketWidth, duration),
            adRanges: []
        )
        let adRanges = seededIntervals
            .filter { $0.source == .unrelatedContent }
            .map { AdTimeRange(start: $0.start, end: $0.end) }
        let complete = AnalysisProgressSnapshot(
            episodeDuration: duration,
            processedEnd: duration,
            processingStart: duration,
            processingEnd: duration,
            adRanges: adRanges
        )
        await MainActor.run {
            onMainActorProgress?(start)
            onProgress?(start)
        }
        // Brief yield only — the observable analyzing window is held in
        // `AnalysisUIViewModel.completePrimedEpisodeAnalysis` via Task.sleep so
        // XCTest can go idle while `analysisTimeline` is still in the AX tree.
        try await Task.sleep(for: .milliseconds(200))
        await MainActor.run {
            onMainActorProgress?(complete)
            onProgress?(complete)
        }
        return seededIntervals
    }
}
