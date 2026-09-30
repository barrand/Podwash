//
//  FeedRefreshCoordinator.swift
//

import Foundation

enum FeedRefreshResult: Equatable, Sendable { case refreshed, notModified, skipped, failed }

struct FeedRefreshSummary: Equatable, Sendable {
    var refreshed = 0
    var notModified = 0
    var skipped = 0
    var failed = 0
    var total = 0

    init(_ values: [URL: FeedRefreshResult] = [:]) {
        total = values.count
        for value in values.values {
            switch value {
            case .refreshed: refreshed += 1
            case .notModified: notModified += 1
            case .skipped: skipped += 1
            case .failed: failed += 1
            }
        }
    }
}

/// Process-lifetime feed refresh owner. Metadata is deliberately separate from
/// the catalog model so it is additive for existing SQLite stores.
actor FeedRefreshCoordinator {
    private let parser: RSSParser
    private let store: any FeedRefreshCatalog
    private let metadataStore: any FeedRefreshMetadataStoring
    private let timing: any AppTiming
    private var inFlight: [URL: Task<FeedRefreshResult, Never>] = [:]
    init(
        parser: RSSParser = RSSParser(),
        store: any FeedRefreshCatalog,
        metadataStore: any FeedRefreshMetadataStoring = UserDefaultsFeedRefreshMetadataStore(),
        timing: any AppTiming = SystemAppTiming()
    ) {
        self.parser = parser
        self.store = store
        self.metadataStore = metadataStore
        self.timing = timing
    }

    func refresh(feedURL: URL, force: Bool = false) async -> FeedRefreshResult {
        if let task = inFlight[feedURL] { return await task.value }
        let now = await timing.now()
        let metadata = await metadataStore.metadata(for: feedURL)
        if !force, let success = metadata.lastSuccess, now.timeIntervalSince(success) < 15 * 60 { return .skipped }
        if !force, let retry = metadata.retryAfter, retry > now { return .skipped }
        let startingMetadata = metadata
        let task = Task { [parser, store, metadataStore, timing, startingMetadata] () -> FeedRefreshResult in
            var metadata = startingMetadata
            metadata.lastAttempt = await timing.now()
            await metadataStore.save(metadata, for: feedURL)
            do {
                let cachedValidators = FeedValidators(etag: metadata.etag, lastModified: metadata.lastModified)
                let response = try await withThrowingTaskGroup(of: FeedFetchResult.self) { group in
                    group.addTask { try await parser.fetcher.fetch(from: feedURL, validators: cachedValidators) }
                    group.addTask { try await timing.sleep(for: 30); throw FeedRefreshAttemptError.timeout }
                    defer { group.cancelAll() }
                    return try await group.next()!
                }
                let succeededAt = await timing.now()
                switch response {
                case let .notModified(validators):
                    metadata.lastSuccess = succeededAt; metadata.consecutiveFailures = 0; metadata.retryAfter = nil
                    metadata.etag = validators.etag; metadata.lastModified = validators.lastModified
                    metadata.failureCategory = nil
                    await metadataStore.save(metadata, for: feedURL)
                    return .notModified
                case let .modified(data, validators):
                    let feed = try parser.parse(data: data)
                    guard store.isSubscribed(feedURL: feedURL) else { return .skipped }
                    try store.mergeRefreshedFeed(feed, feedURL: feedURL)
                    metadata.lastSuccess = succeededAt; metadata.consecutiveFailures = 0; metadata.retryAfter = nil
                    metadata.etag = validators.etag; metadata.lastModified = validators.lastModified
                    metadata.failureCategory = nil
                    await metadataStore.save(metadata, for: feedURL)
                    return .refreshed
                }
            } catch {
                guard !Task.isCancelled else { return .skipped }
                metadata.consecutiveFailures += 1
                let delays: [TimeInterval] = [15 * 60, 60 * 60, 6 * 60 * 60]
                let failedAt = await timing.now()
                metadata.retryAfter = failedAt.addingTimeInterval(delays[min(metadata.consecutiveFailures - 1, 2)])
                metadata.failureCategory = Self.failureCategory(for: error)
                await metadataStore.save(metadata, for: feedURL)
                return .failed
            }
        }
        inFlight[feedURL] = task
        let result = await task.value
        inFlight[feedURL] = nil
        return result
    }

    func refreshAll(force: Bool = false) async -> [URL: FeedRefreshResult] {
        let urls = store.subscribedFeedURLs()
        // A batch never opens more than three sockets.  Same-feed calls are
        // still coalesced by `refresh(feedURL:)`.
        var result: [URL: FeedRefreshResult] = [:]
        for batchStart in stride(from: 0, to: urls.count, by: 3) {
            let batch = Array(urls[batchStart ..< min(batchStart + 3, urls.count)])
            let values = await withTaskGroup(of: (URL, FeedRefreshResult).self, returning: [URL: FeedRefreshResult].self) { group in
                for url in batch { group.addTask { (url, await self.refresh(feedURL: url, force: force)) } }
                var partial: [URL: FeedRefreshResult] = [:]
                for await (url, value) in group { partial[url] = value }
                return partial
            }
            result.merge(values, uniquingKeysWith: { _, new in new })
        }
        return result
    }

    func recordSuccessfulValidation(feedURL: URL, validators: FeedValidators? = nil) async {
        var metadata = await metadataStore.metadata(for: feedURL)
        let now = await timing.now()
        metadata.lastAttempt = now
        metadata.lastSuccess = now
        metadata.consecutiveFailures = 0
        metadata.retryAfter = nil
        metadata.failureCategory = nil
        metadata.etag = validators?.etag
        metadata.lastModified = validators?.lastModified
        await metadataStore.save(metadata, for: feedURL)
    }

    private static func failureCategory(for error: Error) -> FeedRefreshFailureCategory {
        if error is FeedRefreshAttemptError { return .timeout }
        if let parserError = error as? RSSParserError {
            switch parserError {
            case .networkFailure: return .network
            case .malformedFeed: return .malformedFeed
            }
        }
        return .persistence
    }
}

private enum FeedRefreshAttemptError: Error { case timeout }
