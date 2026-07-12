//
//  AnalysisPipeline.swift
//  PodWash
//
//  Slice 07 — Analyze-episode pipeline. ASR → WordMatcher/IntervalBuilder →
//  persisted interval list (ADR-005 §2). Slice 19 merges ContentSegmenting
//  intervals with independent actions (ADR-013 §3.3).
//

import Foundation

/// ASR → matcher → segmenter → cache pipeline.
final class AnalysisPipeline: @unchecked Sendable {

    /// `nonisolated(unsafe)`: released from `nonisolated deinit` without a MainActor hop
    /// (existentials of MainActor-isolated ASR types otherwise crash boxed destroy).
    nonisolated(unsafe) private let transcriber: any ASRTranscribing
    private let cache: IntervalCache
    private let segmenter: any ContentSegmenting

    init(
        transcriber: any ASRTranscribing,
        cache: IntervalCache,
        segmenter: any ContentSegmenting = HeuristicContentSegmenter()
    ) {
        self.transcriber = transcriber
        self.cache = cache
        self.segmenter = segmenter
    }

    // Avoid MainActor/TaskLocal deinit crash when boxed as `any EpisodeAnalyzing`.
    nonisolated deinit {}

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
            injectedTranscript: nil,
            profanityAction: .mute,
            unrelatedContent: UnrelatedContentOptions()
        )
    }

    /// Fast-test path: skip ASR when `injectedTranscript` is non-nil.
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

    /// Analyze with independent profanity / unrelated-content actions (ADR-013 §3.3).
    func analyze(
        episode: EpisodeIdentity,
        audioURL: URL,
        targetWords: Set<String>,
        injectedTranscript: [TimedWord]?,
        profanityAction: CensorAction,
        unrelatedContent: UnrelatedContentOptions
    ) async throws -> [CensorInterval] {
        let union: [CensorInterval]
        if let cached = cache.load(episodeID: episode.id, targetWords: targetWords) {
            union = cached
        } else {
            let transcript: [TimedWord]
            if let injected = injectedTranscript {
                transcript = injected
            } else {
                transcript = try await transcriber.transcribe(fileURL: audioURL)
            }

            let profanity = IntervalBuilder.buildIntervals(
                from: transcript,
                targetSet: targetWords,
                action: profanityAction
            ).map {
                CensorInterval(
                    start: $0.start,
                    end: $0.end,
                    action: profanityAction,
                    source: .profanity
                )
            }

            // Always segment on cache miss; enablement is a return/playback filter.
            let segmentIntervals = segmenter.segments(in: transcript).map { segment in
                CensorInterval(
                    start: segment.start,
                    end: segment.end,
                    action: unrelatedContent.action,
                    source: .unrelatedContent
                )
            }

            union = (profanity + segmentIntervals).sorted { $0.start < $1.start }
            try cache.store(union, episodeID: episode.id, targetWords: targetWords)
        }

        return Self.project(
            union: union,
            profanityAction: profanityAction,
            unrelatedContent: unrelatedContent
        )
    }

    /// Remap actions by source; drop unrelated when disabled.
    private static func project(
        union: [CensorInterval],
        profanityAction: CensorAction,
        unrelatedContent: UnrelatedContentOptions
    ) -> [CensorInterval] {
        union.compactMap { interval in
            switch interval.source {
            case .profanity:
                return CensorInterval(
                    start: interval.start,
                    end: interval.end,
                    action: profanityAction,
                    source: .profanity
                )
            case .unrelatedContent:
                guard unrelatedContent.enabled else { return nil }
                return CensorInterval(
                    start: interval.start,
                    end: interval.end,
                    action: unrelatedContent.action,
                    source: .unrelatedContent
                )
            }
        }
    }
}
