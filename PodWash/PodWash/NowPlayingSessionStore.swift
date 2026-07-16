//
//  NowPlayingSessionStore.swift
//  PodWash
//
//  Slice 31 — Durable active now-playing episode id (ADR-027 §3).
//

import CoreData
import Foundation

@MainActor
final class NowPlayingSessionStore {
    nonisolated(unsafe) private let context: NSManagedObjectContext

    init(context: NSManagedObjectContext) {
        self.context = context
    }

    // Avoid MainActor/TaskLocal deinit crash (same pattern as QueueStore).
    nonisolated deinit {}

    /// `nil` when no durable session row (or empty id).
    func activeEpisodeID() -> String? {
        guard let row = fetchSingleton(),
              let id = row.activeEpisodeID,
              !id.isEmpty
        else {
            return nil
        }
        return id
    }

    /// Upserts the singleton row to `episodeID`. No-op if already set to the same id.
    func setActiveEpisodeID(_ episodeID: String) throws {
        guard !episodeID.isEmpty else {
            try clear()
            return
        }
        if let existing = fetchSingleton() {
            if existing.activeEpisodeID == episodeID { return }
            existing.activeEpisodeID = episodeID
        } else {
            let row = CDNowPlayingSession(context: context)
            row.activeEpisodeID = episodeID
        }
        try context.save()
    }

    /// Deletes the singleton row. After this, `activeEpisodeID() == nil`.
    func clear() throws {
        let request = CDNowPlayingSession.fetchRequest()
        for row in try context.fetch(request) {
            context.delete(row)
        }
        try context.save()
    }

    private func fetchSingleton() -> CDNowPlayingSession? {
        let request = CDNowPlayingSession.fetchRequest()
        request.fetchLimit = 1
        return try? context.fetch(request).first
    }
}
