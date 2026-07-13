//
//  DownloadStateStore.swift
//  PodWash
//
//  Slice 11 — Durable download UI state (ADR-009 §4).
//

import CoreData
import Foundation

enum DownloadError: Error, Equatable {
    case missingRemoteURL
    case transportFailure
    case cancelled
    case noResumeData
}

enum DownloadState: Equatable {
    case notDownloaded
    case downloading(progress: Double)
    case downloaded
    case failed

    fileprivate var persistedRawValue: String? {
        switch self {
        case .notDownloaded: return "notDownloaded"
        case .downloading: return nil
        case .downloaded: return "downloaded"
        case .failed: return "failed"
        }
    }

    fileprivate static func fromPersisted(rawValue: String?) -> DownloadState {
        switch rawValue {
        case "downloaded": return .downloaded
        case "failed": return .failed
        default: return .notDownloaded
        }
    }
}

@MainActor
final class DownloadStateStore {
    nonisolated(unsafe) private let context: NSManagedObjectContext
    nonisolated(unsafe) private let retainedController: PersistenceController?
    /// In-flight `.downloading` is process-local only (not durable across reload).
    nonisolated(unsafe) private var transientDownloading: [String: Double] = [:]

    init(context: NSManagedObjectContext, retaining controller: PersistenceController? = nil) {
        self.context = context
        self.retainedController = controller
    }

    /// Legacy no-arg store for pre–Slice 11 unit tests (`InMemoryDownloadStateStore`).
    convenience init() {
        let controller = PersistenceController.inMemory()
        self.init(context: controller.viewContext, retaining: controller)
    }

    // Avoid MainActor/TaskLocal deinit crash (same pattern as AnalysisUIViewModel).
    nonisolated deinit {}

    func state(for episodeID: String) -> DownloadState {
        if let progress = transientDownloading[episodeID] {
            return .downloading(progress: progress)
        }
        guard let episode = fetchEpisode(id: episodeID) else {
            return .notDownloaded
        }
        return DownloadState.fromPersisted(rawValue: episode.downloadStateRaw)
    }

    /// AC / slice prose alias for `state(for:)`.
    func downloadState(for episodeID: String) -> DownloadState {
        state(for: episodeID)
    }

    func setState(_ state: DownloadState, for episodeID: String) throws {
        switch state {
        case .downloading(let progress):
            transientDownloading[episodeID] = progress
            return
        case .notDownloaded, .downloaded, .failed:
            transientDownloading[episodeID] = nil
            let episode = requireEpisode(id: episodeID)
            episode.downloadStateRaw = state.persistedRawValue ?? "notDownloaded"
            try context.save()
        }
    }

    func clear() throws {
        transientDownloading.removeAll()
        let request = CDEpisode.fetchRequest()
        for episode in try context.fetch(request) {
            episode.downloadStateRaw = "notDownloaded"
        }
        try context.save()
    }

    func downloadedEpisodeIDs() -> [String] {
        let request = CDEpisode.fetchRequest()
        request.predicate = NSPredicate(format: "downloadStateRaw == %@", "downloaded")
        guard let episodes = try? context.fetch(request) else { return [] }
        return episodes.compactMap(\.id)
    }

    private func fetchEpisode(id: String) -> CDEpisode? {
        let request = CDEpisode.fetchRequest()
        request.predicate = NSPredicate(format: "id == %@", id)
        request.fetchLimit = 1
        return try? context.fetch(request).first
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
        return episode
    }
}

/// Compatibility shim: non-throwing API for pre–Slice 11 tests / DownloadManager call sites.
@MainActor
final class InMemoryDownloadStateStore {
    nonisolated(unsafe) private let store: DownloadStateStore

    var backing: DownloadStateStore { store }

    init() {
        store = DownloadStateStore()
    }

    init(backing store: DownloadStateStore) {
        self.store = store
    }

    // Avoid MainActor/TaskLocal deinit crash (same pattern as AnalysisUIViewModel).
    nonisolated deinit {}

    func state(for episodeID: String) -> DownloadState {
        store.state(for: episodeID)
    }

    func setState(_ state: DownloadState, for episodeID: String) {
        try? store.setState(state, for: episodeID)
    }

    func clear() {
        try? store.clear()
    }

    func downloadedEpisodeIDs() -> [String] {
        store.downloadedEpisodeIDs()
    }
}
