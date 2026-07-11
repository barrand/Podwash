//
//  CarPlayLibraryDataSource.swift
//  PodWash
//
//  Slice 15 — Library tab rows from PodcastStore subscriptions (ADR-016 §3).
//

import Foundation

@MainActor
final class CarPlayLibraryDataSource {
    // nonisolated(unsafe): avoid MainActor TaskLocal hop when releasing in deinit
    // (XCTest teardown otherwise SIGABRT via swift_task_deinitOnExecutorImpl).
    nonisolated(unsafe) private let store: PodcastStore
    nonisolated(unsafe) private let artwork: any CarPlayArtworkProviding

    init(store: PodcastStore, artwork: any CarPlayArtworkProviding = .placeholder) {
        self.store = store
        self.artwork = artwork
    }

    // Avoid MainActor/TaskLocal deinit crash under SWIFT_DEFAULT_ACTOR_ISOLATION
    // (XCTest teardown otherwise SIGABRT via swift_task_deinitOnExecutorImpl).
    nonisolated deinit {}

    func listItems() -> [CarPlayListItemModel] {
        store.allSubscriptions().enumerated().map { index, summary in
            CarPlayListItemModel(
                text: summary.title,
                image: artwork.image(for: summary.artworkURL),
                episodeID: nil,
                subscriptionIndex: index
            )
        }
    }
}
