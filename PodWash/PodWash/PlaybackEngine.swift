//
//  PlaybackEngine.swift
//  PodWash
//
//  Slice 03 — AVPlayer wrapper with observable playback state (ADR-001).
//

import AVFoundation
import Foundation

enum AudioSessionConfigurator {
    static func activatePlaybackSession() {
        let session = AVAudioSession.sharedInstance()
        try? session.setCategory(.playback, mode: .default)
        try? session.setActive(true)
    }
}

@MainActor
@Observable
final class PlaybackEngine {
    private(set) var currentTime: TimeInterval = 0
    private(set) var duration: TimeInterval = 0
    private(set) var uiRefreshToken = 0

    private let player: AVPlayer
    private let title: String
    private let artist: String
    private let nowPlayingUpdater: any NowPlayingInfoUpdating

    /// Exposed for unit tests that observe `timeControlStatus` via KVO.
    var avPlayer: AVPlayer { player }

    var isPlaying: Bool {
        player.timeControlStatus == .playing
    }

    init(
        url: URL,
        title: String,
        artist: String,
        nowPlayingUpdater: (any NowPlayingInfoUpdating)? = nil
    ) {
        let item = AVPlayerItem(url: url)
        player = AVPlayer(playerItem: item)
        self.title = title
        self.artist = artist
        self.nowPlayingUpdater = nowPlayingUpdater ?? MPNowPlayingInfoCenterUpdater()

        Task {
            await loadDuration(from: item.asset)
        }
    }

    func play() {
        AudioSessionConfigurator.activatePlaybackSession()
        player.play()
        refreshCurrentTime()
        touchUI()
        updateNowPlaying()
    }

    func pause() {
        player.pause()
        refreshCurrentTime()
        touchUI()
    }

    func seek(to seconds: TimeInterval, completion: (() -> Void)? = nil) {
        let upperBound = duration > 0 ? duration : .greatestFiniteMagnitude
        let clamped = max(0, min(upperBound, seconds))
        let time = CMTime(seconds: clamped, preferredTimescale: 600)
        player.seek(to: time, toleranceBefore: .zero, toleranceAfter: .zero) { [weak self] finished in
            Task { @MainActor [weak self] in
                guard let self else {
                    completion?()
                    return
                }
                if finished {
                    self.refreshCurrentTime()
                    self.touchUI()
                }
                completion?()
            }
        }
    }

    func seek(by delta: TimeInterval) {
        refreshCurrentTime()
        seek(to: currentTime + delta)
    }

    func refreshCurrentTime() {
        currentTime = player.currentTime().seconds
    }

    func touchUI() {
        uiRefreshToken &+= 1
    }

    private func updateNowPlaying() {
        nowPlayingUpdater.updateNowPlayingInfo(
            title: title,
            artist: artist,
            duration: duration,
            elapsed: currentTime
        )
    }

    private func loadDuration(from asset: AVAsset) async {
        do {
            let loadedDuration = try await asset.load(.duration)
            duration = loadedDuration.seconds
            touchUI()
        } catch {
            duration = 0
        }
    }
}
