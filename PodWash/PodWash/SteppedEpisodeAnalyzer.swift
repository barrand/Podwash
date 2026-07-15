//
//  SteppedEpisodeAnalyzer.swift
//  PodWash
//
//  Slice 20 — Deterministic progress double for timeline UITests (ADR-018).
//  Slice 25 — Optional partial intervals + mid-run freeze (ADR-021 §5).
//

import Foundation

typealias AnalysisProgressHandler = @Sendable (AnalysisProgressSnapshot) -> Void

/// Main-actor progress sink — applied synchronously inside `MainActor.run`.
typealias MainActorAnalysisProgressHandler = @MainActor (AnalysisProgressSnapshot) -> Void

final class SteppedEpisodeAnalyzer: EpisodeAnalyzing, @unchecked Sendable {
    let snapshots: [AnalysisProgressSnapshot]
    let pacing: any AnalysisProgressPacing
    let partialIntervalsBySnapshot: [[CensorInterval]]
    let freezeAtProcessedEnd: Double?
    /// Extra hold after the first snapshot so progressive UITests can observe mid-flight state.
    let firstSnapshotHold: Duration?
    var onProgress: AnalysisProgressHandler?
    /// Preferred UI sink: invoked on the main actor before each paced wait.
    var onMainActorProgress: MainActorAnalysisProgressHandler?
    var onPartialIntervals: AnalysisPartialIntervalsHandler?

    init(
        snapshots: [AnalysisProgressSnapshot],
        pacing: any AnalysisProgressPacing,
        onProgress: AnalysisProgressHandler? = nil,
        onMainActorProgress: MainActorAnalysisProgressHandler? = nil,
        partialIntervalsBySnapshot: [[CensorInterval]] = [],
        freezeAtProcessedEnd: Double? = nil,
        firstSnapshotHold: Duration? = nil
    ) {
        self.snapshots = snapshots
        self.pacing = pacing
        self.onProgress = onProgress
        self.onMainActorProgress = onMainActorProgress
        self.partialIntervalsBySnapshot = partialIntervalsBySnapshot
        self.freezeAtProcessedEnd = freezeAtProcessedEnd
        self.firstSnapshotHold = firstSnapshotHold
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

        var union: [CensorInterval] = []
        for (index, snapshot) in snapshots.enumerated() {
            let partial = index < partialIntervalsBySnapshot.count
                ? partialIntervalsBySnapshot[index]
                : []
            union.append(contentsOf: partial)
            // Publish on the main actor before sleeping so AX values update
            // before the next paced wait (UITests poll during Task.sleep idle).
            await MainActor.run {
                onMainActorProgress?(snapshot)
                onProgress?(snapshot)
                onPartialIntervals?(partial, snapshot)
            }
            // Progressive prepare installs `onPartialIntervals` as Task { @MainActor };
            // yield so canStartPlayback / schedule apply land before the paced hold
            // (UITests poll play + first-chunk AX during that window).
            await Task.yield()
            if let freezeAt = freezeAtProcessedEnd,
               abs(snapshot.processedEnd - freezeAt) < 0.01,
               index < snapshots.count - 1 {
                // Hold mid-run snapshot long enough for AC5 seek assertion.
                try await Task.sleep(for: .seconds(30))
            } else if index < snapshots.count - 1 {
                if index == 0, let firstSnapshotHold {
                    try await Task.sleep(for: firstSnapshotHold)
                } else {
                    await pacing.waitBetweenSnapshots()
                }
            }
        }
        return union
    }
}
