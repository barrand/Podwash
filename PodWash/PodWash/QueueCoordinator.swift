//
//  QueueCoordinator.swift
//  PodWash
//
//  Slice 11 — Queue + EpisodePlaying wiring; auto-advance on end (ADR-009 §5).
//  ADR-029 — Smart autoplay when Up Next is empty.
//

import Foundation

enum QueueAdvanceResolution: Equatable {
    case play(episodeID: String, consumesManualQueueEntry: Bool)
    case waiting(title: String)
    case none
}

@MainActor
final class QueueCoordinator {
    // nonisolated(unsafe): avoid MainActor TaskLocal hop when releasing these in deinit
    // (XCTest teardown otherwise hits BUG_IN_CLIENT_OF_LIBMALLOC via swift_task_deinitOnExecutorImpl).
    nonisolated(unsafe) private let queue: QueueStore
    /// Weak so AppShellModel can be the EpisodePlaying surface without a retain cycle.
    nonisolated(unsafe) private weak var player: (any EpisodePlaying)?
    nonisolated(unsafe) private let resume: ResumePositionStore
    nonisolated(unsafe) private let sessionStore: NowPlayingSessionStore?
    nonisolated(unsafe) private(set) var currentEpisodeID: String?

    var onEpisodeMarkedPlayed: ((String) -> Void)?
    /// Unified manual + radio decision. This supersedes the legacy two-closure
    /// split while remaining compatible with focused older coordinator tests.
    var resolveNext: ((_ endedEpisodeID: String, _ manualQueueIDs: [String]) -> QueueAdvanceResolution)?
    var onAdvanceWaiting: ((String) -> Void)?
    private var pendingAdvanceFromEpisodeID: String?

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
            player?.seek(to: position)
        }
        player?.play(episodeID: episodeID)
    }

    /// Saves `resume` position from the supplied seconds (production passes engine time).
    /// When `currentEpisodeID` is unset, falls back to the first persisted episode ID
    /// (feed order) so pause-before-play still records a position for the active feed.
    func pause(savingPosition seconds: TimeInterval) {
        player?.pause()
        let episodeID = currentEpisodeID ?? resume.firstEpisodeID()
        guard let episodeID else { return }
        try? resume.setPosition(seconds, for: episodeID)
    }

    /// AC2 entry: treat `episodeID` as finished; advance Up Next or smart autoplay.
    func handlePlaybackEnded(episodeID: String, duration: TimeInterval?) {
        advance(from: episodeID, duration: duration, markPlayed: true)
    }

    /// User-requested Next: retain the current episode's resume position and
    /// advance through manual Up Next before considering smart autoplay.
    func handleSkipToNext(episodeID: String, currentPosition: TimeInterval?) {
        if let currentPosition {
            try? resume.setPosition(currentPosition, for: episodeID)
        }
        advance(from: episodeID, duration: nil, markPlayed: false)
    }

    private func advance(
        from episodeID: String,
        duration: TimeInterval?,
        markPlayed: Bool
    ) {
        if markPlayed {
            if let duration, duration > 0 {
                try? resume.recordProgress(
                    episodeID: episodeID,
                    seconds: duration,
                    duration: duration
                )
            } else {
                try? resume.setPlayed(true, for: episodeID)
            }
            onEpisodeMarkedPlayed?(episodeID)
        }

        if let resolveNext {
            apply(resolveNext(episodeID, queue.queueEpisodeIDs()), from: episodeID)
            return
        }
        if let nextID = queue.queueEpisodeIDs().first {
            apply(.play(episodeID: nextID, consumesManualQueueEntry: true), from: episodeID)
        } else {
            apply(.none, from: episodeID)
        }
    }

    /// Called when preparation changes after an ended/Skipped episode was held
    /// at the handoff boundary. It never records completion a second time.
    func resumePendingAdvanceIfPossible() {
        guard let from = pendingAdvanceFromEpisodeID, let resolveNext else { return }
        apply(resolveNext(from, queue.queueEpisodeIDs()), from: from)
    }

    func cancelPendingAdvance() { pendingAdvanceFromEpisodeID = nil }

    private func apply(_ resolution: QueueAdvanceResolution, from episodeID: String) {
        switch resolution {
        case let .play(nextID, consumesManual):
            pendingAdvanceFromEpisodeID = nil
            if consumesManual { try? queue.remove(nextID) }
            currentEpisodeID = nextID
            try? sessionStore?.setActiveEpisodeID(nextID)
            player?.play(episodeID: nextID)
        case let .waiting(title):
            pendingAdvanceFromEpisodeID = episodeID
            onAdvanceWaiting?(title)
        case .none:
            pendingAdvanceFromEpisodeID = nil
            currentEpisodeID = nil
            try? sessionStore?.clear()
        }
    }
}
