//
//  CleaningSummaryModel.swift
//  PodWash
//
//  Slice 29 — Pure cleaning-summary aggregation from cached intervals (ADR-025).
//

import Foundation

/// Aggregated cleaning outcome for one episode’s cached interval list.
struct EpisodeCleaningSummary: Equatable, Sendable {
    var profanitySectionCount: Int
    var adSectionCount: Int
    /// Sum of `(end − start)` over `.unrelatedContent` intervals (seconds).
    var adDurationSeconds: Double
    /// Display string, e.g. `"1.5 min"`, `"0.0 min"`, `"0.8 min"`.
    var formattedAdMinutes: String
}

nonisolated enum CleaningSummaryModel {
    /// Aggregates from a **cache-hit** interval array (including empty `[]`).
    /// Callers must not invoke this for a cache miss (`load` → `nil`).
    static func summary(from intervals: [CensorInterval]) -> EpisodeCleaningSummary {
        let profanity = intervals.filter { $0.source == .profanity }
        let ads = intervals.filter { $0.source == .unrelatedContent }
        let adDurationSeconds = ads.reduce(0.0) { partial, interval in
            partial + max(0, interval.end - interval.start)
        }
        return EpisodeCleaningSummary(
            profanitySectionCount: profanity.count,
            adSectionCount: ads.count,
            adDurationSeconds: adDurationSeconds,
            formattedAdMinutes: formattedAdMinutes(adDurationSeconds: adDurationSeconds)
        )
    }

    /// One-decimal round-half-up minutes string from seconds (ADR-025 §4 / AC3).
    static func formattedAdMinutes(adDurationSeconds: Double) -> String {
        let minutes = adDurationSeconds / 60.0
        let rounded = floor(minutes * 10.0 + 0.5) / 10.0
        return String(format: "%.1f min", rounded)
    }

    /// Machine-readable AX value: `profanity:N,ads:N,adMinutes:X.X`.
    static func accessibilityValue(from summary: EpisodeCleaningSummary) -> String {
        let minutesNumeric = summary.formattedAdMinutes.replacingOccurrences(of: " min", with: "")
        return "profanity:\(summary.profanitySectionCount),ads:\(summary.adSectionCount),adMinutes:\(minutesNumeric)"
    }

    /// Human-readable row copy (slice-29-ux.md).
    static func visibleLabel(from summary: EpisodeCleaningSummary) -> String {
        let adNoun = summary.adSectionCount == 1 ? "ad" : "ads"
        return "\(summary.profanitySectionCount) profanity · \(summary.adSectionCount) \(adNoun) · \(summary.formattedAdMinutes) ads"
    }
}
