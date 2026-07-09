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
    private let store: InMemoryPodcastStore

    init(parser: RSSParser, store: InMemoryPodcastStore) {
        self.parser = parser
        self.store = store
    }

    func load(feedURL: URL) async {
        phase = .loading
        do {
            let feed = try await parser.parse(url: feedURL)
            store.save(feed)
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
            store.save(feed)
            phase = .loaded(feed)
        } catch let error as RSSParserError {
            phase = .failed(error)
        } catch {
            phase = .failed(.malformedFeed)
        }
    }
}
