//
//  CleaningToggleStore.swift
//  PodWash
//
//  Slice 11 — Channel + per-episode cleaning flags (ADR-009 §4).
//

import CoreData
import Foundation

@MainActor
final class CleaningToggleStore {
    nonisolated(unsafe) private let context: NSManagedObjectContext
    nonisolated(unsafe) private let retainedController: PersistenceController?

    init(context: NSManagedObjectContext, retaining controller: PersistenceController? = nil) {
        self.context = context
        self.retainedController = controller
    }

    /// Legacy no-arg store for pre–Slice 11 unit tests (`InMemoryCleaningToggleStore`).
    convenience init() {
        let controller = PersistenceController.inMemory()
        self.init(context: controller.viewContext, retaining: controller)
    }

    // Avoid MainActor/TaskLocal deinit crash (same pattern as AnalysisUIViewModel).
    nonisolated deinit {}

    var isChannelCleaningEnabled: Bool {
        fetchPodcast()?.channelCleaningEnabled ?? false
    }

    /// Episode IDs with cleaning enabled (AnalysisUIViewModel / legacy tests).
    var enabledEpisodeIDs: Set<String> {
        let request = CDEpisode.fetchRequest()
        request.predicate = NSPredicate(format: "episodeCleaningEnabled == YES")
        let rows = (try? context.fetch(request)) ?? []
        return Set(rows.compactMap(\.id))
    }

    func isEpisodeCleaningEnabled(_ episodeID: String) -> Bool {
        fetchEpisode(id: episodeID)?.episodeCleaningEnabled ?? false
    }

    func setChannelCleaning(_ enabled: Bool) throws {
        let podcast = requirePodcast()
        podcast.channelCleaningEnabled = enabled
        try context.save()
    }

    func setEpisodeCleaning(_ episodeID: String, enabled: Bool) throws {
        let episode = requireEpisode(id: episodeID)
        episode.episodeCleaningEnabled = enabled
        try context.save()
    }

    private func fetchPodcast() -> CDPodcast? {
        let request = CDPodcast.fetchRequest()
        request.fetchLimit = 1
        return try? context.fetch(request).first
    }

    private func fetchEpisode(id: String) -> CDEpisode? {
        let request = CDEpisode.fetchRequest()
        request.predicate = NSPredicate(format: "id == %@", id)
        request.fetchLimit = 1
        return try? context.fetch(request).first
    }

    private func requirePodcast() -> CDPodcast {
        if let podcast = fetchPodcast() {
            return podcast
        }
        let podcast = CDPodcast(context: context)
        podcast.title = ""
        podcast.channelCleaningEnabled = false
        return podcast
    }

    private func requireEpisode(id: String) -> CDEpisode {
        if let episode = fetchEpisode(id: id) {
            return episode
        }
        let episode = CDEpisode(context: context)
        episode.id = id
        episode.title = id
        episode.pubDate = Date(timeIntervalSince1970: 0)
        episode.playbackPosition = 0
        episode.isPlayed = false
        episode.episodeCleaningEnabled = false
        episode.downloadStateRaw = "notDownloaded"
        if let podcast = fetchPodcast() {
            episode.podcast = podcast
        }
        return episode
    }
}

/// Compatibility shim: non-throwing API for pre–Slice 11 tests.
@MainActor
final class InMemoryCleaningToggleStore: CleaningToggleStoring {
    nonisolated(unsafe) private let store: CleaningToggleStore

    init() {
        store = CleaningToggleStore()
    }

    // Avoid MainActor/TaskLocal deinit crash (same pattern as AnalysisUIViewModel).
    nonisolated deinit {}

    var isChannelCleaningEnabled: Bool { store.isChannelCleaningEnabled }
    var enabledEpisodeIDs: Set<String> { store.enabledEpisodeIDs }

    func isEpisodeCleaningEnabled(_ episodeID: String) -> Bool {
        store.isEpisodeCleaningEnabled(episodeID)
    }

    func setChannelCleaning(_ enabled: Bool) {
        try? store.setChannelCleaning(enabled)
    }

    func setEpisodeCleaning(_ episodeID: String, enabled: Bool) {
        try? store.setEpisodeCleaning(episodeID, enabled: enabled)
    }
}
