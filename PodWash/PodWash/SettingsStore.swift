//
//  SettingsStore.swift
//  PodWash
//
//  Slice 13 — Injectable UserDefaults settings + composed target set (ADR-010).
//

import Foundation
import Observation

enum SettingsCleaningAction: String, Codable, Equatable, Sendable {
    case mute
    case skip
}

/// Injectable UserDefaults settings store (ADR-010).
/// Opted out of module default MainActor isolation (`SWIFT_DEFAULT_ACTOR_ISOLATION`)
/// so unit tests can construct and mutate from XCTest's synchronous nonisolated
/// context; UI still drives it on the main thread.
@Observable
nonisolated final class SettingsStore: @unchecked Sendable {
    private enum Keys {
        static let enabledCategories = "podwash.settings.enabledCategories"
        static let customWords = "podwash.settings.customWords"
        static let defaultCleaningAction = "podwash.settings.defaultCleaningAction"
        static let defaultPlaybackRate = "podwash.settings.defaultPlaybackRate"
        static let autoDownloadEnabled = "podwash.settings.autoDownloadEnabled"
        static let autoDeleteAfterPlayedEnabled = "podwash.settings.autoDeleteAfterPlayedEnabled"

        static let all: [String] = [
            enabledCategories,
            customWords,
            defaultCleaningAction,
            defaultPlaybackRate,
            autoDownloadEnabled,
            autoDeleteAfterPlayedEnabled,
        ]
    }

    @ObservationIgnored nonisolated(unsafe) private let userDefaults: UserDefaults

    /// Sorted array of currently enabled category IDs.
    private(set) var enabledCategoryIDs: [String]
    /// Stored normalized custom words in stable insertion order.
    private(set) var customWords: [String]
    var defaultCleaningAction: SettingsCleaningAction {
        didSet { persistAction() }
    }
    var defaultPlaybackRate: Float {
        didSet {
            let snapped = Self.nearestSupportedRate(to: defaultPlaybackRate)
            if snapped != defaultPlaybackRate {
                defaultPlaybackRate = snapped
                return
            }
            persistRate()
        }
    }
    var autoDownloadEnabled: Bool {
        didSet { userDefaults.set(autoDownloadEnabled, forKey: Keys.autoDownloadEnabled) }
    }
    var autoDeleteAfterPlayedEnabled: Bool {
        didSet { userDefaults.set(autoDeleteAfterPlayedEnabled, forKey: Keys.autoDeleteAfterPlayedEnabled) }
    }

    init(userDefaults: UserDefaults = .standard) {
        self.userDefaults = userDefaults

        if let stored = userDefaults.array(forKey: Keys.enabledCategories) as? [String] {
            enabledCategoryIDs = stored.sorted()
        } else {
            enabledCategoryIDs = WordCategories.defaultEnabledIDs.sorted()
        }

        if let stored = userDefaults.array(forKey: Keys.customWords) as? [String] {
            customWords = stored
        } else {
            customWords = []
        }

        if let raw = userDefaults.string(forKey: Keys.defaultCleaningAction),
           let action = SettingsCleaningAction(rawValue: raw) {
            defaultCleaningAction = action
        } else {
            defaultCleaningAction = .mute
        }

        if userDefaults.object(forKey: Keys.defaultPlaybackRate) != nil {
            defaultPlaybackRate = Self.nearestSupportedRate(
                to: userDefaults.float(forKey: Keys.defaultPlaybackRate)
            )
        } else {
            defaultPlaybackRate = 1.0
        }

        if userDefaults.object(forKey: Keys.autoDownloadEnabled) != nil {
            autoDownloadEnabled = userDefaults.bool(forKey: Keys.autoDownloadEnabled)
        } else {
            autoDownloadEnabled = false
        }

        if userDefaults.object(forKey: Keys.autoDeleteAfterPlayedEnabled) != nil {
            autoDeleteAfterPlayedEnabled = userDefaults.bool(forKey: Keys.autoDeleteAfterPlayedEnabled)
        } else {
            autoDeleteAfterPlayedEnabled = false
        }
    }

    // Avoid MainActor/TaskLocal deinit crash (same pattern as AnalysisUIViewModel).
    // @Observable still routes dealloc through swift_task_deinitOnExecutorImpl under
    // SWIFT_DEFAULT_ACTOR_ISOLATION=MainActor unless deinit is explicitly nonisolated.
    nonisolated deinit {}

    /// Removes all settings keys so the next store reads PRD fresh defaults.
    static func clearPersistedValues(in userDefaults: UserDefaults = .standard) {
        for key in Keys.all {
            userDefaults.removeObject(forKey: key)
        }
    }

    func isCategoryEnabled(_ categoryID: String) -> Bool {
        enabledCategoryIDs.contains(categoryID)
    }

    func setCategoryEnabled(_ categoryID: String, _ enabled: Bool) {
        var set = Set(enabledCategoryIDs)
        if enabled {
            set.insert(categoryID)
        } else {
            set.remove(categoryID)
        }
        enabledCategoryIDs = set.sorted()
        userDefaults.set(enabledCategoryIDs, forKey: Keys.enabledCategories)
    }

    func addCustomWord(_ raw: String) {
        let normalized = WordMatcher.normalize(raw)
        guard !normalized.isEmpty else { return }
        guard !customWords.contains(normalized) else { return }
        customWords.append(normalized)
        userDefaults.set(customWords, forKey: Keys.customWords)
    }

    func removeCustomWord(_ rawOrNormalized: String) {
        let normalized = WordMatcher.normalize(rawOrNormalized)
        guard !normalized.isEmpty else { return }
        customWords.removeAll { $0 == normalized }
        userDefaults.set(customWords, forKey: Keys.customWords)
    }

    /// Union of enabled category seeds + custom words, normalized via WordMatcher.
    func activeNormalizedTargetSet() -> Set<String> {
        var raw: [String] = []
        for id in enabledCategoryIDs {
            raw.append(contentsOf: WordCategories.words(for: id))
        }
        raw.append(contentsOf: customWords)
        return WordMatcher.normalizedTargetSet(raw)
    }

    func censorAction() -> CensorAction {
        switch defaultCleaningAction {
        case .mute: return .mute
        case .skip: return .skip
        }
    }

    private func persistAction() {
        userDefaults.set(defaultCleaningAction.rawValue, forKey: Keys.defaultCleaningAction)
    }

    private func persistRate() {
        userDefaults.set(defaultPlaybackRate, forKey: Keys.defaultPlaybackRate)
    }

    private static func nearestSupportedRate(to rate: Float) -> Float {
        let rates = PlaybackEngine.supportedRates
        if rates.contains(rate) { return rate }
        return rates.min(by: { abs($0 - rate) < abs($1 - rate) }) ?? 1.0
    }
}
