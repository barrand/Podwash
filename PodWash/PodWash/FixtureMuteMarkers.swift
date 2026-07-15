//
//  FixtureMuteMarkers.swift
//  PodWash
//
//  Slice 27 — Launch-argument mute-marker UITest fixtures (ADR-023 §7 / slice-27-ux.md).
//

import Foundation

enum FixtureMuteMarkers {
    static let launchArgument = "-UITestFixtureMuteMarkers"
    static let adsOnlyLaunchArgument = "-UITestFixtureMuteMarkersAdsOnly"

    static let episodeDuration = 120.0

    /// Pinned mute intervals (≥ 2) — mirrors progressive first-chunk partials.
    static let muteIntervals: [CensorInterval] = [
        CensorInterval(start: 0.92, end: 1.87, action: .mute, source: .profanity),
        CensorInterval(start: 2.92, end: 3.32, action: .mute, source: .profanity),
    ]

    /// Ads-only control — yellow buckets, zero mute markers.
    static let adsOnlyIntervals: [CensorInterval] = [
        CensorInterval(
            start: FixtureTranscript.unrelatedSkipStart,
            end: FixtureTranscript.unrelatedSkipEnd,
            action: .skip,
            source: .unrelatedContent
        ),
    ]

    /// Primary mute-markers fixture (not ads-only).
    static var isEnabled: Bool {
        ProcessInfo.processInfo.arguments.contains { argument in
            argument == launchArgument
                || (argument.hasSuffix("UITestFixtureMuteMarkers")
                    && !argument.contains("AdsOnly"))
        }
    }

    static var isAdsOnlyEnabled: Bool {
        ProcessInfo.processInfo.arguments.contains { argument in
            argument == adsOnlyLaunchArgument
                || argument.hasSuffix("UITestFixtureMuteMarkersAdsOnly")
        }
    }

    static var isAnyEnabled: Bool {
        isEnabled || isAdsOnlyEnabled
    }

    static func makeIntervals() -> [CensorInterval] {
        if isAdsOnlyEnabled {
            return adsOnlyIntervals
        }
        return muteIntervals
    }

    static func bundledURL(in bundle: Bundle = .main) -> URL? {
        FixtureProgressivePlayback.bundledURL(in: bundle)
    }

    /// Seeds Library + channel cleaning on for immediate-complete mute-marker UITests.
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
