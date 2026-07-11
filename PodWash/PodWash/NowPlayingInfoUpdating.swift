//
//  NowPlayingInfoUpdating.swift
//  PodWash
//
//  Slice 03 — Now Playing metadata injection point (ADR-001).
//

import Foundation
import MediaPlayer

protocol NowPlayingInfoUpdating: AnyObject {
    func updateNowPlayingInfo(
        title: String,
        artist: String,
        duration: TimeInterval,
        elapsed: TimeInterval
    )
}

final class MPNowPlayingInfoCenterUpdater: NowPlayingInfoUpdating {
    // Avoid MainActor/TaskLocal deinit crash under SWIFT_DEFAULT_ACTOR_ISOLATION
    // (XCTest teardown otherwise SIGABRT via swift_task_deinitOnExecutorImpl when
    // PlaybackEngine releases this updater — OverlaySyncTests crash class).
    nonisolated deinit {}

    func updateNowPlayingInfo(
        title: String,
        artist: String,
        duration: TimeInterval,
        elapsed: TimeInterval
    ) {
        MPNowPlayingInfoCenter.default().nowPlayingInfo = [
            MPMediaItemPropertyTitle: title,
            MPMediaItemPropertyArtist: artist,
            MPMediaItemPropertyPlaybackDuration: duration,
            MPNowPlayingInfoPropertyElapsedPlaybackTime: elapsed,
        ]
    }
}
