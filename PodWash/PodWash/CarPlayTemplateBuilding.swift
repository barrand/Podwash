//
//  CarPlayTemplateBuilding.swift
//  PodWash
//
//  Slice 15 — Pure list-model builder + list presenting seam (ADR-016 §4–§5).
//

import Foundation

@MainActor
protocol CarPlayTemplateBuilding: AnyObject {
    func libraryListItems() -> [CarPlayListItemModel]
    func showListItems(subscriptionIndex: Int) -> [CarPlayListItemModel]
    func queueListItems() -> [CarPlayListItemModel]
}

/// Injectable list double surface (CPListTemplateRecorder in tests).
@MainActor
protocol CarPlayListPresenting: AnyObject {
    func setItems(_ items: [CarPlayListItemModel], listKey: String)
    func setSelectionHandler(listKey: String, at index: Int, handler: @escaping () -> Void)
}

/// Production builder wiring store + queue data sources.
@MainActor
final class CarPlayStoreBuilder: CarPlayTemplateBuilding {
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

    func libraryListItems() -> [CarPlayListItemModel] {
        CarPlayLibraryDataSource(store: store, artwork: artwork).listItems()
    }

    func showListItems(subscriptionIndex: Int) -> [CarPlayListItemModel] {
        CarPlayShowDataSource(
            store: store,
            subscriptionIndex: subscriptionIndex,
            artwork: artwork
        ).listItems()
    }

    func queueListItems() -> [CarPlayListItemModel] {
        CarPlayQueueDataSource(store: store, queue: queue, artwork: artwork).listItems()
    }
}
