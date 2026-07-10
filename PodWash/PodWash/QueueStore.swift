//
//  QueueStore.swift
//  PodWash
//
//  Slice 11 — Up-next order persistence (ADR-009 §4).
//

import CoreData
import Foundation

@MainActor
final class QueueStore {
    nonisolated(unsafe) private let context: NSManagedObjectContext

    init(context: NSManagedObjectContext) {
        self.context = context
    }

    // Avoid MainActor/TaskLocal deinit crash (same pattern as AnalysisUIViewModel).
    nonisolated deinit {}

    func queueEpisodeIDs() -> [String] {
        let request = CDQueueEntry.fetchRequest()
        request.sortDescriptors = [NSSortDescriptor(key: "sortIndex", ascending: true)]
        let rows = (try? context.fetch(request)) ?? []
        return rows.compactMap(\.episodeID)
    }

    func add(_ episodeID: String) throws {
        let existing = queueEpisodeIDs()
        guard !existing.contains(episodeID) else { return }
        let entry = CDQueueEntry(context: context)
        entry.episodeID = episodeID
        entry.sortIndex = Int32(existing.count)
        try context.save()
    }

    func remove(_ episodeID: String) throws {
        let request = CDQueueEntry.fetchRequest()
        request.predicate = NSPredicate(format: "episodeID == %@", episodeID)
        for entry in try context.fetch(request) {
            context.delete(entry)
        }
        try reindex()
        try context.save()
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

    /// Removes every queue row (fixture reset / UITest launch).
    func clear() throws {
        let request = CDQueueEntry.fetchRequest()
        for entry in try context.fetch(request) {
            context.delete(entry)
        }
        try context.save()
    }

    private func reindex() throws {
        let request = CDQueueEntry.fetchRequest()
        request.sortDescriptors = [NSSortDescriptor(key: "sortIndex", ascending: true)]
        let entries = try context.fetch(request)
        for (index, entry) in entries.enumerated() {
            entry.sortIndex = Int32(index)
        }
    }
}
