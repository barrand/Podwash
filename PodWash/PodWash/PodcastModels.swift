//
//  PodcastModels.swift
//  PodWash
//
//  Slice 06 — RSS feed domain models (ADR-004).
//

import Foundation

struct Episode: Equatable, Identifiable, Codable {
    let id: String
    let title: String
    let pubDate: Date
    let artworkURL: URL?
    let showNotes: String?
    let audioURL: URL?
}

extension Episode {
    /// Orders a feed for display without relying on publisher or persistence
    /// insertion order. Equal publication dates retain their source order.
    static func newestFirst(_ episodes: [Episode]) -> [Episode] {
        episodes.enumerated()
            .sorted { lhs, rhs in
                if lhs.element.pubDate != rhs.element.pubDate {
                    return lhs.element.pubDate > rhs.element.pubDate
                }
                return lhs.offset < rhs.offset
            }
            .map(\.element)
    }
}

struct PodcastFeed: Equatable, Codable {
    let title: String
    let artworkURL: URL?
    let description: String?
    let episodes: [Episode]
}

enum RSSParserError: Error, Equatable {
    case networkFailure
    case malformedFeed
}
