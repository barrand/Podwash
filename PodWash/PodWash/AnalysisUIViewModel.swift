//
//  AnalysisUIViewModel.swift
//  PodWash
//
//  Slice 09 — Cleaning toggle + analysis progress view model (slice-09-ux.md).
//

import Foundation
import Observation
import UIKit

@MainActor
protocol CleaningToggleStoring: AnyObject {
    var isChannelCleaningEnabled: Bool { get }
    var enabledEpisodeIDs: Set<String> { get }
    func isEpisodeCleaningEnabled(_ episodeID: String) -> Bool
    func setChannelCleaning(_ enabled: Bool)
    func setEpisodeCleaning(_ episodeID: String, enabled: Bool)
}

/// Adapts throwing `CleaningToggleStore` mutators to the non-throwing UI protocol.
@MainActor
final class CleaningToggleStoreAdapter: CleaningToggleStoring {
    nonisolated(unsafe) private let store: CleaningToggleStore

    init(_ store: CleaningToggleStore) {
        self.store = store
    }

    // Avoid MainActor/TaskLocal deinit crash (same pattern as AnalysisUIViewModel).
    nonisolated deinit {}

    var isChannelCleaningEnabled: Bool { store.isChannelCleaningEnabled }
    var enabledEpisodeIDs: Set<String> { store.enabledEpisodeIDs }

    func isEpisodeCleaningEnabled(_ episodeID: String) -> Bool {
        store.isEpisodeCleaningEnabled(episodeID)
    }

    func setChannelCleaning(_ enabled: Bool) {
        try? store.setChannelCleaning(enabled)
    }

    func setEpisodeCleaning(_ episodeID: String, enabled: Bool) {
        try? store.setEpisodeCleaning(episodeID, enabled: enabled)
    }
}

@MainActor @Observable
final class AnalysisUIViewModel {
    private(set) var state: AnalysisUIState = .off
    private(set) var isChannelCleaningEnabled = false
    @ObservationIgnored let store: any CleaningToggleStoring
    private(set) var analyzingEpisodeID: String?
    private(set) var contentGeneration = 0

    @ObservationIgnored private let analyzer: InstantEpisodeAnalyzer
    @ObservationIgnored private let autoAnalyzeEpisodeEnable: Bool
    @ObservationIgnored private let settingsStore: SettingsStore
    @ObservationIgnored var onAnalyzingEpisodeIDChanged: (() -> Void)?

    init(
        store: any CleaningToggleStoring,
        analyzer: InstantEpisodeAnalyzer,
        autoAnalyzeOnEpisodeEnable: Bool = false,
        settingsStore: SettingsStore = SettingsStore()
    ) {
        self.store = store
        self.analyzer = analyzer
        self.autoAnalyzeEpisodeEnable = autoAnalyzeOnEpisodeEnable
        self.settingsStore = settingsStore
        syncStateFromStore()
    }

    var autoAnalyzeOnEpisodeEnable: Bool {
        autoAnalyzeEpisodeEnable || FixtureAnalysis.isEnabled
    }

    private var shouldAutoAnalyzeOnEpisodeEnable: Bool {
        autoAnalyzeOnEpisodeEnable
    }

    nonisolated deinit {}

    /// Attempts a state-machine transition; returns false when illegal.
    @discardableResult
    func transition(to newState: AnalysisUIState) -> Bool {
        guard state.legalNextStates.contains(newState) else {
            return false
        }
        state = newState
        markContentChanged()
        return true
    }

    func syncStateFromStore() {
        isChannelCleaningEnabled = store.isChannelCleaningEnabled
        let newState: AnalysisUIState
        if analyzingEpisodeID != nil {
            newState = .analyzing
        } else if store.isChannelCleaningEnabled {
            newState = .channelOn
        } else if !store.enabledEpisodeIDs.isEmpty {
            newState = .episodeOn
        } else {
            newState = .off
        }
        guard state != newState else { return }
        state = newState
        markContentChanged()
    }

    func setChannelCleaning(_ enabled: Bool) {
        store.setChannelCleaning(enabled)
        isChannelCleaningEnabled = enabled
        if enabled {
            _ = transition(to: .channelOn)
        } else if analyzingEpisodeID == nil {
            _ = transition(to: .off)
        }
        syncStateFromStore()
        markContentChanged()
    }

    func setEpisodeCleaning(episodeID: String, enabled: Bool) async {
        store.setEpisodeCleaning(episodeID, enabled: enabled)
        if enabled {
            if shouldAutoAnalyzeOnEpisodeEnable {
                primeEpisodeCleaningToggle(episodeID: episodeID)
                await completePrimedEpisodeAnalysis(episodeID: episodeID)
            } else {
                analyzingEpisodeID = nil
                _ = transition(to: .episodeOn)
                syncStateFromStore()
                markContentChanged()
            }
        } else {
            analyzingEpisodeID = nil
            if store.isChannelCleaningEnabled {
                _ = transition(to: .channelOn)
            } else if store.enabledEpisodeIDs.isEmpty {
                _ = transition(to: .off)
            } else {
                _ = transition(to: .episodeOn)
            }
            syncStateFromStore()
            markContentChanged()
        }
    }

    func completePrimedEpisodeAnalysis(episodeID: String) async {
        guard shouldAutoAnalyzeOnEpisodeEnable else {
            analyzingEpisodeID = nil
            markContentChanged()
            return
        }

        // Fixture UITests register an `analysisProgress` expectation before the
        // toggle tap, then wait for post-tap idle. Hold `.analyzing` on the main
        // actor with `Task.sleep` (does not block XCTest idleness the way
        // `DispatchQueue.main.asyncAfter` does) so the progress control stays in
        // the AX tree for the 2 s appear window. Clear only after analyze returns.
        // Keep toggle→done under AC ≤5 s. Use 3.5 s so post-tap work from the
        // download accessory / SwiftUI update can settle before the window closes.
        if FixtureAnalysis.isEnabled {
            try? await Task.sleep(for: .milliseconds(3_500))
        }

        let identity = EpisodeIdentity(id: episodeID)
        let audioURL = URL(string: "https://fixture.podwash.tests/episode-audio")!
        _ = try? await analyzer.analyze(
            episode: identity,
            audioURL: audioURL,
            targetWords: settingsStore.activeNormalizedTargetSet(),
            injectedTranscript: []
        )

        analyzingEpisodeID = nil
        if store.isEpisodeCleaningEnabled(episodeID) {
            _ = transition(to: .episodeOn)
        } else if store.isChannelCleaningEnabled {
            _ = transition(to: .channelOn)
        } else {
            _ = transition(to: .off)
        }
        syncStateFromStore()
        markContentChanged()
    }

    func episodeRowShowsProgress(episodeID: String) -> Bool {
        analyzingEpisodeID == episodeID
    }

    func episodeRowShowsOnBadge(episodeID: String) -> Bool {
        analyzingEpisodeID != episodeID && store.isEpisodeCleaningEnabled(episodeID)
    }

    /// Updates store and surfaces analysis progress synchronously when a toggle turns on.
    func primeEpisodeCleaningToggle(episodeID: String) {
        guard shouldAutoAnalyzeOnEpisodeEnable else { return }
        store.setEpisodeCleaning(episodeID, enabled: true)
        analyzingEpisodeID = episodeID
        syncStateFromStore()
        markContentChanged()
    }

    private func markContentChanged() {
        contentGeneration += 1
        onAnalyzingEpisodeIDChanged?()
        UIAccessibility.post(notification: .layoutChanged, argument: nil)
    }
}
