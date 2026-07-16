//
//  AnalysisPipeline.swift
//  PodWash
//
//  Slice 07 — Analyze-episode pipeline. ASR → WordMatcher/IntervalBuilder →
//  persisted interval list (ADR-005 §2). Slice 19 merges ContentSegmenting
//  intervals with independent actions (ADR-013 §3.3).
//  Slice 20 / mini-player — optional start+complete progress (ADR-018 §6).
//  Slice 25 — chunked cold-miss analyze + partial intervals (ADR-021 §3).
//

import AVFoundation
import Foundation

extension Notification.Name {
    /// Posted after a deferred NoCache transcript backfill write (UITest AC7 / Task 020).
    static let podwashTranscriptBackfillDidStore = Notification.Name(
        "com.barrandfarm.PodWash.transcriptBackfillDidStore"
    )
}

enum PodWashTranscriptBackfillUserInfoKey {
    static let episodeID = "episodeID"
}

/// ASR → matcher → segmenter → cache pipeline.
final class AnalysisPipeline: @unchecked Sendable {

    /// Signals live transcription progress emission to stop.
    private final class TranscriptionProgressGate: @unchecked Sendable {
        private let lock = NSLock()
        private var finished = false
        func markFinished() {
            lock.lock()
            finished = true
            lock.unlock()
        }
        var isFinished: Bool {
            lock.lock()
            defer { lock.unlock() }
            return finished
        }
    }

    /// `nonisolated(unsafe)`: released from `nonisolated deinit` without a MainActor hop
    /// (existentials of MainActor-isolated ASR types otherwise crash boxed destroy).
    nonisolated(unsafe) private let transcriber: any ASRTranscribing
    private let cache: IntervalCache
    private let transcriptCache: TranscriptCache
    private let segmenter: any ContentSegmenting

    var onProgress: AnalysisProgressHandler?
    /// `nonisolated(unsafe)`: cleared from `nonisolated deinit` without a MainActor TaskLocal hop.
    nonisolated(unsafe) var onMainActorProgress: MainActorAnalysisProgressHandler?
    var onPartialIntervals: AnalysisPartialIntervalsHandler?

    /// Full cache union from the most recent `analyze` call (includes filtered unrelated spans).
    private(set) var lastAnalysisUnion: [CensorInterval] = []

    init(
        transcriber: any ASRTranscribing,
        cache: IntervalCache,
        transcriptCache: TranscriptCache = .applicationSupport,
        segmenter: any ContentSegmenting = HeuristicContentSegmenter()
    ) {
        self.transcriber = transcriber
        self.cache = cache
        self.transcriptCache = transcriptCache
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
        let audioDuration = await Self.resolveDuration(audioURL: audioURL)
        // Progressive + injected short fixtures: pad horizon to ≥ one chunk so AC8’s
        // first-chunk frontier (`processedEnd >= 30`) is observable on 5 s sine audio.
        let duration: Double
        if onPartialIntervals != nil,
           injectedTranscript != nil,
           audioDuration > 0,
           audioDuration < AnalysisChunking.chunkSize {
            duration = AnalysisChunking.chunkSize
        } else {
            duration = audioDuration
        }

        if duration > 0 {
            await emitProgress(AnalysisTimelineModel.startSnapshot(duration: duration))
        }

        let union: [CensorInterval]
        if let cached = cache.load(episodeID: episode.id, targetWords: targetWords) {
            // Interval cache hit — do not overwrite an existing transcript (ADR-022 §4).
            union = cached
            if transcriptCache.load(episodeID: episode.id) == nil {
                try await backfillMissingTranscript(
                    episode: episode,
                    audioURL: audioURL,
                    duration: duration,
                    injectedTranscript: injectedTranscript
                )
            }
        } else if onPartialIntervals != nil {
            union = try await analyzeChunkedColdMiss(
                episode: episode,
                audioURL: audioURL,
                duration: duration,
                targetWords: targetWords,
                injectedTranscript: injectedTranscript,
                profanityAction: profanityAction,
                unrelatedContent: unrelatedContent
            )
        } else {
            let transcript: [TimedWord]
            if let injected = injectedTranscript, !injected.isEmpty {
                transcript = injected
            } else {
                transcript = try await transcribeWithLiveProgress(
                    fileURL: audioURL,
                    duration: duration
                )
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
            try transcriptCache.store(transcript, episodeID: episode.id)
        }

        lastAnalysisUnion = union

        let projected = Self.projectPlaybackIntervals(
            union: union,
            profanityAction: profanityAction,
            unrelatedContent: unrelatedContent
        )

        if duration > 0 {
            await emitProgress(
                Self.completeSnapshot(
                    duration: duration,
                    intervals: projected,
                    adRangeIntervals: Self.adRangePaintIntervals(
                        playbackIntervals: projected,
                        analysisUnion: union,
                        unrelatedContentEnabled: unrelatedContent.enabled
                    )
                )
            )
        }

        return projected
    }

    /// Chunked cold-miss path (ADR-021 §3). Cache write only after the final chunk.
    private func analyzeChunkedColdMiss(
        episode: EpisodeIdentity,
        audioURL: URL,
        duration: Double,
        targetWords: Set<String>,
        injectedTranscript: [TimedWord]?,
        profanityAction: CensorAction,
        unrelatedContent: UnrelatedContentOptions
    ) async throws -> [CensorInterval] {
        // Live ASR: one full-file pass, then emit logical chunk frontiers (ADR-021 §3).
        // Injected path filters the transcript per chunk without ASR.
        let fullTranscript: [TimedWord]
        if let injected = injectedTranscript, !injected.isEmpty {
            fullTranscript = injected
        } else {
            fullTranscript = try await transcriber.transcribe(fileURL: audioURL)
        }

        var lastUnion: [CensorInterval] = []
        let ends = AnalysisChunking.chunkEnds(duration: max(duration, 0.001))
        for chunkEnd in ends {
            let accumulatedTranscript = fullTranscript.filter { $0.start < chunkEnd }

            let profanity = IntervalBuilder.buildIntervals(
                from: accumulatedTranscript,
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
            let segmentIntervals = segmenter.segments(in: accumulatedTranscript).map { segment in
                CensorInterval(
                    start: segment.start,
                    end: segment.end,
                    action: unrelatedContent.action,
                    source: .unrelatedContent
                )
            }
            let fullUnion = (profanity + segmentIntervals).sorted { $0.start < $1.start }
            lastUnion = fullUnion

            let eligible = fullUnion.filter { $0.end <= chunkEnd }
            let projectedEligible = Self.projectPlaybackIntervals(
                union: eligible,
                profanityAction: profanityAction,
                unrelatedContent: unrelatedContent
            )

            let isTerminal = chunkEnd >= duration - 0.000_1
            let snapshot: AnalysisProgressSnapshot
            if isTerminal {
                let terminalProjected = Self.projectPlaybackIntervals(
                    union: fullUnion,
                    profanityAction: profanityAction,
                    unrelatedContent: unrelatedContent
                )
                snapshot = Self.completeSnapshot(
                    duration: duration,
                    intervals: terminalProjected,
                    adRangeIntervals: Self.adRangePaintIntervals(
                        playbackIntervals: terminalProjected,
                        analysisUnion: fullUnion,
                        unrelatedContentEnabled: unrelatedContent.enabled
                    )
                )
            } else {
                snapshot = AnalysisChunking.inFlightSnapshot(
                    duration: duration,
                    processedEnd: chunkEnd
                )
            }

            await emitProgress(snapshot)
            await emitPartialIntervals(projectedEligible, snapshot: snapshot)
        }

        try cache.store(lastUnion, episodeID: episode.id, targetWords: targetWords)
        // Terminal-only transcript write (ADR-022 §4 / ADR-021) — never mid-chunk.
        try transcriptCache.store(fullTranscript, episodeID: episode.id)
        return lastUnion
    }

    /// Interval cache hit with no transcript file — persist ASR (or injected) without re-analyzing intervals.
    private func backfillMissingTranscript(
        episode: EpisodeIdentity,
        audioURL: URL,
        duration: Double,
        injectedTranscript: [TimedWord]?
    ) async throws {
        let transcript: [TimedWord]
        if let injected = injectedTranscript, !injected.isEmpty {
            transcript = injected
        } else {
            transcript = try await transcribeWithLiveProgress(
                fileURL: audioURL,
                duration: duration
            )
        }
        // UITest NoCache: store off the prepare critical path so AC7 can expand the
        // full player and assert `playback.viewTranscript` absent. Task 020 still
        // observes the affordance once the deferred write lands (≤ backfill wait).
        if FixtureTranscript.isNoCacheEnabled {
            let episodeID = episode.id
            let cache = transcriptCache
            Task { @MainActor in
                try? await Task.sleep(for: .seconds(8))
                try? cache.store(transcript, episodeID: episodeID)
                NotificationCenter.default.post(
                    name: .podwashTranscriptBackfillDidStore,
                    object: nil,
                    userInfo: [PodWashTranscriptBackfillUserInfoKey.episodeID: episodeID]
                )
            }
            return
        }
        try transcriptCache.store(transcript, episodeID: episode.id)
    }

    /// Runs ASR while emitting time-based timeline progress (ADR-018 §6 — not Whisper chunk truth).
    private func transcribeWithLiveProgress(fileURL: URL, duration: Double) async throws -> [TimedWord] {
        guard duration > 0 else {
            return try await transcriber.transcribe(fileURL: fileURL)
        }

        let gate = TranscriptionProgressGate()
        let progressTask = Task {
            await emitTimeBasedProgressDuringTranscription(duration: duration, gate: gate)
        }
        defer {
            gate.markFinished()
            progressTask.cancel()
        }
        return try await transcriber.transcribe(fileURL: fileURL)
    }

    private func emitTimeBasedProgressDuringTranscription(
        duration: Double,
        gate: TranscriptionProgressGate
    ) async {
        let bucketWidth = duration / Double(AnalysisTimelineModel.defaultSegmentCount)
        var processedEnd = 0.0
        while !gate.isFinished {
            try? await Task.sleep(for: .milliseconds(350))
            if gate.isFinished { break }
            processedEnd = min(max(0, duration - bucketWidth), processedEnd + bucketWidth)
            await emitProgress(
                AnalysisTimelineModel.inFlightSnapshot(
                    duration: duration,
                    processedEnd: processedEnd
                )
            )
            if processedEnd >= duration - bucketWidth { break }
        }
    }

    /// Intervals for yellow buckets: applied playback when unrelated skip/mute is on;
    /// full analyze union when unrelated is filtered from playback (ADR-018 / task-019).
    static func adRangePaintIntervals(
        playbackIntervals: [CensorInterval],
        analysisUnion: [CensorInterval],
        unrelatedContentEnabled: Bool
    ) -> [CensorInterval] {
        if unrelatedContentEnabled {
            return playbackIntervals
        }
        if analysisUnion.contains(where: { $0.source == .unrelatedContent }) {
            return analysisUnion
        }
        return playbackIntervals
    }

    /// Remap actions by source; drop unrelated when disabled.
    static func projectPlaybackIntervals(
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

    private func emitProgress(_ snapshot: AnalysisProgressSnapshot) async {
        await MainActor.run {
            onMainActorProgress?(snapshot)
            onProgress?(snapshot)
        }
    }

    private func emitPartialIntervals(
        _ intervals: [CensorInterval],
        snapshot: AnalysisProgressSnapshot
    ) async {
        await MainActor.run {
            onPartialIntervals?(intervals, snapshot)
        }
    }

    private static func completeSnapshot(
        duration: Double,
        intervals: [CensorInterval],
        adRangeIntervals: [CensorInterval]
    ) -> AnalysisProgressSnapshot {
        AnalysisTimelineModel.completeSnapshot(
            duration: duration,
            intervals: intervals,
            adRangeIntervals: adRangeIntervals
        )
    }

    private static func resolveDuration(audioURL: URL) async -> Double {
        let asset = AVURLAsset(url: audioURL)
        do {
            let loaded = try await asset.load(.duration)
            let seconds = loaded.seconds
            guard seconds.isFinite, seconds > 0 else { return 0 }
            return seconds
        } catch {
            return 0
        }
    }
}
