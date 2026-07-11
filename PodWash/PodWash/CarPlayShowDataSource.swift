//
//  CarPlayShowDataSource.swift
//  PodWash
//
//  Slice 15 — Per-subscription episode list for CarPlay show drill-down (ADR-016 §3).
//

import Foundation

@MainActor
final class CarPlayShowDataSource {
    // nonisolated(unsafe): avoid MainActor TaskLocal hop when releasing in deinit
    // (XCTest teardown otherwise SIGABRT via swift_task_deinitOnExecutorImpl).
    nonisolated(unsafe) private let store: PodcastStore
    nonisolated(unsafe) private let subscriptionIndex: Int
    nonisolated(unsafe) private let artwork: any CarPlayArtworkProviding

    init(
        store: PodcastStore,
        subscriptionIndex: Int,
        artwork: any CarPlayArtworkProviding = .placeholder
    ) {
        self.store = store
        self.subscriptionIndex = subscriptionIndex
        self.artwork = artwork
    }

    // Avoid MainActor/TaskLocal deinit crash under SWIFT_DEFAULT_ACTOR_ISOLATION
    // (XCTest teardown otherwise SIGABRT via swift_task_deinitOnExecutorImpl).
    nonisolated deinit {}

    func listItems() -> [CarPlayListItemModel] {
        let subscriptions = store.allSubscriptions()
        guard subscriptions.indices.contains(subscriptionIndex) else { return [] }
        let summary = subscriptions[subscriptionIndex]
        guard let feed = store.subscription(forFeedURL: summary.feedURL) else { return [] }

        return feed.episodes.map { episode in
            CarPlayListItemModel(
                text: episode.title,
                image: artwork.image(for: episode.artworkURL ?? feed.artworkURL),
                episodeID: episode.id,
                subscriptionIndex: nil
            )
        }
    }
}
