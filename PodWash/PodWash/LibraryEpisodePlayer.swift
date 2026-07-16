//
//  LibraryEpisodePlayer.swift
//  PodWash
//
//  Slice 23 — EpisodePlaying adapter for QueueCoordinator (ADR-015 §4).
//

import Foundation

@MainActor
final class LibraryEpisodePlayer: EpisodePlaying {
    /// `nonisolated(unsafe)`: released from `nonisolated deinit` without a MainActor TaskLocal hop
    /// (NowPlayingSessionTests otherwise SIGABRT via swift_task_deinitOnExecutorImpl).
    nonisolated(unsafe) private let engine: PlaybackEngine

    init(engine: PlaybackEngine) {
        self.engine = engine
    }

    // Avoid MainActor/TaskLocal deinit crash under SWIFT_DEFAULT_ACTOR_ISOLATION
    // (XCTest teardown / stopAndDismissPlayer otherwise SIGABRT via swift_task_deinitOnExecutorImpl).
    nonisolated deinit {}

    func play(episodeID: String) {
        _ = episodeID
        engine.play()
    }

    func pause() {
        engine.pause()
    }

    func seek(to seconds: TimeInterval) {
        engine.seek(to: seconds)
    }
}
