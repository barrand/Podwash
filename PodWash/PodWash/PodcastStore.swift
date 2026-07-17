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

    /// Feed description for TopicCard construction (topic-llm-v1).
    func feedDescription(feedURL: URL) -> String? {
        context.performAndWait {
            self.fetchPodcast(feedURLString: feedURL.absoluteString)?.feedDescription
        }
    }

    /// First match across subscriptions (`CDEpisode.id` is globally unique). ADR-027 bootstrap.
    func episodeLookup(id: String) -> (episode: Episode, podcastTitle: String, feedURL: URL)? {
        context.performAndWait {
            let request = CDEpisode.fetchRequest()
            request.predicate = NSPredicate(format: "id == %@", id)
            request.fetchLimit = 1
            guard let row = try? self.context.fetch(request).first,
                  let podcast = row.podcast,
                  let feedURLString = podcast.feedURLString,
                  !feedURLString.isEmpty,
                  let feedURL = URL(string: feedURLString)
            else {
                return nil
            }
            let episode = Episode(
                id: row.id ?? "",
                title: row.title ?? "",
                pubDate: row.pubDate ?? Date(timeIntervalSince1970: 0),
                artworkURL: row.artworkURLString.flatMap(URL.init(string:)),
                showNotes: row.showNotes,
                audioURL: row.audioURLString.flatMap(URL.init(string:))
            )
            return (episode, podcast.title ?? "", feedURL)
        }
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
                podcast = existing
            } else if let legacy = self.fetchLegacyUnkeyedPodcast() {
                // Reclaim pre–Slice 22 rows that migrated with empty feedURLString.
                legacy.feedURLString = key
                podcast = legacy
            } else {
                podcast = CDPodcast(context: self.context)
                podcast.feedURLString = key
                podcast.subscribedAt = Date()
                podcast.channelCleaningEnabled = true
                podcast.channelUnrelatedContentEnabled = true
            }

            podcast.title = title
            podcast.artworkURLString = artworkURL?.absoluteString
            podcast.feedDescription = feed.description
            if let collectionId {
                podcast.collectionId = NSNumber(value: collectionId)
            }

            // CDEpisode.id is globally unique (ADR-009/014). Drop any existing rows with
            // these IDs — including this podcast's prior set and collisions left by other
            // fixture subscriptions — before inserting replacements.
            let incomingIDs = feed.episodes.map(\.id).filter { !$0.isEmpty }
            var preservedEpisodeState: [String: (
                downloadStateRaw: String?,
                playbackPosition: Double,
                isPlayed: Bool,
                dismissedFromAutoplay: Bool
            )] = [:]
            if !incomingIDs.isEmpty {
                let conflictRequest = CDEpisode.fetchRequest()
                conflictRequest.predicate = NSPredicate(format: "id IN %@", incomingIDs)
                for row in try self.context.fetch(conflictRequest) {
                    if let id = row.id {
                        preservedEpisodeState[id] = (
                            downloadStateRaw: row.downloadStateRaw,
                            playbackPosition: row.playbackPosition,
                            isPlayed: row.isPlayed,
                            dismissedFromAutoplay: row.dismissedFromAutoplay
                        )
                    }
                    self.context.delete(row)
                }
            } else if let existingEpisodes = podcast.episodes?.array as? [CDEpisode] {
                for row in existingEpisodes {
                    self.context.delete(row)
                }
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
                if let preserved = preservedEpisodeState[episode.id] {
                    row.downloadStateRaw = preserved.downloadStateRaw ?? "notDownloaded"
                    row.playbackPosition = preserved.playbackPosition
                    row.isPlayed = preserved.isPlayed
                    row.dismissedFromAutoplay = preserved.dismissedFromAutoplay
                } else {
                    row.playbackPosition = 0
                    row.isPlayed = false
                    row.downloadStateRaw = "notDownloaded"
                    row.dismissedFromAutoplay = false
                }
                row.episodeCleaningEnabled = false
                row.podcast = podcast
                ordered.add(row)
            }
            podcast.episodes = ordered

            try self.context.save()
        }
    }

    // MARK: - Smart autoplay (ADR-029)

    func isBinge(feedURL: URL) -> Bool {
        context.performAndWait {
            self.fetchPodcast(feedURLString: feedURL.absoluteString)?.isBinge ?? false
        }
    }

    func setBinge(_ enabled: Bool, feedURL: URL) throws {
        try context.performAndWait {
            guard let podcast = self.fetchPodcast(feedURLString: feedURL.absoluteString) else { return }
            podcast.isBinge = enabled
            try self.context.save()
        }
    }

    func touchLastHeard(feedURL: URL, at date: Date = Date()) throws {
        try context.performAndWait {
            guard let podcast = self.fetchPodcast(feedURLString: feedURL.absoluteString) else { return }
            podcast.lastHeardAt = date
            try self.context.save()
        }
    }

    func setDismissedFromAutoplay(_ dismissed: Bool, episodeID: String) throws {
        try context.performAndWait {
            let request = CDEpisode.fetchRequest()
            request.predicate = NSPredicate(format: "id == %@", episodeID)
            request.fetchLimit = 1
            guard let row = try self.context.fetch(request).first else { return }
            row.dismissedFromAutoplay = dismissed
            try self.context.save()
        }
    }

    func isDismissedFromAutoplay(episodeID: String) -> Bool {
        context.performAndWait {
            let request = CDEpisode.fetchRequest()
            request.predicate = NSPredicate(format: "id == %@", episodeID)
            request.fetchLimit = 1
            return (try? self.context.fetch(request).first)?.dismissedFromAutoplay ?? false
        }
    }

    /// Catalog for `SmartOrderEngine` (includes played/dismissed flags).
    func smartOrderShows() -> [SmartOrderShow] {
        context.performAndWait {
            let request = CDPodcast.fetchRequest()
            request.sortDescriptors = [
                NSSortDescriptor(key: "subscribedAt", ascending: true),
                NSSortDescriptor(key: "feedURLString", ascending: true),
            ]
            let rows = (try? self.context.fetch(request)) ?? []
            return rows.compactMap { podcast -> SmartOrderShow? in
                guard let feedURLString = podcast.feedURLString,
                      let feedURL = URL(string: feedURLString),
                      !feedURLString.isEmpty
                else { return nil }
                let episodes = (podcast.episodes?.array as? [CDEpisode] ?? []).map { row in
                    SmartOrderEpisode(
                        id: row.id ?? "",
                        title: row.title ?? "",
                        pubDate: row.pubDate ?? Date(timeIntervalSince1970: 0),
                        isPlayed: row.isPlayed,
                        playbackPosition: row.playbackPosition,
                        dismissedFromAutoplay: row.dismissedFromAutoplay
                    )
                }
                return SmartOrderShow(
                    feedURL: feedURL,
                    title: podcast.title ?? "",
                    isBinge: podcast.isBinge,
                    lastHeardAt: podcast.lastHeardAt,
                    episodes: episodes
                )
            }
        }
    }

    private func fetchPodcast(feedURLString: String) -> CDPodcast? {
        let request = CDPodcast.fetchRequest()
        request.predicate = NSPredicate(format: "feedURLString == %@", feedURLString)
        request.fetchLimit = 1
        return try? context.fetch(request).first
    }

    /// Single legacy row from before multi-sub keyed by `feedURLString` (default `""`).
    private func fetchLegacyUnkeyedPodcast() -> CDPodcast? {
        let request = CDPodcast.fetchRequest()
        request.predicate = NSPredicate(format: "feedURLString == %@ OR feedURLString == nil", "")
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
