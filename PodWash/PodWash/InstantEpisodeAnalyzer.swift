//
//  InstantEpisodeAnalyzer.swift
//  PodWash
//
//  Slice 09 — Stub analyzer for UI tests (-UITestFixtureAnalysis).
//

import Foundation

/// Returns immediately with an empty interval list for deterministic UI tests.
struct InstantEpisodeAnalyzer: EpisodeAnalyzing, Sendable {
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
        _ = profanityAction
        _ = unrelatedContent
        // Brief yield only — the observable analyzing window is held in
        // `AnalysisUIViewModel.completePrimedEpisodeAnalysis` via Task.sleep so
        // XCTest can go idle while `analysisProgress` is still in the AX tree.
        // Must not animate UIActivityIndicator (that blocks XCTest idle).
        try await Task.sleep(for: .milliseconds(200))
        return []
    }
}
