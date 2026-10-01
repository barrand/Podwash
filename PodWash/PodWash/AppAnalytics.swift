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
}
