//
//  FixtureTranscript.swift
//  PodWash
//
//  Slice 26 — Launch-argument transcript UITest fixture (ADR-022 §5).
//

import Foundation

enum FixtureTranscript {
    static let launchArgument = "-UITestFixtureTranscript"
    static let noCacheLaunchArgument = "-UITestFixtureTranscriptNoCache"
    static let longFollowLaunchArgument = "-UITestFixtureTranscriptLongFollow"
    static let scrollFollowLaunchArgument = "-UITestFixtureTranscriptScrollFollow"

    static let wordCount = 24
    static let wordDuration = 2.5
    static let playbackPosition: TimeInterval = 30.0
    static let longFollowWordCount = 1_100
    static let longFollowPlaybackPosition: TimeInterval = 41 * 60
    static let scrollFollowWordCount = 240
    static let scrollFollowWordDuration = 1.0
    static let scrollFollowPlaybackPosition: TimeInterval = 30.0
    static let unrelatedSkipStart = 35.0
    static let unrelatedSkipEnd = 42.5

    static var isEnabled: Bool {
        ProcessInfo.processInfo.arguments.contains { argument in
            argument == launchArgument
                || argument == longFollowLaunchArgument
                || argument == scrollFollowLaunchArgument
                || (argument.hasSuffix("UITestFixtureTranscript")
                    && !argument.contains("NoCache"))
        }
    }

    static var isLongFollowEnabled: Bool {
        ProcessInfo.processInfo.arguments.contains(longFollowLaunchArgument)
    }

    static var isScrollFollowEnabled: Bool {
        ProcessInfo.processInfo.arguments.contains(scrollFollowLaunchArgument)
    }

    /// Dedicated negative mode: same library/intervals/resume, omit transcript file.
    static var isNoCacheEnabled: Bool {
        ProcessInfo.processInfo.arguments.contains { argument in
            argument == noCacheLaunchArgument
                || argument.hasSuffix("UITestFixtureTranscriptNoCache")
        }
    }

    /// True when either transcript fixture flag is present (with or without cache).
    static var isAnyEnabled: Bool {
        isEnabled || isNoCacheEnabled
    }

    /// Library / in-memory persistence path (same family as FixtureLibrary).
    static var usesInMemoryPersistence: Bool {
        isAnyEnabled
    }

    /// The scroll-follow fixture resumes at 30 seconds and needs enough audio
    /// remaining to cross a later transcript render block.
    static func scrollFollowAudioURL(in bundle: Bundle = .main) -> URL? {
        bundle.url(
            forResource: "progressive-120s",
            withExtension: "m4a",
            subdirectory: "Fixtures/audio"
        ) ?? bundle.url(forResource: "progressive-120s", withExtension: "m4a")
    }

    static func makeTranscript() -> [TimedWord] {
        let count = isLongFollowEnabled
            ? longFollowWordCount
            : (isScrollFollowEnabled ? scrollFollowWordCount : wordCount)
        let duration = isScrollFollowEnabled ? scrollFollowWordDuration : wordDuration
        return (0 ..< count).map { index in
            let start = Double(index) * duration
            let text = isScrollFollowEnabled && index % 4 == 3 ? "w\(index)." : "w\(index)"
            return TimedWord(word: text, start: start, end: start + duration)
        }
    }

    static func makeSkipIntervals() -> [CensorInterval] {
        [
            CensorInterval(
                start: unrelatedSkipStart,
                end: unrelatedSkipEnd,
                action: .skip,
                source: .unrelatedContent
            ),
        ]
    }

    /// Seeds transcript (unless NoCache), intervals, and resume position for row 0.
    @MainActor
    static func prepare(
        podcastStore: PodcastStore,
        resumeStore: ResumePositionStore,
        settingsStore: SettingsStore,
        transcriptCache: TranscriptCache = .applicationSupport,
        intervalCache: IntervalCache = .applicationSupport
    ) throws {
        try FixtureLibrary.prepareSeededStore(podcastStore)

        guard let summary = podcastStore.allSubscriptions().first,
              let feed = podcastStore.subscription(forFeedURL: summary.feedURL),
              let episodeID = feed.episodes.first?.id
        else {
            throw FixtureTranscriptError.missingSeededEpisode
        }

        // Wipe any leftover transcript from a prior UITest launch (shared Application Support).
        try? transcriptCache.remove(episodeID: episodeID)

        let position = isLongFollowEnabled
            ? longFollowPlaybackPosition
            : (isScrollFollowEnabled ? scrollFollowPlaybackPosition : playbackPosition)
        try resumeStore.setPosition(position, for: episodeID)

        let targetWords = settingsStore.activeNormalizedTargetSet()
        try intervalCache.store(makeSkipIntervals(), episodeID: episodeID, targetWords: targetWords)

        if !isNoCacheEnabled {
            try transcriptCache.store(makeTranscript(), episodeID: episodeID)
        }
    }

    /// No-cache UITest / backfill path — real cache pipeline with deterministic ASR.
    static func makeAnalyzer() -> AnalysisPipeline {
        AnalysisPipeline(
            transcriber: FixtureTranscriptASR(),
            cache: .applicationSupport,
            transcriptCache: .applicationSupport
        )
    }

    /// Clears leftover transcript files for seeded library episodes (AC9 progressive negative).
    @MainActor
    static func clearSeededTranscripts(
        podcastStore: PodcastStore,
        transcriptCache: TranscriptCache = .applicationSupport
    ) {
        for summary in podcastStore.allSubscriptions() {
            guard let feed = podcastStore.subscription(forFeedURL: summary.feedURL) else { continue }
            for episode in feed.episodes {
                try? transcriptCache.remove(episodeID: episode.id)
            }
        }
    }
}

private enum FixtureTranscriptError: Error {
    case missingSeededEpisode
}

private struct FixtureTranscriptASR: ASRTranscribing, Sendable {
    func transcribe(fileURL: URL) async throws -> [TimedWord] {
        _ = fileURL
        return FixtureTranscript.makeTranscript()
    }
}
