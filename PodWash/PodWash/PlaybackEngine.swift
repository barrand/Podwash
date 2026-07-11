//
//  PlaybackEngine.swift
//  PodWash
//
//  Slice 03 — AVPlayer wrapper with observable playback state (ADR-001).
//

import AVFoundation
import Foundation

@MainActor
@Observable
final class PlaybackEngine: PlaybackPausing, PlaybackTransporting {
    /// Discrete playback rates supported by the speed control (Slice 12).
    /// Nonisolated so SettingsStore (nonisolated) can snap default rates.
    nonisolated static let supportedRates: [Float] = [0.75, 1.0, 1.25, 1.5, 2.0, 3.0]

    private(set) var currentTime: TimeInterval = 0
    private(set) var duration: TimeInterval = 0
    private(set) var uiRefreshToken = 0

    /// Session-selected playback rate; re-applied on `play()` (not persisted across launches).
    private(set) var selectedRate: Float = 1.0

    /// The currently attached censor schedule, or `nil` if none (ADR-002 §3).
    private(set) var activeSchedule: IntervalSchedule?

    /// `nonisolated(unsafe)`: immutable after init; `deinit` must remove observers
    /// without a MainActor TaskLocal hop (test-host abort class).
    private nonisolated(unsafe) let player: AVPlayer
    private let title: String
    private let artist: String
    private let nowPlayingUpdater: any NowPlayingInfoUpdating
    private let audioSessionConfigurator: any AudioSessionConfiguring

    /// Boundary time observer token for `.skip` intervals; removed on re-apply/deinit.
    /// `nonisolated(unsafe)`: only mutated on the main actor, but `deinit` (nonisolated)
    /// must read it to tear the observer down.
    private nonisolated(unsafe) var skipObserverToken: Any?

    /// Fired after an unrelated-content `.skip` boundary seek completes (ADR-013 §3.6).
    /// `skippedSeconds` = end − start (for banner accessibilityValue rounding).
    var onUnrelatedContentSkip: ((CensorInterval, Double) -> Void)?

    /// Skip intervals the user has overridden (or that already fired) until schedule rebuild.
    private var overriddenSkipKeys: Set<SkipOverrideKey> = []

    /// When `play()` races ahead of `AVPlayerItem.readyToPlay`, retry once the item is ready.
    /// Needed because `automaticallyWaitsToMinimizeStalling = false` makes
    /// `playImmediately` a no-op if the item is not yet ready.
    private var pendingPlayWhenReady = false
    private var itemStatusObservation: NSKeyValueObservation?

    /// Exposed for unit tests that observe `timeControlStatus` via KVO.
    var avPlayer: AVPlayer { player }

    private struct SkipOverrideKey: Hashable {
        let start: Double
        let end: Double
        let source: IntervalSource

        init(_ interval: CensorInterval) {
            start = interval.start
            end = interval.end
            source = interval.source
        }
    }

    var isPlaying: Bool {
        player.timeControlStatus == .playing
    }

    /// Accessibility value for the speed control (`"0.75"` … `"3.0"`).
    var rateAccessibilityValue: String {
        Self.accessibilityValue(for: selectedRate)
    }

    init(
        url: URL,
        title: String,
        artist: String,
        nowPlayingUpdater: (any NowPlayingInfoUpdating)? = nil,
        audioSessionConfigurator: (any AudioSessionConfiguring)? = nil
    ) {
        let item = AVPlayerItem(url: url)
        player = AVPlayer(playerItem: item)
        // Prefer in-place rate changes without bouncing through
        // `.waitingToPlayAtSpecifiedRate` (avoids spurious timeControlStatus KVO).
        player.automaticallyWaitsToMinimizeStalling = false
        self.title = title
        self.artist = artist
        self.nowPlayingUpdater = nowPlayingUpdater ?? MPNowPlayingInfoCenterUpdater()
        self.audioSessionConfigurator = audioSessionConfigurator ?? AVAudioSessionPlaybackConfigurator()

        itemStatusObservation = item.observe(\.status, options: [.new]) { [weak self] observed, _ in
            Task { @MainActor [weak self] in
                self?.handleItemStatusChange(observed.status)
            }
        }

        Task {
            await loadDuration(from: item.asset)
        }
    }

    func play() {
        audioSessionConfigurator.activatePlaybackSession()
        startOrPendPlayback()
        refreshCurrentTime()
        touchUI()
        updateNowPlaying()
    }

    func pause() {
        pendingPlayWhenReady = false
        player.pause()
        refreshCurrentTime()
        touchUI()
        updateNowPlaying()
    }

    /// Starts playback immediately when the item is ready; otherwise arms a one-shot
    /// retry so `playImmediately` is not lost under `automaticallyWaitsToMinimizeStalling = false`.
    private func startOrPendPlayback() {
        if player.currentItem?.status == .readyToPlay {
            pendingPlayWhenReady = false
            player.playImmediately(atRate: selectedRate)
            return
        }
        pendingPlayWhenReady = true
        // Best-effort: some items accept playImmediately while still `.unknown`.
        player.playImmediately(atRate: selectedRate)
    }

    private func handleItemStatusChange(_ status: AVPlayerItem.Status) {
        guard pendingPlayWhenReady, status == .readyToPlay else { return }
        pendingPlayWhenReady = false
        player.playImmediately(atRate: selectedRate)
        refreshCurrentTime()
        touchUI()
        updateNowPlaying()
    }

    // MARK: - Playback rate (Slice 12)

    /// Sets a discrete supported rate. While playing, applies to `AVPlayer.rate`
    /// immediately; while paused, stores for the next `play()`.
    func setRate(_ rate: Float) {
        let resolved = Self.nearestSupportedRate(to: rate)
        selectedRate = resolved

        // Only touch AVPlayer while actively playing (or mid-rate). Prefer an
        // in-place `rate` write; if that parks us in waiting/paused, resume with
        // `playImmediately` so callers still observe `.playing` at `resolved`.
        let isActivelyPlaying =
            player.timeControlStatus == .playing || abs(player.rate) > 0.0001
        guard isActivelyPlaying else {
            touchUI()
            return
        }

        if abs(player.rate - resolved) > 0.0001 {
            player.rate = resolved
        }
        if player.timeControlStatus != .playing {
            player.playImmediately(atRate: resolved)
        }
        touchUI()
    }

    /// Advances through `supportedRates`, wrapping after the last entry.
    func cycleRate() {
        let rates = Self.supportedRates
        let index = rates.firstIndex(of: selectedRate) ?? rates.firstIndex(of: 1.0) ?? 0
        let next = rates[(index + 1) % rates.count]
        setRate(next)
    }

    /// Accessibility value for the speed control (`"0.75"` … `"3.0"`).
    nonisolated static func accessibilityValue(for rate: Float) -> String {
        switch rate {
        case 0.75: return "0.75"
        case 1.0: return "1.0"
        case 1.25: return "1.25"
        case 1.5: return "1.5"
        case 2.0: return "2.0"
        case 3.0: return "3.0"
        default:
            return String(format: "%g", rate)
        }
    }

    private static func nearestSupportedRate(to rate: Float) -> Float {
        if supportedRates.contains(rate) { return rate }
        return supportedRates.min(by: { abs($0 - rate) < abs($1 - rate) }) ?? 1.0
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
                    self.updateNowPlaying()
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
        overriddenSkipKeys.removeAll()

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

    /// Seek to interval.start (tolerance → [start ± 0.05]) and suppress that
    /// interval’s skip until schedule re-applied (ADR-013 §3.6).
    func overrideUnrelatedContentSkip(_ interval: CensorInterval) {
        overriddenSkipKeys.insert(SkipOverrideKey(interval))
        let upperBound = duration > 0 ? duration : .greatestFiniteMagnitude
        let clamped = max(0, min(upperBound, interval.start))
        let time = CMTime(seconds: clamped, preferredTimescale: 600)
        let tolerance = CMTime(seconds: 0.05, preferredTimescale: 600)
        player.seek(
            to: time,
            toleranceBefore: tolerance,
            toleranceAfter: tolerance
        ) { [weak self] finished in
            Task { @MainActor [weak self] in
                guard let self else { return }
                if finished {
                    self.refreshCurrentTime()
                    self.touchUI()
                    self.updateNowPlaying()
                }
                // Keep playing after override seek (AC3).
                if self.player.timeControlStatus != .playing {
                    self.startOrPendPlayback()
                }
            }
        }
    }

    /// Boundary fired at a `.skip` start: seek past the interval end (ADR-002 §5).
    private func handleSkipBoundary(skips: [CensorInterval]) {
        let now = player.currentTime().seconds
        // Drop override keys once playback has passed the segment end.
        overriddenSkipKeys = overriddenSkipKeys.filter { now < $0.end }

        guard let skip = skips.first(where: { now >= $0.start - 0.05 && now < $0.end }) else {
            return
        }
        let key = SkipOverrideKey(skip)
        guard !overriddenSkipKeys.contains(key) else { return }

        // Suppress re-entry for this span until playback passes end / schedule rebuild
        // (ADR-013 §3.6 — after a skip fires or the user overrides).
        overriddenSkipKeys.insert(key)

        skipSeek(to: skip.end) { [weak self] in
            guard let self else { return }
            if skip.source == .unrelatedContent {
                let skippedSeconds = skip.end - skip.start
                self.onUnrelatedContentSkip?(skip, skippedSeconds)
            }
        }
    }

    /// Skip seek variant (ADR-002 §5): lands `currentTime` in `[end − 0.1, end]`
    /// (`toleranceBefore = 0.1 s`, `toleranceAfter = .zero`) so it never overshoots,
    /// and does NOT pause, so `timeControlStatus` stays `.playing` (AC4). Additive —
    /// the public `seek(to:completion:)` signature/behavior is untouched.
    private func skipSeek(to seconds: TimeInterval, completion: (() -> Void)? = nil) {
        // Seeking exactly to asset duration often cancels (`finished == false`) or
        // ends the item; prefer a target still inside ADR-002's [end − 0.1, end]
        // window when `seconds` is at/past EOF.
        var target = seconds
        if duration > 0.1, target >= duration - 0.001 {
            // Only nudge off EOF — do not clamp mid-file skip ends.
            target = min(target, duration - 0.05)
        }
        target = max(0, target)
        let time = CMTime(seconds: target, preferredTimescale: 600)
        player.seek(
            to: time,
            toleranceBefore: CMTime(seconds: 0.1, preferredTimescale: 600),
            toleranceAfter: .zero
        ) { [weak self] _ in
            Task { @MainActor [weak self] in
                guard let self else {
                    completion?()
                    return
                }
                // Always sample the playhead — EOF seeks may report !finished while
                // still landing inside the allowed window.
                self.refreshCurrentTime()
                self.touchUI()
                self.updateNowPlaying()
                if self.player.timeControlStatus != .playing {
                    self.startOrPendPlayback()
                }
                completion?()
            }
        }
    }

    private func removeSkipObserver() {
        if let token = skipObserverToken {
            player.removeTimeObserver(token)
            skipObserverToken = nil
        }
    }

    // Avoid MainActor/TaskLocal deinit crash (same pattern as QueueCoordinator).
    nonisolated deinit {
        if let token = skipObserverToken {
            player.removeTimeObserver(token)
            skipObserverToken = nil
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
