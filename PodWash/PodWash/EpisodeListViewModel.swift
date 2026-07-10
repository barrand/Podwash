//
//  EpisodeListViewModel.swift
//  PodWash
//
//  Slice 06 — Episode list load state (ADR-004).
//

import Foundation

@MainActor @Observable
final class EpisodeListViewModel {
    enum Phase: Equatable {
        case idle
        case loading
        case loaded(PodcastFeed)
        case failed(RSSParserError)
    }

    private(set) var phase: Phase = .idle

    private let parser: RSSParser
    private let store: PodcastStore

    init(parser: RSSParser, store: PodcastStore) {
        self.parser = parser
        self.store = store
    }

    /// Pre–Slice 11 tests construct `InMemoryPodcastStore()`.
    convenience init(parser: RSSParser, store: InMemoryPodcastStore) {
        self.init(parser: parser, store: store.backing)
    }

    func load(feedURL: URL) async {
        phase = .loading
        do {
            let feed = try await parser.parse(url: feedURL)
            try store.save(feed)
            phase = .loaded(feed)
        } catch let error as RSSParserError {
            phase = .failed(error)
        } catch {
            phase = .failed(.networkFailure)
        }
    }

    func load(data: Data) async {
        phase = .loading
        do {
            let feed = try parser.parse(data: data)
            try store.save(feed)
            phase = .loaded(feed)
        } catch let error as RSSParserError {
            phase = .failed(error)
        } catch {
            phase = .failed(.malformedFeed)
        }
    }
}
