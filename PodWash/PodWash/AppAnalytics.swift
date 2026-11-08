//
//  AppAnalytics.swift
//  PodWash
//
//  Product analytics. Podcast titles are sent for subscription changes and
//  podcast/episode titles for playback; never pass RSS URLs, transcript/audio
//  content, user-entered words, or a custom user identifier.
//

import Foundation
import TelemetryDeck

enum PodWashAnalytics {
    static let appID = "CFEEBFA0-0E60-4159-9246-0127CAC933A7"

    static func initialize() {
        TelemetryDeck.initialize(config: .init(appID: appID))
    }

    /// Records a predefined product action. Callers must not include listener-entered
    /// values in parameters; titles are handled by the dedicated methods below.
    static func action(_ name: String, parameters: [String: String] = [:]) {
        TelemetryDeck.signal("PodWash.\(name)", parameters: parameters)
    }

    static func subscriptionChanged(_ change: String, podcastTitle: String) {
        let normalized = podcastTitle.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !normalized.isEmpty else {
            TelemetryDeck.signal(
                "PodWash.Library.subscriptionChanged",
                parameters: ["change": change]
            )
            return
        }
        // A title is deliberately collected only for the requested subscription
        // insight; cap it so malformed feeds cannot create oversized payloads.
        TelemetryDeck.signal(
            "PodWash.Library.subscriptionChanged",
            parameters: [
                "change": change,
                "podcastTitle": String(normalized.prefix(200)),
            ]
        )
    }

    static func episodePlaybackChanged(
        _ change: String,
        episodeTitle: String,
        podcastTitle: String
    ) {
        let normalizedEpisode = episodeTitle.trimmingCharacters(in: .whitespacesAndNewlines)
        let normalizedPodcast = podcastTitle.trimmingCharacters(in: .whitespacesAndNewlines)
        var parameters = ["change": change]
        if !normalizedEpisode.isEmpty {
            parameters["episodeTitle"] = String(normalizedEpisode.prefix(200))
        }
        if !normalizedPodcast.isEmpty {
            parameters["podcastTitle"] = String(normalizedPodcast.prefix(200))
        }
        TelemetryDeck.signal(
            "PodWash.Playback.episodeChanged",
            parameters: parameters
        )
    }

    static func featureStateChanged(_ feature: String, isEnabled: Bool) {
        action(
            "Settings.featureStateChanged",
            parameters: ["feature": feature, "enabled": isEnabled ? "true" : "false"]
        )
    }

    /// Aggregate download health signals. Parameters are deliberately low-cardinality
    /// and exclude podcast titles, enclosure URLs, and listener identifiers.
    static func downloadStarted(allowsCellular: Bool) {
        action("Download.started", parameters: ["allowsCellular": allowsCellular ? "true" : "false"])
    }

    static func downloadCompleted(bytes: Int64, redirects: Int) {
        action("Download.completed", parameters: [
            "byteBucket": byteBucket(bytes),
            "redirectBucket": redirectBucket(redirects),
        ])
    }

    static func downloadFailed(
        category: String,
        phase: String,
        httpStatusClass: String,
        bytes: Int64,
        redirects: Int,
        allowsCellular: Bool
    ) {
        action("Download.failed", parameters: [
            "category": category,
            "phase": phase,
            "httpStatusClass": httpStatusClass,
            "byteBucket": byteBucket(bytes),
            "redirectBucket": redirectBucket(redirects),
            "allowsCellular": allowsCellular ? "true" : "false",
        ])
    }

    private static func byteBucket(_ bytes: Int64) -> String {
        switch bytes {
        case 0: return "zero"
        case 1 ..< 1_000_000: return "under1MB"
        case 1_000_000 ..< 10_000_000: return "1to10MB"
        default: return "over10MB"
        }
    }

    private static func redirectBucket(_ redirects: Int) -> String {
        switch redirects {
        case 0: return "zero"
        case 1: return "one"
        case 2: return "two"
        default: return "threePlus"
        }
    }
}
