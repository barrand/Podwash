//
//  FixturePrerollAdBands.swift
//  PodWash
//
//  Slice 33 — Launch-argument preroll ad-band UITest fixtures (ADR-030 §8 / slice-33-ux.md).
//

import Foundation

enum FixturePrerollAdBands {
    static let launchArgument = "-UITestFixturePrerollAdBands"
    static let withMutesLaunchArgument = "-UITestFixturePrerollAdBandsWithMutes"

    /// Pinned episode duration for AC6/AC7 (≥ 600.0 s).
    static let episodeDuration = 600.0

    /// Single preroll unrelated skip — yellow band width 30/600 = 0.0500.
    static let prerollSkip = CensorInterval(
        start: 0.0,
        end: 30.0,
        action: .skip,
        source: .unrelatedContent
    )

    /// Same mute pair as Slice 27 progressive / mute-marker fixtures.
    static let muteIntervals: [CensorInterval] = FixtureMuteMarkers.muteIntervals

    /// Primary preroll-only fixture (not with-mutes).
    static var isEnabled: Bool {
        ProcessInfo.processInfo.arguments.contains { argument in
            argument == launchArgument
                || (argument.hasSuffix("UITestFixturePrerollAdBands")
                    && !argument.contains("WithMutes"))
        }
    }

    static var isWithMutesEnabled: Bool {
        ProcessInfo.processInfo.arguments.contains { argument in
            argument == withMutesLaunchArgument
                || argument.hasSuffix("UITestFixturePrerollAdBandsWithMutes")
        }
    }

    static var isAnyEnabled: Bool {
        isEnabled || isWithMutesEnabled
    }

    static func makeIntervals() -> [CensorInterval] {
        if isWithMutesEnabled {
            return [prerollSkip] + muteIntervals
        }
        return [prerollSkip]
    }

    static func bundledURL(in bundle: Bundle = .main) -> URL? {
        FixtureProgressivePlayback.bundledURL(in: bundle)
    }

    /// Seeds Library + channel cleaning on for immediate-complete preroll UITests.
    @MainActor
    static func prepare(
        podcastStore: PodcastStore,
        cleaningStore: CleaningToggleStore
    ) throws {
        try FixtureLibrary.prepareSeededStore(podcastStore)
        for summary in podcastStore.allSubscriptions() {
            try cleaningStore.setChannelCleaning(forFeedURL: summary.feedURL, enabled: true)
        }
    }
}
