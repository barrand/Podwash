//
//  PodcastStore.swift
//  PodWash
//
//  Slice 11/22 — Core Data–backed multi-subscription persistence (ADR-009, ADR-014).
//

import CoreData
import Foundation

/// Feed/episode persistence. Opted out of module default MainActor isolation so
/// test helpers (nonisolated `FixtureFeedLoader`) can call `save` synchronously;
/// all Core Data work runs on the context queue via `performAndWait`.
nonisolated final class PodcastStore: @unchecked Sendable {
    nonisolated(unsafe) private let context: NSManagedObjectContext
    nonisolated(unsafe) private let retainedController: PersistenceController?

    init(context: NSManagedObjectContext, retaining controller: PersistenceController? = nil) {
        self.context = context
        self.retainedController = controller
    }

    /// Legacy no-arg store for pre–Slice 11 unit tests (`InMemoryPodcastStore`).
    convenience init() {
        let controller = PersistenceController.inMemory()
        self.init(context: controller.viewContext, retaining: controller)
    }

    /// Upsert by `result.feedURL`. Does not clear other subscriptions.
    func saveSubscription(from result: PodcastSearchResult, feed: PodcastFeed) throws {
        try upsert(
            feed: feed,
            feedURL: result.feedURL,
            title: result.title,
            artworkURL: result.artworkURL ?? feed.artworkURL,
            collectionId: result.collectionId
        )
    }

    /// Upsert by explicit feed URL (fixture / EpisodeListViewModel path).
    func save(_ feed: PodcastFeed, feedURL: URL) throws {
        try upsert(
            feed: feed,
            feedURL: feedURL,
            title: feed.title,
            artworkURL: feed.artworkURL,
            collectionId: nil
        )
    }

    /// Compatibility for pre–Slice 22 callers; upserts under `FixtureFeed.fixtureFeedURL`.
    func save(_ feed: PodcastFeed) throws {
        try save(feed, feedURL: FixtureFeed.fixtureFeedURL)
    }

    var subscriptionCount: Int {
        context.performAndWait {
            let request = CDPodcast.fetchRequest()
            return (try? self.context.count(for: request)) ?? 0
        }
    }

    func allSubscriptions() -> [PodcastSummary] {
        context.performAndWait {
            let request = CDPodcast.fetchRequest()
            request.sortDescriptors = [
                NSSortDescriptor(key: "subscribedAt", ascending: true),
                NSSortDescriptor(key: "feedURLString", ascending: true),
            ]
            let rows = (try? self.context.fetch(request)) ?? []
            return rows.compactMap { podcast -> PodcastSummary? in
                guard let feedURLString = podcast.feedURLString,
                      let feedURL = URL(string: feedURLString),
                      !feedURLString.isEmpty
                else { return nil }
                return PodcastSummary(
                    title: podcast.title ?? "",
                    feedURL: feedURL,
                    artworkURL: podcast.artworkURLString.flatMap(URL.init(string:)),
                    collectionId: podcast.collectionId.map { $0.intValue }
                )
            }
        }
    }

    func subscription(forFeedURL feedURL: URL) -> PodcastFeed? {
        context.performAndWait {
            guard let podcast = self.fetchPodcast(feedURLString: feedURL.absoluteString) else {
                return nil
            }
            return PodcastFeed(
                title: podcast.title ?? "",
                artworkURL: podcast.artworkURLString.flatMap(URL.init(string:)),
                description: podcast.feedDescription,
                episodes: self.episodes(for: podcast)
            )
        }
    }

    func isSubscribed(feedURL: URL) -> Bool {
        context.performAndWait {
            self.fetchPodcast(feedURLString: feedURL.absoluteString) != nil
        }
    }

    func clear() throws {
        try context.performAndWait {
            try self.clearPodcastRows()
            try self.context.save()
        }
    }

    /// Legacy single-feed read: first subscription by `allSubscriptions()` order, else nil.
    var currentFeed: PodcastFeed? {
        guard let summary = allSubscriptions().first else { return nil }
        return subscription(forFeedURL: summary.feedURL)
    }

    var episodes: [Episode] {
        currentFeed?.episodes ?? []
    }

    private func upsert(
        feed: PodcastFeed,
        feedURL: URL,
        title: String,
        artworkURL: URL?,
        collectionId: Int?
    ) throws {
        try context.performAndWait {
            let key = feedURL.absoluteString
            let podcast: CDPodcast
            if let existing = self.fetchPodcast(feedURLString: key) {
                if let existingEpisodes = existing.episodes?.array as? [CDEpisode] {
                    for row in existingEpisodes {
                        self.context.delete(row)
                    }
                }
                podcast = existing
            } else {
                podcast = CDPodcast(context: self.context)
                podcast.feedURLString = key
                podcast.subscribedAt = Date()
                podcast.channelCleaningEnabled = false
                podcast.channelUnrelatedContentEnabled = false
            }

            podcast.title = title
            podcast.artworkURLString = artworkURL?.absoluteString
            podcast.feedDescription = feed.description
            if let collectionId {
                podcast.collectionId = NSNumber(value: collectionId)
            }

            let ordered = NSMutableOrderedSet()
            for episode in feed.episodes {
                let row = CDEpisode(context: self.context)
                row.id = episode.id
                row.title = episode.title
                row.pubDate = episode.pubDate
                row.artworkURLString = episode.artworkURL?.absoluteString
                row.showNotes = episode.showNotes
                row.audioURLString = episode.audioURL?.absoluteString
                row.playbackPosition = 0
                row.isPlayed = false
                row.episodeCleaningEnabled = false
                row.downloadStateRaw = "notDownloaded"
                row.podcast = podcast
                ordered.add(row)
            }
            podcast.episodes = ordered

            try self.context.save()
        }
    }

    private func fetchPodcast(feedURLString: String) -> CDPodcast? {
        let request = CDPodcast.fetchRequest()
        request.predicate = NSPredicate(format: "feedURLString == %@", feedURLString)
        request.fetchLimit = 1
        return try? context.fetch(request).first
    }

    private func episodes(for podcast: CDPodcast) -> [Episode] {
        let rows = podcast.episodes?.array as? [CDEpisode] ?? []
        return rows.map { row in
            Episode(
                id: row.id ?? "",
                title: row.title ?? "",
                pubDate: row.pubDate ?? Date(timeIntervalSince1970: 0),
                artworkURL: row.artworkURLString.flatMap(URL.init(string:)),
                showNotes: row.showNotes,
                audioURL: row.audioURLString.flatMap(URL.init(string:))
            )
        }
    }

    private func clearPodcastRows() throws {
        let podcastRequest = CDPodcast.fetchRequest()
        for podcast in try context.fetch(podcastRequest) {
            context.delete(podcast)
        }
    }
}

/// Compatibility shim: non-throwing API for pre–Slice 11 tests.
nonisolated final class InMemoryPodcastStore: @unchecked Sendable {
    let backing: PodcastStore

    var currentFeed: PodcastFeed? { backing.currentFeed }

    init() {
        backing = PodcastStore()
    }

    func save(_ feed: PodcastFeed) {
        try? backing.save(feed)
    }

    func clear() {
        try? backing.clear()
    }
}
