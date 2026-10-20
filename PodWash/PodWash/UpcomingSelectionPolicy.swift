//
//  UpcomingSelectionPolicy.swift
//  PodWash
//
//  The one, value-only definition of "what is next".  Keeping this out of
//  SwiftUI and the worker means Queue, autoplay, and preparation cannot drift.
//

import Foundation

nonisolated struct UpcomingSelection: Equatable, Sendable {
    enum Origin: Equatable, Sendable { case manual, automatic }
    let episodeID: String
    let origin: Origin
}

nonisolated struct UpcomingSelectionPolicy: Sendable {
    static let readyTarget = 2

    /// The one listener-visible projection of what will play after the current
    /// episode. Manual entries are durable; autoplay entries are a forecast.
    struct PlaybackPlan: Equatable, Sendable {
        let manualEpisodeIDs: [String]
        let autoplay: [ComingUpItem]

        var preparationEpisodeIDs: [String] {
            Array((manualEpisodeIDs + autoplay.map(\.episodeID)).prefix(UpcomingSelectionPolicy.readyTarget))
        }
    }

    /// Builds the full Queue projection. Callers supply predictions that already
    /// exclude manual IDs so Queue, playback, and warming cannot disagree.
    func playbackPlan(
        manualQueueIDs: [String],
        autoplay: [ComingUpItem],
        smartAutoplayEnabled: Bool
    ) -> PlaybackPlan {
        var seen = Set<String>()
        let manual = manualQueueIDs.filter { !$0.isEmpty && seen.insert($0).inserted }
        let automatic = smartAutoplayEnabled
            ? autoplay.filter { seen.insert($0.episodeID).inserted }.prefix(Self.readyTarget)
            : []
        return PlaybackPlan(manualEpisodeIDs: manual, autoplay: Array(automatic))
    }

    /// Preparation ownership is bounded independently of the complete listening order.
    func preparationWindow(
        currentEpisodeID: String?,
        manualQueueIDs: [String],
        predictions: [ComingUpItem],
        automaticPreparationEnabled: Bool
    ) -> [String] {
        guard automaticPreparationEnabled else { return [] }
        return Array(select(
            currentEpisodeID: currentEpisodeID,
            manualQueueIDs: manualQueueIDs,
            predictions: predictions,
            automaticPreparationEnabled: true
        ).prefix(Self.readyTarget).map(\.episodeID))
    }

    /// Manual entries always remain in their saved order. Predictions are only
    /// used to fill the first two choices and never include the current item or
    /// a manual duplicate.
    func select(
        currentEpisodeID: String?,
        manualQueueIDs: [String],
        predictions: [ComingUpItem],
        automaticPreparationEnabled: Bool,
        suppressedAutomaticEpisodeIDs: Set<String> = []
    ) -> [UpcomingSelection] {
        var seen = Set<String>()
        if let currentEpisodeID { seen.insert(currentEpisodeID) }
        let manual = manualQueueIDs.compactMap { id -> UpcomingSelection? in
            guard !id.isEmpty, seen.insert(id).inserted else { return nil }
            return UpcomingSelection(episodeID: id, origin: .manual)
        }
        guard automaticPreparationEnabled else { return manual }
        let remaining = max(0, Self.readyTarget - manual.count)
        guard remaining > 0 else { return manual }
        let automatic = predictions.compactMap { item -> UpcomingSelection? in
            guard !suppressedAutomaticEpisodeIDs.contains(item.episodeID),
                  seen.insert(item.episodeID).inserted else { return nil }
            return UpcomingSelection(episodeID: item.episodeID, origin: .automatic)
        }.prefix(remaining)
        return manual + automatic
    }
}
