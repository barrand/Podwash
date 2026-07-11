//
//  SteppedEpisodeAnalyzer.swift
//  PodWash
//
//  Slice 20 — Deterministic progress double for timeline UITests (ADR-018).
//

import Foundation

typealias AnalysisProgressHandler = @Sendable (AnalysisProgressSnapshot) -> Void

/// Main-actor progress sink — applied synchronously inside `MainActor.run`.
typealias MainActorAnalysisProgressHandler = @MainActor (AnalysisProgressSnapshot) -> Void

final class SteppedEpisodeAnalyzer: EpisodeAnalyzing, @unchecked Sendable {
    let snapshots: [AnalysisProgressSnapshot]
    let pacing: any AnalysisProgressPacing
    var onProgress: AnalysisProgressHandler?
    /// Preferred UI sink: invoked on the main actor before each paced wait.
    var onMainActorProgress: MainActorAnalysisProgressHandler?

    init(
        snapshots: [AnalysisProgressSnapshot],
        pacing: any AnalysisProgressPacing,
        onProgress: AnalysisProgressHandler? = nil,
        onMainActorProgress: MainActorAnalysisProgressHandler? = nil
    ) {
        self.snapshots = snapshots
        self.pacing = pacing
        self.onProgress = onProgress
        self.onMainActorProgress = onMainActorProgress
    }

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

        for (index, snapshot) in snapshots.enumerated() {
            // Publish on the main actor before sleeping so AX values update
            // before the next paced wait (UITests poll during Task.sleep idle).
            await MainActor.run {
                onMainActorProgress?(snapshot)
                onProgress?(snapshot)
            }
            // Wait between snapshots only — terminal hold lives in
            // `AnalysisUIViewModel.completePrimedEpisodeAnalysis` so toggle→done
            // stays under the AC4/AC5 ≤5 s budget.
            if index < snapshots.count - 1 {
                await pacing.waitBetweenSnapshots()
            }
        }
        return []
    }
}
