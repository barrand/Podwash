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

    /// The currently attached censor schedule, or `nil` if none (ADR-002 §3).
    private(set) var activeSchedule: IntervalSchedule?

    private let player: AVPlayer
    private let title: String
    private let artist: String
    private let nowPlayingUpdater: any NowPlayingInfoUpdating

    /// Boundary time observer token for `.skip` intervals; removed on re-apply/deinit.
    /// `nonisolated(unsafe)`: only mutated on the main actor, but `deinit` (nonisolated)
    /// must read it to tear the observer down.
    private nonisolated(unsafe) var skipObserverToken: Any?

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

    // MARK: - Interval schedule (Slice 04 — ADR-002 §3, additive)

    /// Attaches the mute mix to the current item and arms the skip observer.
    /// Additive: the play/pause/seek surface from ADR-001 is unchanged. Idempotent —
    /// calling it again rebuilds/replaces the mix and re-arms the observer.
    func applySchedule(_ schedule: IntervalSchedule) async {
        removeSkipObserver()

        if let item = player.currentItem {
            let mix = try? await IntervalScheduler.makeAudioMix(
                for: item.asset,
                intervals: schedule.intervals,
                fadeDuration: schedule.fadeDuration
            )
            item.audioMix = mix
        }

        let skips = IntervalScheduler.skipIntervals(from: schedule.intervals)
        if !skips.isEmpty {
            let times = skips.map {
                NSValue(time: CMTime(seconds: $0.start, preferredTimescale: 600))
            }
            skipObserverToken = player.addBoundaryTimeObserver(
                forTimes: times,
                queue: .main
            ) { [weak self] in
                MainActor.assumeIsolated {
                    self?.handleSkipBoundary(skips: skips)
                }
            }
        }

        activeSchedule = schedule
    }

    /// Boundary fired at a `.skip` start: seek past the interval end (ADR-002 §5).
    private func handleSkipBoundary(skips: [CensorInterval]) {
        let now = player.currentTime().seconds
        guard let skip = skips.first(where: { now >= $0.start - 0.05 && now < $0.end }) else {
            return
        }
        skipSeek(to: skip.end)
    }

    /// Skip seek variant (ADR-002 §5): lands `currentTime` in `[end − 0.1, end]`
    /// (`toleranceBefore = 0.1 s`, `toleranceAfter = .zero`) so it never overshoots,
    /// and does NOT pause, so `timeControlStatus` stays `.playing` (AC4). Additive —
    /// the public `seek(to:completion:)` signature/behavior is untouched.
    private func skipSeek(to seconds: TimeInterval) {
        let upperBound = duration > 0 ? duration : .greatestFiniteMagnitude
        let clamped = max(0, min(upperBound, seconds))
        let time = CMTime(seconds: clamped, preferredTimescale: 600)
        player.seek(
            to: time,
            toleranceBefore: CMTime(seconds: 0.1, preferredTimescale: 600),
            toleranceAfter: .zero
        ) { [weak self] finished in
            Task { @MainActor [weak self] in
                guard let self else { return }
                if finished {
                    self.refreshCurrentTime()
                    self.touchUI()
                }
            }
        }
    }

    private func removeSkipObserver() {
        if let token = skipObserverToken {
            player.removeTimeObserver(token)
            skipObserverToken = nil
        }
    }

    deinit {
        if let token = skipObserverToken {
            player.removeTimeObserver(token)
        }
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
