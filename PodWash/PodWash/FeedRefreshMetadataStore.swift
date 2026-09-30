//
//  FeedRefreshMetadataStore.swift
//  PodWash
//

import Foundation

enum FeedRefreshFailureCategory: String, Codable, Equatable, Sendable {
    case network
    case timeout
    case malformedFeed
    case identityCollision
    case persistence
}

struct FeedRefreshMetadata: Codable, Equatable, Sendable {
    var lastAttempt: Date?
    var lastSuccess: Date?
    var etag: String?
    var lastModified: String?
    var consecutiveFailures: Int = 0
    var retryAfter: Date?
    var failureCategory: FeedRefreshFailureCategory?
}

protocol FeedRefreshMetadataStoring: Sendable {
    func metadata(for feedURL: URL) async -> FeedRefreshMetadata
    func save(_ metadata: FeedRefreshMetadata, for feedURL: URL) async
}

/// Actor isolation prevents concurrent feed completions from losing each
/// other's validator and retry metadata during a read-modify-write.
actor UserDefaultsFeedRefreshMetadataStore: FeedRefreshMetadataStoring {
    private let defaults: UserDefaults
    private let key: String

    init(defaults: UserDefaults = .standard, key: String = "podwash.feedRefresh.metadata.v2") {
        self.defaults = defaults
        self.key = key
    }

    func metadata(for feedURL: URL) -> FeedRefreshMetadata {
        all()[feedURL.absoluteString] ?? FeedRefreshMetadata()
    }

    func save(_ metadata: FeedRefreshMetadata, for feedURL: URL) {
        var values = all()
        values[feedURL.absoluteString] = metadata
        defaults.set(try? JSONEncoder().encode(values), forKey: key)
    }

    private func all() -> [String: FeedRefreshMetadata] {
        guard let data = defaults.data(forKey: key),
              let values = try? JSONDecoder().decode([String: FeedRefreshMetadata].self, from: data)
        else { return [:] }
        return values
    }
}
