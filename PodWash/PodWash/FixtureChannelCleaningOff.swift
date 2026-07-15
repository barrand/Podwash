//
//  FixtureChannelCleaningOff.swift
//  PodWash
//
//  Task 023 — UITest launch arg when a test needs channel cleaning off without
//  the removed podcast-detail toggle (slice-09 / task-023).
//

import Foundation

enum FixtureChannelCleaningOff {
    static let launchArgument = "-UITestChannelCleaningOff"

    static var isEnabled: Bool {
        ProcessInfo.processInfo.arguments.contains { argument in
            argument == launchArgument || argument.hasSuffix("UITestChannelCleaningOff")
        }
    }

    /// Applied after migrate/seed so explicit off wins over default-on channel flags.
    @MainActor
    static func applyIfNeeded(
        cleaningStore: CleaningToggleStore,
        podcastStore: PodcastStore
    ) throws {
        guard isEnabled else { return }
        for summary in podcastStore.allSubscriptions() {
            try cleaningStore.setChannelCleaning(forFeedURL: summary.feedURL, enabled: false)
        }
    }
}
