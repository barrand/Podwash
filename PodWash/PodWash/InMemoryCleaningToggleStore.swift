//
//  InMemoryCleaningToggleStore.swift
//  PodWash
//
//  Slice 09 — In-memory cleaning toggle persistence (Slice 11 migrates to SwiftData).
//

import Foundation

/// In-memory toggle persistence shared across view-model instances (Slice 11 → SwiftData).
@MainActor
final class InMemoryCleaningToggleStore {
    private(set) var isChannelCleaningEnabled = false
    private(set) var enabledEpisodeIDs: Set<String> = []

    nonisolated deinit {}

    func isEpisodeCleaningEnabled(_ episodeID: String) -> Bool {
        enabledEpisodeIDs.contains(episodeID)
    }

    func setChannelCleaning(_ enabled: Bool) {
        isChannelCleaningEnabled = enabled
    }

    func setEpisodeCleaning(_ episodeID: String, enabled: Bool) {
        if enabled {
            enabledEpisodeIDs.insert(episodeID)
        } else {
            enabledEpisodeIDs.remove(episodeID)
        }
    }
}
