//
//  LibraryEpisodePlayer.swift
//  PodWash
//
//  Slice 23 — EpisodePlaying adapter for QueueCoordinator (ADR-015 §4).
//

import Foundation

@MainActor
final class LibraryEpisodePlayer: EpisodePlaying {
    private let engine: PlaybackEngine

    init(engine: PlaybackEngine) {
        self.engine = engine
    }

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
