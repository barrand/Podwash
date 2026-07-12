//
//  AnalysisUIViewModel.swift
//  PodWash
//
//  Slice 09 — Cleaning toggle + analysis progress view model (slice-09-ux.md).
//  Slice 20 — Progress snapshot + timeline AX (ADR-018).
//

import Foundation
import Observation
import UIKit

@MainActor
protocol CleaningToggleStoring: AnyObject {
    var isChannelCleaningEnabled: Bool { get }
    var isChannelUnrelatedContentEnabled: Bool { get }
    var enabledEpisodeIDs: Set<String> { get }
    func isEpisodeCleaningEnabled(_ episodeID: String) -> Bool
    func setChannelCleaning(_ enabled: Bool)
    func setChannelUnrelatedContent(_ enabled: Bool)
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
    var isChannelUnrelatedContentEnabled: Bool { store.isChannelUnrelatedContentEnabled }
    var enabledEpisodeIDs: Set<String> { store.enabledEpisodeIDs }

    func isEpisodeCleaningEnabled(_ episodeID: String) -> Bool {
        store.isEpisodeCleaningEnabled(episodeID)
    }

    func setChannelCleaning(_ enabled: Bool) {
        try? store.setChannelCleaning(enabled)
    }

    func setChannelUnrelatedContent(_ enabled: Bool) {
        try? store.setChannelUnrelatedContent(enabled)
    }

    func setEpisodeCleaning(_ episodeID: String, enabled: Bool) {
        try? store.setEpisodeCleaning(episodeID, enabled: enabled)
    }
}

@MainActor @Observable
final class AnalysisUIViewModel {
    private(set) var state: AnalysisUIState = .off
    private(set) var isChannelCleaningEnabled = false
    private(set) var isChannelUnrelatedContentEnabled = false
    @ObservationIgnored let store: any CleaningToggleStoring
    private(set) var analyzingEpisodeID: String?
    private(set) var progressSnapshot: AnalysisProgressSnapshot?
    private(set) var contentGeneration = 0

    @ObservationIgnored private let analyzer: any EpisodeAnalyzing
    @ObservationIgnored private let autoAnalyzeEpisodeEnable: Bool
    @ObservationIgnored private let settingsStore: SettingsStore
    @ObservationIgnored private var progressHandlerID: UUID?
    @ObservationIgnored var onAnalyzingEpisodeIDChanged: (() -> Void)?

    init(
        store: any CleaningToggleStoring,
        analyzer: any EpisodeAnalyzing,
        autoAnalyzeOnEpisodeEnable: Bool = false,
        settingsStore: SettingsStore = SettingsStore(),
        progressRelay: AnalysisProgressRelay? = nil
    ) {
        self.store = store
        self.analyzer = analyzer
        self.autoAnalyzeEpisodeEnable = autoAnalyzeOnEpisodeEnable
        self.settingsStore = settingsStore
        if let progressRelay {
            progressHandlerID = progressRelay.addHandler { [weak self] snapshot in
                guard let self else { return }
                self.progressSnapshot = snapshot
                self.markContentChanged()
            }
        } else {
            wireProgressHandler()
        }
        syncStateFromStore()
    }

    var autoAnalyzeOnEpisodeEnable: Bool {
        autoAnalyzeEpisodeEnable
            || FixtureAnalysis.isEnabled
            || FixtureAnalysisTimeline.isEnabled
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
        isChannelUnrelatedContentEnabled = store.isChannelUnrelatedContentEnabled
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

    func setChannelUnrelatedContent(_ enabled: Bool) {
        store.setChannelUnrelatedContent(enabled)
        isChannelUnrelatedContentEnabled = enabled
        markContentChanged()
    }

    func setEpisodeCleaning(episodeID: String, enabled: Bool) async {
        if enabled && shouldAutoAnalyzeOnEpisodeEnable {
            store.setEpisodeCleaning(episodeID, enabled: enabled)
            primeEpisodeCleaningToggle(episodeID: episodeID)
            await completePrimedEpisodeAnalysis(episodeID: episodeID)
            return
        }
        applyEpisodeCleaningWithoutAnalysis(episodeID: episodeID, enabled: enabled)
    }

    /// Non-auto toggle path used by UITests that assert badges on post-tap idle.
    func applyEpisodeCleaningWithoutAnalysis(episodeID: String, enabled: Bool) {
        store.setEpisodeCleaning(episodeID, enabled: enabled)
        progressSnapshot = nil
        if enabled {
            analyzingEpisodeID = nil
            _ = transition(to: .episodeOn)
            syncStateFromStore()
            markContentChanged()
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
            progressSnapshot = nil
            markContentChanged()
            return
        }

        // Fixture UITests wait for `analysisTimeline` AX values after the toggle
        // tap. Hold `.analyzing` with `Task.sleep` (does not block XCTest idleness
        // the way `DispatchQueue.main.asyncAfter` does) so the timeline stays in
        // the AX tree while waiters poll. Clear only after the observable window.
        // Keep toggle→done under AC ≤5 s.
        if FixtureAnalysis.isEnabled && !FixtureAnalysisTimeline.isEnabled {
            // Slice 09: single hold so appear + disappear assertions can settle.
            try? await Task.sleep(for: .milliseconds(3_500))
        }
        if FixtureAnalysisTimeline.isEnabled {
            // Re-assert primed first snapshot in case a SwiftUI representable
            // refresh cleared it before the observable window.
            if progressSnapshot == nil {
                progressSnapshot = FixtureAnalysisTimeline.pinnedSnapshots.first
                markContentChanged()
            }
            // Hold primed `ready:3,…` across post-tap idle *and* AC3's 2.0 s
            // wait window. XCTest's tap() returns once Task.sleep yields idle;
            // the waiter then needs the first snapshot still in the AX tree.
            // (1.2 s was too short once idle settle ate into the window.)
            try? await Task.sleep(for: .milliseconds(2_500))
        }

        let identity = EpisodeIdentity(id: episodeID)
        let audioURL = URL(string: "https://fixture.podwash.tests/episode-audio")!
        let effectiveUnrelated = UnrelatedContentOptions(
            enabled: settingsStore.unrelatedContentEnabled && store.isChannelUnrelatedContentEnabled,
            action: settingsStore.unrelatedCensorAction()
        )
        _ = try? await analyzer.analyze(
            episode: identity,
            audioURL: audioURL,
            targetWords: settingsStore.activeNormalizedTargetSet(),
            injectedTranscript: [],
            profanityAction: settingsStore.censorAction(),
            unrelatedContent: effectiveUnrelated
        )

        if FixtureAnalysisTimeline.isEnabled {
            // Hold terminal `ready:12,…` before retiring the timeline (AC4).
            try? await Task.sleep(for: .milliseconds(500))
        }

        analyzingEpisodeID = nil
        progressSnapshot = nil
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

    func episodeRowShowsTimeline(episodeID: String) -> Bool {
        analyzingEpisodeID == episodeID && progressSnapshot != nil
    }

    func episodeRowTimelineAccessibilityValue(episodeID: String) -> String? {
        guard episodeRowShowsTimeline(episodeID: episodeID),
              let snapshot = progressSnapshot else { return nil }
        let colors = AnalysisTimelineModel.segmentColors(snapshot: snapshot)
        return AnalysisTimelineModel.accessibilityValue(from: colors)
    }

    func episodeRowTimelineColors(episodeID: String) -> [TimelineSegmentColor]? {
        guard episodeRowShowsTimeline(episodeID: episodeID),
              let snapshot = progressSnapshot else { return nil }
        return AnalysisTimelineModel.segmentColors(snapshot: snapshot)
    }

    func episodeRowShowsOnBadge(episodeID: String) -> Bool {
        analyzingEpisodeID != episodeID && store.isEpisodeCleaningEnabled(episodeID)
    }

    /// Updates store and surfaces analysis progress synchronously when a toggle turns on.
    func primeEpisodeCleaningToggle(episodeID: String) {
        guard shouldAutoAnalyzeOnEpisodeEnable else { return }
        store.setEpisodeCleaning(episodeID, enabled: true)
        analyzingEpisodeID = episodeID
        // Seed a snapshot before paint so `analysisTimeline` exists for XCTest
        // appear windows (Slice 09 lifecycle + Slice 20 first snapshot).
        if FixtureAnalysisTimeline.isEnabled {
            progressSnapshot = FixtureAnalysisTimeline.pinnedSnapshots.first
        } else {
            progressSnapshot = AnalysisProgressSnapshot(
                episodeDuration: FixtureAnalysisTimeline.episodeDuration,
                processedEnd: 0,
                processingStart: 0,
                processingEnd: FixtureAnalysisTimeline.bucketWidth,
                adRanges: []
            )
        }
        syncStateFromStore()
        markContentChanged()
    }

    private func wireProgressHandler() {
        // Prefer a @MainActor sink invoked inside `MainActor.run` so each
        // snapshot is published before the next paced wait (a nested
        // `Task { @MainActor }` can be deferred past the wait / analyze return).
        let mainActorHandler: MainActorAnalysisProgressHandler = { [weak self] snapshot in
            guard let self else { return }
            self.progressSnapshot = snapshot
            self.markContentChanged()
        }
        if let stepped = analyzer as? SteppedEpisodeAnalyzer {
            stepped.onMainActorProgress = mainActorHandler
        }
        if let instant = analyzer as? InstantEpisodeAnalyzer {
            instant.onMainActorProgress = mainActorHandler
        }
    }

    private func markContentChanged() {
        contentGeneration += 1
        onAnalyzingEpisodeIDChanged?()
        UIAccessibility.post(notification: .layoutChanged, argument: nil)
    }
}
