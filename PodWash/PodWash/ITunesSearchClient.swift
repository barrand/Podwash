//
//  ITunesSearchClient.swift
//  PodWash
//
//  Slice 22 — iTunes Search API client (ADR-014 §2–§3).
//

import Foundation

struct PodcastSearchResult: Equatable, Identifiable, Sendable {
    var id: Int { collectionId }
    let collectionId: Int
    let title: String
    let feedURL: URL
    let artworkURL: URL?
}

struct PodcastSummary: Equatable, Identifiable, Sendable {
    var id: String { feedURL.absoluteString }
    let title: String
    let feedURL: URL
    let artworkURL: URL?
    let collectionId: Int?
}

enum ITunesSearchError: Error, Equatable, Sendable {
    case networkFailure
    case invalidResponse
}

struct ITunesSearchClient: Sendable {
    let session: URLSession
    let popularURL: URL

    static let defaultPopularURL = URL(
        string: "https://itunes.apple.com/search?term=podcast&media=podcast&entity=podcast&limit=25"
    )!

    init(
        session: URLSession = .shared,
        popularURL: URL = ITunesSearchClient.defaultPopularURL
    ) {
        self.session = session
        self.popularURL = popularURL
    }

    func fetchPopular() async throws -> [PodcastSearchResult] {
        try await fetchResults(from: popularURL)
    }

    func search(term: String) async throws -> [PodcastSearchResult] {
        let trimmed = term.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return [] }
        return try await fetchResults(from: Self.searchURL(for: trimmed))
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

    private func fetchResults(from url: URL) async throws -> [PodcastSearchResult] {
        let data: Data
        let response: URLResponse
        do {
            (data, response) = try await session.data(from: url)
        } catch {
            throw ITunesSearchError.networkFailure
        }

        guard let http = response as? HTTPURLResponse, (200 ..< 300).contains(http.statusCode) else {
            throw ITunesSearchError.invalidResponse
        }

        let decoded: ITunesSearchPayload
        do {
            decoded = try JSONDecoder().decode(ITunesSearchPayload.self, from: data)
        } catch {
            throw ITunesSearchError.invalidResponse
        }

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

private struct ITunesSearchPayload: Decodable {
    let results: [ITunesSearchEntry]
}

private struct ITunesSearchEntry: Decodable {
    let collectionId: Int
    let collectionName: String
    let feedUrl: String?
    let artworkUrl600: String?
    let artworkUrl100: String?
}
