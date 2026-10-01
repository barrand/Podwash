//
//  EpisodePreparationPreferencesStore.swift
//  PodWash
//

import Foundation

/// Durable listener intent is intentionally separate from the persisted job
/// checkpoint. A job says what happened; this payload says what the listener
/// still wants after a relaunch.
struct EpisodePreparationPreferences: Codable, Equatable {
    var explicitEpisodeIDs: Set<String> = []
    var automaticallySuppressedEpisodeIDs: Set<String> = []
}

final class EpisodePreparationPreferencesStore {
    private let defaults: UserDefaults
    private let key: String
    private(set) var preferences: EpisodePreparationPreferences

    init(defaults: UserDefaults = .standard, key: String = "podwash.episodePreparationPreferences.v1") {
        self.defaults = defaults
        self.key = key
        if let data = defaults.data(forKey: key),
           let decoded = try? JSONDecoder().decode(EpisodePreparationPreferences.self, from: data) {
            preferences = decoded
        } else {
            preferences = EpisodePreparationPreferences()
        }
    }

    func addExplicit(_ episodeID: String) {
        preferences.explicitEpisodeIDs.insert(episodeID)
        preferences.automaticallySuppressedEpisodeIDs.remove(episodeID)
        save()
    }

    func removeExplicit(_ episodeID: String) { preferences.explicitEpisodeIDs.remove(episodeID); save() }
    func suppressAutomatic(_ episodeID: String) { preferences.automaticallySuppressedEpisodeIDs.insert(episodeID); save() }
    func clearSuppression(_ episodeID: String) { preferences.automaticallySuppressedEpisodeIDs.remove(episodeID); save() }

    private func save() {
        defaults.set(try? JSONEncoder().encode(preferences), forKey: key)
    }
}
