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
