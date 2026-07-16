//
//  QueueCoordinator.swift
//  PodWash
//
//  Slice 11 — Queue + EpisodePlaying wiring; auto-advance on end (ADR-009 §5).
//

import Foundation

@MainActor
final class QueueCoordinator {
    // nonisolated(unsafe): avoid MainActor TaskLocal hop when releasing these in deinit
    // (XCTest teardown otherwise hits BUG_IN_CLIENT_OF_LIBMALLOC via swift_task_deinitOnExecutorImpl).
    nonisolated(unsafe) private let queue: QueueStore
    nonisolated(unsafe) private let player: any EpisodePlaying
    nonisolated(unsafe) private let resume: ResumePositionStore
    nonisolated(unsafe) private let sessionStore: NowPlayingSessionStore?
    nonisolated(unsafe) private(set) var currentEpisodeID: String?

    /// Wires queue + resume Core Data stores to an `EpisodePlaying` surface.
    /// Optional `sessionStore` updates the durable active episode on end / advance (ADR-027).
    init(
        queue: QueueStore,
        player: any EpisodePlaying,
        resume: ResumePositionStore,
        sessionStore: NowPlayingSessionStore? = nil
    ) {
        self.queue = queue
        self.player = player
        self.resume = resume
        self.sessionStore = sessionStore
    }

    // Avoid MainActor/TaskLocal deinit crash (same pattern as AnalysisUIViewModel).
    // Keep this nonisolated so the test-host executable does not abort on teardown.
    nonisolated deinit {}

    /// Records the in-memory current episode without seeking or playing (paused restore).
    func bindCurrentEpisode(_ episodeID: String) {
        currentEpisodeID = episodeID
    }

    /// Sets current episode; restores saved position via `player.seek` then `play`
    /// when `resume.position(for:) > 0`.
    func playEpisode(_ episodeID: String) {
        currentEpisodeID = episodeID
        let position = resume.position(for: episodeID)
        if position > 0 {
            player.seek(to: position)
        }
        player.play(episodeID: episodeID)
    }

    /// Saves `resume` position from the supplied seconds (production passes engine time).
    /// When `currentEpisodeID` is unset, falls back to the first persisted episode ID
    /// (feed order) so pause-before-play still records a position for the active feed.
    func pause(savingPosition seconds: TimeInterval) {
        player.pause()
        let episodeID = currentEpisodeID ?? resume.firstEpisodeID()
        guard let episodeID else { return }
        try? resume.setPosition(seconds, for: episodeID)
    }

    /// AC2 entry: treat `episodeID` as finished.
    func handlePlaybackEnded(episodeID: String, duration: TimeInterval?) {
        if let duration, duration > 0 {
            try? resume.recordProgress(
                episodeID: episodeID,
                seconds: duration,
                duration: duration
            )
        } else {
            try? resume.setPlayed(true, for: episodeID)
        }

        let ids = queue.queueEpisodeIDs()
        guard let nextID = ids.first else {
            currentEpisodeID = nil
            try? sessionStore?.clear()
            return
        }

        try? queue.remove(nextID)
        currentEpisodeID = nextID
        try? sessionStore?.setActiveEpisodeID(nextID)
        player.play(episodeID: nextID)
    }
}
