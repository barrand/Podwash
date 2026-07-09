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
