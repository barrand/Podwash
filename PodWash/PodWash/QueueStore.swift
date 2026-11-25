//
//  QueueStore.swift
//  PodWash
//
//  Slice 11 — Up-next order persistence (ADR-009 §4).
//

import CoreData
import Foundation

struct QueuedEpisode: Equatable {
    let episodeID: String
    let replayFeedURL: URL?
    let objectID: URL
}

@MainActor
final class QueueStore {
    nonisolated(unsafe) private let context: NSManagedObjectContext

    init(context: NSManagedObjectContext) {
        self.context = context
    }

    // Avoid MainActor/TaskLocal deinit crash (same pattern as AnalysisUIViewModel).
    nonisolated deinit {}

    func entries() -> [QueuedEpisode] {
        let request = CDQueueEntry.fetchRequest()
        request.sortDescriptors = [NSSortDescriptor(key: "sortIndex", ascending: true)]
        return ((try? context.fetch(request)) ?? []).compactMap { row in
            guard let id = row.episodeID else { return nil }
            return QueuedEpisode(episodeID: id, replayFeedURL: row.replayFeedURLString.flatMap(URL.init(string:)),
                                 objectID: row.objectID.uriRepresentation())
        }
    }

    func queueEpisodeIDs() -> [String] { entries().map(\.episodeID) }

    func entry(for episodeID: String) -> QueuedEpisode? {
        entries().first { $0.episodeID == episodeID }
    }

    func add(_ episodeID: String) throws {
        let existing = queueEpisodeIDs()
        guard !existing.contains(episodeID) else { return }
        let entry = CDQueueEntry(context: context)
        entry.episodeID = episodeID
        entry.sortIndex = Int32(existing.count)
        try context.save()
    }

    /// Listener intent is "Play Next": insert a new item at the front of the
    /// durable manual queue. Existing queued items are promoted instead.
    func playNext(_ episodeID: String, replayFeedURL: URL? = nil) throws {
        var ids = queueEpisodeIDs().filter { $0 != episodeID }
        ids.insert(episodeID, at: 0)
        let replaySources = replayFeedURL.map { [episodeID: $0] } ?? [:]
        try replaceQueue(with: ids, replaySources: replaySources)
    }

    func remove(_ episodeID: String, save: Bool = true) throws {
        let request = CDQueueEntry.fetchRequest()
        request.predicate = NSPredicate(format: "episodeID == %@", episodeID)
        for entry in try context.fetch(request) {
            context.delete(entry)
        }
        try reindex()
        if save { try context.save() }
    }

    func move(_ episodeID: String, toIndex: Int) throws {
        var ids = queueEpisodeIDs()
        guard let fromIndex = ids.firstIndex(of: episodeID) else { return }
        ids.remove(at: fromIndex)
        let clamped = max(0, min(toIndex, ids.count))
        ids.insert(episodeID, at: clamped)

        let request = CDQueueEntry.fetchRequest()
        let entries = try context.fetch(request)
        let byID = Dictionary(uniqueKeysWithValues: entries.compactMap { entry -> (String, CDQueueEntry)? in
            guard let id = entry.episodeID else { return nil }
            return (id, entry)
        })
        for (index, id) in ids.enumerated() {
            byID[id]?.sortIndex = Int32(index)
        }
        try context.save()
    }

    /// Select a queued episode for immediate playback while keeping the interrupted
    /// episode first in Up Next. For `[A, B, C]` with current `X`, selecting `B`
    /// produces `[X, A, C]`.
    @discardableResult
    func selectForImmediatePlayback(
        _ selectedEpisodeID: String,
        replacingCurrentEpisodeID currentEpisodeID: String
    ) throws -> Bool {
        let existing = queueEpisodeIDs()
        guard selectedEpisodeID != currentEpisodeID,
              existing.contains(selectedEpisodeID)
        else { return false }

        let reordered = [currentEpisodeID]
            + existing.filter { $0 != selectedEpisodeID && $0 != currentEpisodeID }
        try replaceQueue(with: reordered)
        return true
    }

    /// Places the interrupted episode first while removing the selected episode if
    /// it was already in Up Next. Called only after local playback is staged.
    func prepareForImmediatePlayback(
        selectedEpisodeID: String,
        replacingCurrentEpisodeID currentEpisodeID: String?,
        save: Bool = true
    ) throws {
        var reordered = queueEpisodeIDs().filter { $0 != selectedEpisodeID && $0 != currentEpisodeID }
        if let currentEpisodeID, currentEpisodeID != selectedEpisodeID {
            reordered.insert(currentEpisodeID, at: 0)
        }
        try replaceQueue(with: reordered, save: save)
    }

    /// Removes every queue row (fixture reset / UITest launch).
    func clear() throws {
        let request = CDQueueEntry.fetchRequest()
        for entry in try context.fetch(request) {
            context.delete(entry)
        }
        try context.save()
    }

    /// Restores a previously captured manual order for Queue's Clear/Undo affordance.
    func restore(_ episodeIDs: [String]) throws {
        try replaceQueue(with: episodeIDs)
    }

    func restoreEntries(_ entries: [QueuedEpisode]) throws {
        var replaySources: [String: URL] = [:]
        for entry in entries where replaySources[entry.episodeID] == nil {
            replaySources[entry.episodeID] = entry.replayFeedURL
        }
        try replaceQueue(with: entries.map(\.episodeID), replaySources: replaySources)
    }

    private func reindex() throws {
        let request = CDQueueEntry.fetchRequest()
        request.sortDescriptors = [NSSortDescriptor(key: "sortIndex", ascending: true)]
        let entries = try context.fetch(request)
        for (index, entry) in entries.enumerated() {
            entry.sortIndex = Int32(index)
        }
    }

    private func replaceQueue(with episodeIDs: [String], replaySources: [String: URL] = [:],
                              save: Bool = true) throws {
        let uniqueIDs = episodeIDs.reduce(into: [String]()) { result, id in
            guard !result.contains(id) else { return }
            result.append(id)
        }
        let request = CDQueueEntry.fetchRequest()
        let entries = try context.fetch(request)
        let byID = Dictionary(uniqueKeysWithValues: entries.compactMap { entry -> (String, CDQueueEntry)? in
            guard let id = entry.episodeID else { return nil }
            return (id, entry)
        })

        for entry in entries where !(entry.episodeID.map(uniqueIDs.contains) ?? false) {
            context.delete(entry)
        }
        for (index, id) in uniqueIDs.enumerated() {
            let entry = byID[id] ?? CDQueueEntry(context: context)
            entry.episodeID = id
            entry.sortIndex = Int32(index)
            if let feed = replaySources[id] { entry.replayFeedURLString = feed.absoluteString }
        }
        if save { try context.save() }
    }
}
