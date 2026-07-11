//
//  CarPlayNowPlayingUpdater.swift
//  PodWash
//
//  Slice 15 — Forwards PlaybackEngine play/pause into CarPlayNowPlayingPresenting (ADR-016 §6).
//

import Foundation

@MainActor
final class CarPlayNowPlayingUpdater {
    // nonisolated(unsafe): avoid MainActor TaskLocal hop when releasing in deinit
    // (XCTest teardown otherwise SIGABRT via swift_task_deinitOnExecutorImpl).
    nonisolated(unsafe) private let engine: PlaybackEngine
    nonisolated(unsafe) private let presenting: any CarPlayNowPlayingPresenting
    nonisolated(unsafe) private var didAttach = false

    init(engine: PlaybackEngine, presenting: any CarPlayNowPlayingPresenting) {
        self.engine = engine
        self.presenting = presenting
    }

    // Avoid MainActor/TaskLocal deinit crash under SWIFT_DEFAULT_ACTOR_ISOLATION
    // (XCTest teardown otherwise SIGABRT via swift_task_deinitOnExecutorImpl).
    // Clear the engine callback here — `onPlayPauseIntent` is nonisolated(unsafe).
    nonisolated deinit {
        engine.onPlayPauseIntent = nil
    }

    /// Registers for synchronous play/pause intent callbacks on the engine.
    func attach() {
        guard !didAttach else { return }
        didAttach = true

        engine.onPlayPauseIntent = { [weak self] isPlaying in
            guard let self else { return }
            if isPlaying {
                self.presenting.updateTitle(self.engine.nowPlayingTitle)
                self.presenting.updatePlaybackState(.playing)
            } else {
                self.presenting.updatePlaybackState(.paused)
            }
        }
    }
}
