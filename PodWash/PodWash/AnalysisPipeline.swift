//
//  AnalysisPipeline.swift
//  PodWash
//
//  Slice 07 — Analyze-episode pipeline. ASR → WordMatcher/IntervalBuilder →
//  persisted interval list (ADR-005 §2). Transcript injection bypasses ASR for
//  fast tests; production uses ASRTranscribing (Slice 05 stack).
//

import Foundation

/// ASR → matcher → cache pipeline.
final class AnalysisPipeline: @unchecked Sendable {

    private let transcriber: any ASRTranscribing
    private let cache: IntervalCache

    init(transcriber: any ASRTranscribing, cache: IntervalCache) {
        self.transcriber = transcriber
        self.cache = cache
    }

    /// Full path: check cache → ASR (if miss) → build intervals → persist → return.
    func analyze(
        episode: EpisodeIdentity,
        audioURL: URL,
        targetWords: Set<String>
    ) async throws -> [CensorInterval] {
        try await analyze(
            episode: episode,
            audioURL: audioURL,
            targetWords: targetWords,
            injectedTranscript: nil
        )
    }

    /// Fast-test path: skip ASR when `injectedTranscript` is non-nil.
    func analyze(
        episode: EpisodeIdentity,
        audioURL: URL,
        targetWords: Set<String>,
        injectedTranscript: [TimedWord]?
    ) async throws -> [CensorInterval] {
        if let cached = cache.load(episodeID: episode.id, targetWords: targetWords) {
            return cached
        }

        let transcript: [TimedWord]
        if let injected = injectedTranscript {
            transcript = injected
        } else {
            transcript = try await transcriber.transcribe(fileURL: audioURL)
        }

        let intervals = IntervalBuilder.buildIntervals(from: transcript, targetSet: targetWords)
        try cache.store(intervals, episodeID: episode.id, targetWords: targetWords)
        return intervals
    }
}
