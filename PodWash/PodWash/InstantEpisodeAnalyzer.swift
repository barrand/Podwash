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
        // Brief pause so progress stays visible after the EpisodeListView deferral
        // window; keep toggle→done under UX 1s / UI-test 5s completion bound.
        // Must not rely on UIActivityIndicator animation (that blocks XCTest idle).
        try await Task.sleep(for: .milliseconds(FixtureAnalysis.isEnabled ? 400 : 200))
        return []
    }
}
