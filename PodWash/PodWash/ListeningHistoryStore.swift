import CoreData
import Foundation

struct ListeningHistoryEntry: Identifiable {
    struct ID: Hashable {
        let feedURL: URL
        let episodeID: String

        var accessibilityID: String { "\(feedURL.absoluteString)|\(episodeID)" }
    }

    let id: ID
    let episode: Episode
    let showTitle: String
    let completedAt: Date?
}

@MainActor
final class ListeningHistoryStore {
    nonisolated(unsafe) private let context: NSManagedObjectContext

    init(context: NSManagedObjectContext) {
        self.context = context
    }

    nonisolated deinit {}

    func importPlayedEpisodes() throws {
        let marker = CDListeningHistoryImport.fetchRequest()
        marker.fetchLimit = 1
        guard try context.fetch(marker).isEmpty else { return }
        let request = CDEpisode.fetchRequest()
        request.predicate = NSPredicate(format: "isPlayed == YES AND podcast != nil")
        for row in try context.fetch(request) {
            guard let id = row.id, !id.isEmpty, let podcast = row.podcast,
                  let feed = podcast.feedURLString, !feed.isEmpty,
                  let url = URL(string: feed), let title = row.title
            else { continue }
            let episode = Episode(id: id, title: title, pubDate: row.pubDate ?? .distantPast,
                                  artworkURL: nil, showNotes: nil, audioURL: row.audioURLString.flatMap(URL.init(string:)))
            let key = ListeningHistoryEntry.ID(feedURL: url, episodeID: id)
            if try find(key) == nil {
                fill(insertEntry(), episode: episode, feedURL: url,
                     showTitle: podcast.title ?? "")
            }
        }
        _ = NSEntityDescription.insertNewObject(forEntityName: "CDListeningHistoryImport", into: context)
        try context.save()
    }

    func recordCompletion(episode: Episode, feedURL: URL, showTitle: String,
                          runID: String, at date: Date, updateProgress: () throws -> Void) throws -> Bool {
        let key = ListeningHistoryEntry.ID(feedURL: feedURL, episodeID: episode.id)
        let existing = try find(key)
        guard existing?.completedRunID != runID else { return false }
        do {
            try updateProgress()
            let row = existing ?? insertEntry()
            fill(row, episode: episode, feedURL: feedURL, showTitle: showTitle)
            row.completedAt = date
            row.completedRunID = runID
            try context.save()
            return true
        } catch {
            context.rollback()
            throw error
        }
    }

    func entries() -> [ListeningHistoryEntry] {
        let request = CDListeningEntry.fetchRequest()
        request.sortDescriptors = [
            NSSortDescriptor(key: "completedAt", ascending: false),
            NSSortDescriptor(key: "showTitle", ascending: true),
            NSSortDescriptor(key: "episodeTitle", ascending: true),
            NSSortDescriptor(key: "feedURLString", ascending: true),
            NSSortDescriptor(key: "episodeID", ascending: true)
        ]
        return ((try? context.fetch(request)) ?? []).compactMap(entry)
    }

    func entry(for key: ListeningHistoryEntry.ID) -> ListeningHistoryEntry? {
        (try? find(key)).flatMap(entry)
    }

    func entries(episodeID: String) -> [ListeningHistoryEntry] {
        let request = CDListeningEntry.fetchRequest()
        request.predicate = NSPredicate(format: "episodeID == %@", episodeID)
        return ((try? context.fetch(request)) ?? []).compactMap(entry)
    }

    private func insertEntry() -> CDListeningEntry {
        let entity = NSEntityDescription.entity(forEntityName: "CDListeningEntry", in: context)!
        return CDListeningEntry(entity: entity, insertInto: context)
    }

    private func find(_ key: ListeningHistoryEntry.ID) throws -> CDListeningEntry? {
        let request = CDListeningEntry.fetchRequest()
        request.predicate = NSPredicate(format: "feedURLString == %@ AND episodeID == %@",
                                        key.feedURL.absoluteString, key.episodeID)
        request.fetchLimit = 1
        return try context.fetch(request).first
    }

    private func fill(_ row: CDListeningEntry, episode: Episode, feedURL: URL, showTitle: String) {
        row.episodeID = episode.id
        row.feedURLString = feedURL.absoluteString
        row.episodeTitle = episode.title
        row.showTitle = showTitle
        row.publicationDate = episode.pubDate
        row.audioURLString = episode.audioURL?.absoluteString
    }

    private func entry(_ row: CDListeningEntry) -> ListeningHistoryEntry? {
        guard let feed = row.feedURLString, let url = URL(string: feed),
              let id = row.episodeID, let title = row.episodeTitle else { return nil }
        return ListeningHistoryEntry(
            id: .init(feedURL: url, episodeID: id),
            episode: Episode(id: id, title: title, pubDate: row.publicationDate ?? .distantPast,
                             artworkURL: nil, showNotes: nil, audioURL: row.audioURLString.flatMap(URL.init(string:))),
            showTitle: row.showTitle ?? "",
            completedAt: row.completedAt
        )
    }
}
