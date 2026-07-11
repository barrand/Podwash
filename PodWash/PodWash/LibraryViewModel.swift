//
//  LibraryViewModel.swift
//  PodWash
//
//  Slice 23 — Library subscription list (ADR-015 §3).
//

import Foundation

@MainActor @Observable
final class LibraryViewModel {
    private let store: PodcastStore

    private(set) var subscriptions: [PodcastSummary] = []

    var subscriptionCount: Int { subscriptions.count }
    var titles: [String] { subscriptions.map(\.title) }

    init(store: PodcastStore) {
        self.store = store
    }

    // Avoid MainActor/TaskLocal deinit crash under SWIFT_DEFAULT_ACTOR_ISOLATION
    // (XCTest teardown otherwise SIGABRT via swift_task_deinitOnExecutorImpl).
    nonisolated deinit {}

    /// Re-reads `store.allSubscriptions()` (ascending `subscribedAt`, then `feedURLString`).
    func reload() {
        subscriptions = store.allSubscriptions()
    }
}
