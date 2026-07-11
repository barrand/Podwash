//
//  FixtureLibrary.swift
//  PodWash
//
//  Slice 23 — Launch-argument fixture mode for Library UI tests (ADR-015 §6).
//

import Foundation

enum FixtureLibrary {
    static let launchArgument = "-UITestFixtureLibrary"
    static let emptyLaunchArgument = "-UITestFixtureLibraryEmpty"

    static var isEnabled: Bool {
        ProcessInfo.processInfo.arguments.contains(launchArgument)
    }

    static var isEmptyEnabled: Bool {
        ProcessInfo.processInfo.arguments.contains(emptyLaunchArgument)
    }

    /// True when either Library fixture flag is present (seeded or empty).
    static var usesInMemoryPersistence: Bool {
        isEnabled || isEmptyEnabled
    }

    /// Seeds exactly 2 subscriptions with golden popular titles 0 and 1;
    /// namespaces episode IDs so two `sample_feed.xml` copies do not collide.
    static func prepareSeededStore(_ store: PodcastStore) throws {
        try store.clear()

        let results = try loadGoldenPopularResults()
        guard results.count >= 2 else {
            throw FixtureLibraryError.missingGoldenResults
        }

        guard let feedData = FixtureFeed.bundledData() else {
            throw FixtureLibraryError.missingSampleFeed
        }
        let parser = RSSParser()
        let baseFeed = try parser.parse(data: feedData)

        for index in 0 ..< 2 {
            let namespaced = namespacedFeed(baseFeed, showIndex: index)
            try store.saveSubscription(from: results[index], feed: namespaced)
        }
    }

    /// Ensures zero subscriptions for the empty-library UI test.
    static func prepareEmptyStore(_ store: PodcastStore) throws {
        try store.clear()
    }

    private static func namespacedFeed(_ feed: PodcastFeed, showIndex: Int) -> PodcastFeed {
        PodcastFeed(
            title: feed.title,
            artworkURL: feed.artworkURL,
            description: feed.description,
            episodes: feed.episodes.map { episode in
                Episode(
                    id: "lib-\(showIndex)-\(episode.id)",
                    title: episode.title,
                    pubDate: episode.pubDate,
                    artworkURL: episode.artworkURL,
                    showNotes: episode.showNotes,
                    audioURL: episode.audioURL
                )
            }
        )
    }

    private static func loadGoldenPopularResults(in bundle: Bundle = .main) throws -> [PodcastSearchResult] {
        let data: Data
        if let url = bundle.url(
            forResource: "itunes_popular_response",
            withExtension: "json",
            subdirectory: "Fixtures/itunes"
        ) ?? bundle.url(forResource: "itunes_popular_response", withExtension: "json") {
            data = try Data(contentsOf: url)
        } else {
            throw FixtureLibraryError.missingGoldenResults
        }

        let decoded = try JSONDecoder().decode(LibraryITunesPayload.self, from: data)
        return decoded.results.compactMap { entry in
            guard
                let feedUrlString = entry.feedUrl,
                !feedUrlString.isEmpty,
                let feedURL = URL(string: feedUrlString)
            else {
                return nil
            }
            let artwork = (entry.artworkUrl600 ?? entry.artworkUrl100).flatMap(URL.init(string:))
            return PodcastSearchResult(
                collectionId: entry.collectionId,
                title: entry.collectionName,
                feedURL: feedURL,
                artworkURL: artwork
            )
        }
    }
}

private enum FixtureLibraryError: Error {
    case missingGoldenResults
    case missingSampleFeed
}

private struct LibraryITunesPayload: Decodable {
    let results: [LibraryITunesEntry]
}

private struct LibraryITunesEntry: Decodable {
    let collectionId: Int
    let collectionName: String
    let feedUrl: String?
    let artworkUrl600: String?
    let artworkUrl100: String?
}
