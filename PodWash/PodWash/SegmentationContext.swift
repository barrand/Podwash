//
//  SegmentationContext.swift
//  PodWash
//
//  Topic-LLM ad detection — show/episode text for TopicCard construction.
//

import Foundation

/// RSS / library metadata passed into topic-based content segmentation.
nonisolated struct SegmentationContext: Equatable, Sendable {
    var showTitle: String
    var showDescription: String
    var episodeTitle: String
    var episodeDescription: String

    static let empty = SegmentationContext(
        showTitle: "",
        showDescription: "",
        episodeTitle: "",
        episodeDescription: ""
    )

    /// Trim long RSS HTML-ish blobs for model prompts.
    func trimmed(maxChars: Int = 800) -> SegmentationContext {
        SegmentationContext(
            showTitle: showTitle,
            showDescription: Self.clip(showDescription, maxChars: maxChars),
            episodeTitle: episodeTitle,
            episodeDescription: Self.clip(episodeDescription, maxChars: maxChars)
        )
    }

    private static func clip(_ raw: String, maxChars: Int) -> String {
        let stripped = raw
            .replacingOccurrences(of: "<[^>]+>", with: " ", options: .regularExpression)
            .replacingOccurrences(of: "\\s+", with: " ", options: .regularExpression)
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard stripped.count > maxChars else { return stripped }
        return String(stripped.prefix(maxChars)) + "…"
    }
}
