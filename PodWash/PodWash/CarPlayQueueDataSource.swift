//
//  CarPlayQueueDataSource.swift
//  PodWash
//
//  Slice 15 — Queue tab rows from QueueStore order (ADR-016 §3).
//

import Foundation

@MainActor
final class CarPlayQueueDataSource {
    // nonisolated(unsafe): avoid MainActor TaskLocal hop when releasing in deinit
    // (XCTest teardown otherwise SIGABRT via swift_task_deinitOnExecutorImpl).
    nonisolated(unsafe) private let store: PodcastStore
    nonisolated(unsafe) private let queue: QueueStore
    nonisolated(unsafe) private let artwork: any CarPlayArtworkProviding

    init(
        store: PodcastStore,
        queue: QueueStore,
        artwork: any CarPlayArtworkProviding = .placeholder
    ) {
        self.store = store
        self.queue = queue
        self.artwork = artwork
    }

    // Avoid MainActor/TaskLocal deinit crash under SWIFT_DEFAULT_ACTOR_ISOLATION
    // (XCTest teardown otherwise SIGABRT via swift_task_deinitOnExecutorImpl).
    nonisolated deinit {}

    func listItems() -> [CarPlayListItemModel] {
        queue.entries().compactMap { entry in
            let episodeID = entry.episodeID
            let episode: Episode?
            if let feed = entry.replayFeedURL, let shell = CarPlayDependencies.provider as? AppShellModel,
               shell.queueStore === queue {
                episode = shell.carPlayReplayEpisode(id: episodeID, feedURL: feed)
            } else {
                episode = Self.resolveEpisode(id: episodeID, in: store)
            }
            guard let episode else {
                return nil
            }
            return CarPlayListItemModel(
                text: episode.title,
                image: artwork.image(for: episode.artworkURL),
                episodeID: episodeID,
                subscriptionIndex: nil
            )
        }
    }

    /// Walk subscriptions → episodes; no new PodcastStore API (ADR-016 §3).
    static func resolveEpisode(id: String, in store: PodcastStore) -> Episode? {
        for summary in store.allSubscriptions() {
            guard let feed = store.subscription(forFeedURL: summary.feedURL) else { continue }
            if let episode = feed.episodes.first(where: { $0.id == id }) {
                return episode
            }
        }
        return nil
    }
}
