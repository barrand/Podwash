//
//  EpisodeAnalyzing.swift
//  PodWash
//
//  Slice 08 — Playback integration seam (ADR-006 §2). Lets tests spy on analyze
//  call count without mocking ASR alone.
//

import Foundation

/// Pipeline entry point for playback wiring (ADR-005 analyze overload with injection seam).
protocol EpisodeAnalyzing: Sendable {
    func analyze(
        episode: EpisodeIdentity,
        audioURL: URL,
        targetWords: Set<String>,
        injectedTranscript: [TimedWord]?
    ) async throws -> [CensorInterval]
}

extension AnalysisPipeline: EpisodeAnalyzing {}
