//
//  ITunesGoldenFixtures.swift
//  PodWashTests
//
//  Slice 22 — Hand-authored iTunes Search JSON goldens (ADR-014 §3, §8).
//  Provenance: Fixtures/itunes/README.md (not live-captured).
//

import Foundation
import XCTest
@testable import PodWash

// MARK: - Golden decode (independent of ITunesSearchClient)

struct ITunesGoldenEntry: Decodable, Equatable {
    let collectionId: Int
    let collectionName: String
    let feedUrl: String
    let artworkUrl600: String?
}

struct ITunesGoldenResponse: Decodable, Equatable {
    let results: [ITunesGoldenEntry]
}

enum ITunesGoldenFixtures {

    static let pinnedSearchTerm = "fixture-query"

    static let popularURLString =
        "https://itunes.apple.com/search?term=podcast&media=podcast&entity=podcast&limit=25"

    static func fixtureData(
        _ name: String,
        extension ext: String,
        file: StaticString = #filePath,
        line: UInt = #line
    ) throws -> Data {
        let bundle = Bundle(for: ITunesFixtureBundleToken.self)
        if let url = bundle.url(forResource: name, withExtension: ext, subdirectory: "Fixtures/itunes")
            ?? bundle.url(forResource: name, withExtension: ext) {
            return try Data(contentsOf: url)
        }
        let sourceURL = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .appendingPathComponent("Fixtures/itunes/\(name).\(ext)")
        if FileManager.default.fileExists(atPath: sourceURL.path) {
            return try Data(contentsOf: sourceURL)
        }
        XCTFail(
            "Missing fixture '\(name).\(ext)' (not in test bundle nor at \(sourceURL.path))",
            file: file,
            line: line
        )
        throw CocoaError(.fileNoSuchFile)
    }

    static func loadPopularGolden() throws -> ITunesGoldenResponse {
        let data = try fixtureData("itunes_popular_response", extension: "json")
        return try JSONDecoder().decode(ITunesGoldenResponse.self, from: data)
    }

    static func loadSearchGolden() throws -> ITunesGoldenResponse {
        let data = try fixtureData("itunes_search_response", extension: "json")
        return try JSONDecoder().decode(ITunesGoldenResponse.self, from: data)
    }

    static func popularResults() throws -> [PodcastSearchResult] {
        try loadPopularGolden().results.map(makeSearchResult(from:))
    }

    static func searchResults() throws -> [PodcastSearchResult] {
        try loadSearchGolden().results.map(makeSearchResult(from:))
    }

    static func makeSearchResult(from entry: ITunesGoldenEntry) -> PodcastSearchResult {
        PodcastSearchResult(
            collectionId: entry.collectionId,
            title: entry.collectionName,
            feedURL: URL(string: entry.feedUrl)!,
            artworkURL: entry.artworkUrl600.flatMap(URL.init(string:))
        )
    }

    /// Maps fixture feed URLs to bundled RSS XML for URLProtocol stubs.
    static func rssPayload(for feedURL: URL) throws -> Data {
        let path = feedURL.path
        if path.hasSuffix("popular-beta") {
            return try fixtureData("second_feed", extension: "xml")
        }
        if path.contains("/feeds/") {
            return try FixtureFeedLoader.fixtureData("sample_feed", extension: "xml")
        }
        throw URLError(.fileDoesNotExist)
    }

    static func searchURL(for term: String) -> URL {
        var components = URLComponents(string: "https://itunes.apple.com/search")!
        components.queryItems = [
            URLQueryItem(name: "term", value: term),
            URLQueryItem(name: "media", value: "podcast"),
            URLQueryItem(name: "entity", value: "podcast"),
            URLQueryItem(name: "limit", value: "25"),
        ]
        return components.url!
    }
}

private final class ITunesFixtureBundleToken {}
