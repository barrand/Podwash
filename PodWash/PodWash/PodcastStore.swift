//
//  PodcastStore.swift
//  PodWash
//
//  Slice 11 — Core Data–backed feed/episode persistence (ADR-009 §4).
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

    func save(_ feed: PodcastFeed) throws {
        try context.performAndWait {
            try self.clearPodcastRows()

            let podcast = CDPodcast(context: self.context)
            podcast.title = feed.title
            podcast.artworkURLString = feed.artworkURL?.absoluteString
            podcast.feedDescription = feed.description
            podcast.channelCleaningEnabled = false

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

    func clear() throws {
        try context.performAndWait {
            try self.clearPodcastRows()
            try self.context.save()
        }
    }

    var currentFeed: PodcastFeed? {
        context.performAndWait {
            guard let podcast = self.fetchPodcast() else { return nil }
            return PodcastFeed(
                title: podcast.title ?? "",
                artworkURL: podcast.artworkURLString.flatMap(URL.init(string:)),
                description: podcast.feedDescription,
                episodes: self.episodes(for: podcast)
            )
        }
    }

    var episodes: [Episode] {
        currentFeed?.episodes ?? []
    }

    private func fetchPodcast() -> CDPodcast? {
        let request = CDPodcast.fetchRequest()
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
