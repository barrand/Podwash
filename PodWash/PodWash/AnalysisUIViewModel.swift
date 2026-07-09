//
//  AnalysisUIViewModel.swift
//  PodWash
//
//  Slice 09 — Cleaning toggle + analysis progress view model (slice-09-ux.md).
//

import Foundation
import Observation
import UIKit

@MainActor @Observable
final class AnalysisUIViewModel {
    private(set) var state: AnalysisUIState = .off
    private(set) var isChannelCleaningEnabled = false
    @ObservationIgnored let store: InMemoryCleaningToggleStore
    private(set) var analyzingEpisodeID: String?
    private(set) var contentGeneration = 0

    @ObservationIgnored private let analyzer: InstantEpisodeAnalyzer
    @ObservationIgnored private let autoAnalyzeEpisodeEnable: Bool
    @ObservationIgnored var onAnalyzingEpisodeIDChanged: (() -> Void)?

    init(
        store: InMemoryCleaningToggleStore,
        analyzer: InstantEpisodeAnalyzer,
        autoAnalyzeOnEpisodeEnable: Bool = false
    ) {
        self.store = store
        self.analyzer = analyzer
        self.autoAnalyzeEpisodeEnable = autoAnalyzeOnEpisodeEnable
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

        defer {
            analyzingEpisodeID = nil
            syncStateFromStore()
            markContentChanged()
        }

        let identity = EpisodeIdentity(id: episodeID)
        let audioURL = URL(string: "https://fixture.podwash.tests/episode-audio")!
        _ = try? await analyzer.analyze(
            episode: identity,
            audioURL: audioURL,
            targetWords: [],
            injectedTranscript: []
        )

        if store.isEpisodeCleaningEnabled(episodeID) {
            _ = transition(to: .episodeOn)
        } else if store.isChannelCleaningEnabled {
            _ = transition(to: .channelOn)
        } else {
            _ = transition(to: .off)
        }
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
