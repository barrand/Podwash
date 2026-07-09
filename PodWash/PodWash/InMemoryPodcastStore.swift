//
//  InMemoryPodcastStore.swift
//  PodWash
//
//  Slice 06 — In-memory feed stub (ADR-004); replaced by SwiftData in Slice 11.
//

import Foundation

@MainActor
final class InMemoryPodcastStore {
    private(set) var currentFeed: PodcastFeed?

    func save(_ feed: PodcastFeed) {
        currentFeed = feed
    }

    func clear() {
        currentFeed = nil
    }
}
