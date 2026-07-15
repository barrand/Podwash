//
//  EpisodeAnalyzing.swift
//  PodWash
//
//  Slice 08 — Playback integration seam (ADR-006 §2). Slice 19 extends analyze
//  with unrelated-content options (ADR-013 §3.3). Slice 25 adds progressive
//  partial-interval callbacks (ADR-021 §2).
//

import Foundation

/// Invoked after each analysis chunk’s intervals are ready — before `analyze` returns.
typealias AnalysisPartialIntervalsHandler = @Sendable (
    _ intervals: [CensorInterval],
    _ snapshot: AnalysisProgressSnapshot
) -> Void

/// Pipeline entry point for playback wiring (ADR-005 analyze overload with injection seam).
///
/// Conformers may implement either overload; the other is supplied by the extension
/// below so legacy 4-arg spies and Slice 19 6-arg spies both compile.
///
/// Class-bound so progressive `onPartialIntervals` installs mutate stored properties
/// through `any EpisodeAnalyzing` (value-type existentials cannot retain handlers).
protocol EpisodeAnalyzing: AnyObject, Sendable {
    func analyze(
        episode: EpisodeIdentity,
        audioURL: URL,
        targetWords: Set<String>,
        injectedTranscript: [TimedWord]?
    ) async throws -> [CensorInterval]

    func analyze(
        episode: EpisodeIdentity,
        audioURL: URL,
        targetWords: Set<String>,
        injectedTranscript: [TimedWord]?,
        profanityAction: CensorAction,
        unrelatedContent: UnrelatedContentOptions
    ) async throws -> [CensorInterval]

    /// Progressive analyzers set this; Instant / legacy doubles may leave nil.
    var onPartialIntervals: AnalysisPartialIntervalsHandler? { get set }
}

extension EpisodeAnalyzing {
    /// Default no-op so Instant / legacy spies compile without a stored property.
    var onPartialIntervals: AnalysisPartialIntervalsHandler? {
        get { nil }
        set { _ = newValue }
    }

    /// Default for Slice 19 spies that only implement the 6-arg overload.
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

    /// Default for legacy spies that only implement the 4-arg overload.
    func analyze(
        episode: EpisodeIdentity,
        audioURL: URL,
        targetWords: Set<String>,
        injectedTranscript: [TimedWord]?,
        profanityAction: CensorAction,
        unrelatedContent: UnrelatedContentOptions
    ) async throws -> [CensorInterval] {
        _ = profanityAction
        _ = unrelatedContent
        return try await analyze(
            episode: episode,
            audioURL: audioURL,
            targetWords: targetWords,
            injectedTranscript: injectedTranscript
        )
    }
}

extension AnalysisPipeline: EpisodeAnalyzing {}
