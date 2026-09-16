//
//  FeedRefreshCoordinator.swift
//

import Foundation

enum FeedRefreshResult: Equatable, Sendable { case refreshed, notModified, skipped, failed }

/// Process-lifetime feed refresh owner. Metadata is deliberately separate from
/// the catalog model so it is additive for existing SQLite stores.
actor FeedRefreshCoordinator {
    private struct Metadata: Codable, Sendable {
        var lastAttempt: Date?
        var lastSuccess: Date?
        var etag: String?
        var lastModified: String?
        var failures = 0
        var retryAfter: Date?
    }

    private let parser: RSSParser
    private let store: PodcastStore
    private let defaults: UserDefaults
    private var inFlight: [URL: Task<FeedRefreshResult, Never>] = [:]
    private let key = "podwash.feedRefresh.metadata.v1"

    init(parser: RSSParser = RSSParser(), store: PodcastStore, defaults: UserDefaults = .standard) {
        self.parser = parser; self.store = store; self.defaults = defaults
    }

    func refresh(feedURL: URL, force: Bool = false, now: Date = Date()) async -> FeedRefreshResult {
        if let task = inFlight[feedURL] { return await task.value }
        let metadata = load()[feedURL.absoluteString] ?? Metadata()
        if !force, let success = metadata.lastSuccess, now.timeIntervalSince(success) < 15 * 60 { return .skipped }
        if !force, let retry = metadata.retryAfter, retry > now { return .skipped }
        let startingMetadata = metadata
        let task = Task { [parser, store, defaults, key, startingMetadata] () -> FeedRefreshResult in
            var metadata = startingMetadata
            metadata.lastAttempt = now
            save(metadata, for: feedURL, defaults: defaults, key: key)
            do {
                let cachedValidators = FeedValidators(etag: metadata.etag, lastModified: metadata.lastModified)
                let response = try await withThrowingTaskGroup(of: FeedFetchResult.self) { group in
                    group.addTask { try await parser.fetcher.fetch(from: feedURL, validators: cachedValidators) }
                    group.addTask { try await Task.sleep(for: .seconds(30)); throw RSSParserError.networkFailure }
                    defer { group.cancelAll() }
                    return try await group.next()!
                }
                switch response {
                case let .notModified(validators):
                    metadata.lastSuccess = now; metadata.failures = 0; metadata.retryAfter = nil
                    metadata.etag = validators.etag; metadata.lastModified = validators.lastModified
                    save(metadata, for: feedURL, defaults: defaults, key: key)
                    return .notModified
                case let .modified(data, validators):
                    let feed = try parser.parse(data: data)
                guard store.isSubscribed(feedURL: feedURL) else { return .skipped }
                try store.mergeRefreshedFeed(feed, feedURL: feedURL)
                metadata.lastSuccess = now; metadata.failures = 0; metadata.retryAfter = nil
                metadata.etag = validators.etag; metadata.lastModified = validators.lastModified
                save(metadata, for: feedURL, defaults: defaults, key: key)
                return .refreshed
                }
            } catch {
                metadata.failures += 1
                let delays: [TimeInterval] = [15 * 60, 60 * 60, 6 * 60 * 60]
                metadata.retryAfter = now.addingTimeInterval(delays[min(metadata.failures - 1, 2)])
                save(metadata, for: feedURL, defaults: defaults, key: key)
                return .failed
            }
        }
        inFlight[feedURL] = task
        let result = await task.value
        inFlight[feedURL] = nil
        return result
    }

    func refreshAll(force: Bool = false, now: Date = Date()) async -> [URL: FeedRefreshResult] {
        let urls = store.allSubscriptions().map(\.feedURL)
        // A batch never opens more than three sockets.  Same-feed calls are
        // still coalesced by `refresh(feedURL:)`.
        var result: [URL: FeedRefreshResult] = [:]
        for batchStart in stride(from: 0, to: urls.count, by: 3) {
            let batch = Array(urls[batchStart ..< min(batchStart + 3, urls.count)])
            let values = await withTaskGroup(of: (URL, FeedRefreshResult).self, returning: [URL: FeedRefreshResult].self) { group in
                for url in batch { group.addTask { (url, await self.refresh(feedURL: url, force: force, now: now)) } }
                var partial: [URL: FeedRefreshResult] = [:]
                for await (url, value) in group { partial[url] = value }
                return partial
            }
            result.merge(values, uniquingKeysWith: { _, new in new })
        }
        return result
    }

    private func load() -> [String: Metadata] {
        guard let data = defaults.data(forKey: key), let value = try? JSONDecoder().decode([String: Metadata].self, from: data) else { return [:] }; return value
    }
    private func save(_ value: Metadata, for url: URL, defaults: UserDefaults, key: String) {
        var values: [String: Metadata] = {
            guard let data = defaults.data(forKey: key), let v = try? JSONDecoder().decode([String: Metadata].self, from: data) else { return [:] }; return v
        }()
        values[url.absoluteString] = value
        defaults.set(try? JSONEncoder().encode(values), forKey: key)
    }
}
