//
//  FixtureCleaningSummary.swift
//  PodWash
//
//  Slice 29 — Launch-argument cleaning-summary UITest fixture (ADR-025 §5).
//

import Foundation

enum FixtureCleaningSummary {
    static let launchArgument = "-UITestFixtureCleaningSummary"

    /// Pinned intervals (slice-29 AC1 — independent provenance).
    static let pinnedIntervals: [CensorInterval] = [
        CensorInterval(start: 10.0, end: 11.0, action: .mute, source: .profanity),
        CensorInterval(start: 20.0, end: 21.5, action: .mute, source: .profanity),
        CensorInterval(start: 30.0, end: 90.0, action: .skip, source: .unrelatedContent),
        CensorInterval(start: 100.0, end: 130.0, action: .skip, source: .unrelatedContent),
    ]

    static var isEnabled: Bool {
        ProcessInfo.processInfo.arguments.contains { argument in
            argument == launchArgument || argument.hasSuffix("UITestFixtureCleaningSummary")
        }
    }

    /// Seeds IntervalCache for row 0 with pinned intervals; analysis not in-flight.
    @MainActor
    static func prepare(
        podcastStore: PodcastStore,
        settingsStore: SettingsStore,
        intervalCache: IntervalCache = .applicationSupport
    ) throws {
        guard let summary = podcastStore.allSubscriptions().first,
              let feed = podcastStore.subscription(forFeedURL: summary.feedURL),
              let episodeID = feed.episodes.first?.id
        else {
            throw FixtureCleaningSummaryError.missingSeededEpisode
        }

        let targetWords = settingsStore.activeNormalizedTargetSet()
        try intervalCache.store(pinnedIntervals, episodeID: episodeID, targetWords: targetWords)
    }

    /// Wipe shared Application Support interval files so Feed-only launches stay cache-miss (AC4).
    static func clearIntervalCache(_ intervalCache: IntervalCache = .applicationSupport) {
        try? intervalCache.clear()
    }
}

private enum FixtureCleaningSummaryError: Error {
    case missingSeededEpisode
}
