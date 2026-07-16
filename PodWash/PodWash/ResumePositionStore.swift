//
//  ResumePositionStore.swift
//  PodWash
//
//  Slice 11 — Per-episode position + played flag (ADR-009 §4).
//

import CoreData
import Foundation

@MainActor
final class ResumePositionStore {
    nonisolated(unsafe) private let context: NSManagedObjectContext

    init(context: NSManagedObjectContext) {
        self.context = context
    }

    // Avoid MainActor/TaskLocal deinit crash (same pattern as AnalysisUIViewModel).
    nonisolated deinit {}

    func position(for episodeID: String) -> TimeInterval {
        fetchEpisode(id: episodeID)?.playbackPosition ?? 0
    }

    /// First episode in the active podcast's ordered relationship (feed save order).
    func firstEpisodeID() -> String? {
        let podcastRequest = CDPodcast.fetchRequest()
        podcastRequest.fetchLimit = 1
        guard let podcast = try? context.fetch(podcastRequest).first,
              let rows = podcast.episodes?.array as? [CDEpisode],
              let first = rows.first
        else {
            return nil
        }
        return first.id
    }

    func setPosition(_ seconds: TimeInterval, for episodeID: String) throws {
        let episode = try requireEpisode(id: episodeID)
        episode.playbackPosition = seconds
        try context.save()
    }

    func isPlayed(_ episodeID: String) -> Bool {
        fetchEpisode(id: episodeID)?.isPlayed ?? false
    }

    func setPlayed(_ played: Bool, for episodeID: String) throws {
        let episode = try requireEpisode(id: episodeID)
        episode.isPlayed = played
        try context.save()
    }

    /// Updates position; sets `isPlayed == true` when
    /// `duration > 0 && seconds / duration >= playedThreshold` (default **0.95**).
    /// Does not clear `isPlayed` when progress later drops below threshold.
    func recordProgress(
        episodeID: String,
        seconds: TimeInterval,
        duration: TimeInterval,
        playedThreshold: Double = 0.95
    ) throws {
        let episode = try requireEpisode(id: episodeID)
        episode.playbackPosition = seconds
        if duration > 0, seconds / duration >= playedThreshold {
            episode.isPlayed = true
        }
        try context.save()
    }

    private func fetchEpisode(id: String) -> CDEpisode? {
        let request = CDEpisode.fetchRequest()
        request.predicate = NSPredicate(format: "id == %@", id)
        request.fetchLimit = 1
        return try? context.fetch(request).first
    }

    private func requireEpisode(id: String) throws -> CDEpisode {
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
        episode.dismissedFromAutoplay = false
        episode.downloadStateRaw = "notDownloaded"
        return episode
    }
}
