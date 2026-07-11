//
//  DiscoverViewModel.swift
//  PodWash
//
//  Slice 22 — Discover popular/search/subscribe orchestration (ADR-014 §6).
//

import Foundation

@MainActor @Observable
final class DiscoverViewModel {
    enum LoadPhase: Equatable {
        case idle
        case loading
        case loaded
        case failed
    }

    enum SubscribeState: Equatable {
        case idle
        case loading(index: Int)
        case succeeded(index: Int)
        case failed
    }

    private(set) var popularResults: [PodcastSearchResult] = []
    private(set) var searchResults: [PodcastSearchResult] = []
    private(set) var loadPhase: LoadPhase = .idle
    private(set) var searchPhase: LoadPhase = .idle
    private(set) var subscribeState: SubscribeState = .idle
    private(set) var searchTerm: String = ""

    private let searchClient: ITunesSearchClient
    private let parser: RSSParser
    private let store: PodcastStore
    private let searchDebounceNanoseconds: UInt64
    private var searchTask: Task<Void, Never>?

    init(
        searchClient: ITunesSearchClient,
        parser: RSSParser,
        store: PodcastStore,
        searchDebounceNanoseconds: UInt64 = 300_000_000
    ) {
        self.searchClient = searchClient
        self.parser = parser
        self.store = store
        self.searchDebounceNanoseconds = searchDebounceNanoseconds
    }

    // Avoid MainActor/TaskLocal deinit crash under SWIFT_DEFAULT_ACTOR_ISOLATION.
    nonisolated deinit {}

    func loadPopular() async {
        loadPhase = .loading
        do {
            popularResults = try await searchClient.fetchPopular()
            loadPhase = .loaded
        } catch {
            popularResults = []
            loadPhase = .failed
        }
    }

    func search(term: String) async {
        searchTerm = term
        let trimmed = term.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            searchResults = []
            searchPhase = .idle
            return
        }

        searchPhase = .loading
        do {
            searchResults = try await searchClient.search(term: trimmed)
            searchPhase = .loaded
        } catch {
            searchResults = []
            searchPhase = .failed
        }
    }

    func scheduleSearch(term: String) {
        searchTerm = term
        searchTask?.cancel()
        let trimmed = term.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.isEmpty {
            searchResults = []
            searchPhase = .idle
            return
        }
        searchTask = Task {
            if searchDebounceNanoseconds > 0 {
                try? await Task.sleep(nanoseconds: searchDebounceNanoseconds)
            }
            guard !Task.isCancelled else { return }
            await search(term: term)
        }
    }

    func subscribe(atIndex index: Int) async {
        let active = searchResults.isEmpty ? popularResults : searchResults
        guard active.indices.contains(index) else { return }
        let result = active[index]

        if store.isSubscribed(feedURL: result.feedURL) {
            subscribeState = .succeeded(index: index)
            return
        }

        subscribeState = .loading(index: index)
        do {
            let feed = try await parser.parse(url: result.feedURL)
            try store.saveSubscription(from: result, feed: feed)
            subscribeState = .succeeded(index: index)
        } catch {
            subscribeState = .failed
        }
    }

    func isSubscribed(feedURL: URL) -> Bool {
        store.isSubscribed(feedURL: feedURL)
    }
}
