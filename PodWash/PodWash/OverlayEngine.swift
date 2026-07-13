//
//  OverlayEngine.swift
//  PodWash
//
//  Slice 16 — Boundary-observer + AVAudioPlayer mute overlay (ADR-017).
//

import AVFoundation
import Foundation

/// Schedules beep/quack overlay on mute interval boundaries (player timeline).
@MainActor
final class OverlayEngine {

    /// `nonisolated(unsafe)`: immutable after init; `deinit` must remove observers
    /// without a MainActor TaskLocal hop (test-host abort class).
    private nonisolated(unsafe) let player: AVPlayer
    /// `nonisolated(unsafe)`: released from `nonisolated deinit` without a MainActor hop.
    private nonisolated(unsafe) let eventRecorder: (any OverlayEventRecording)?
    private let assetBundle: Bundle

    /// `nonisolated(unsafe)`: torn down from `deinit` as well as MainActor methods.
    private nonisolated(unsafe) var boundaryObserverToken: Any?
    /// `nonisolated(unsafe)`: stopped/released from `nonisolated deinit`.
    private nonisolated(unsafe) var audioPlayer: AVAudioPlayer?
    private var muteIntervals: [(start: TimeInterval, end: TimeInterval)] = []
    private var mode: MuteOverlayMode = .off
    private var assetID: String = "beep"
    private var isOverlayActive = false
    /// Suppresses boundary handling while seek resync runs (avoids double stop/start).
    private var isSeekResyncing = false
    private let matchEpsilon: TimeInterval = 0.05

    init(
        player: AVPlayer,
        eventRecorder: (any OverlayEventRecording)? = nil,
        assetBundle: Bundle = .main
    ) {
        self.player = player
        self.eventRecorder = eventRecorder
        self.assetBundle = assetBundle
    }

    nonisolated deinit {
        if let token = boundaryObserverToken {
            player.removeTimeObserver(token)
            boundaryObserverToken = nil
        }
        audioPlayer?.stop()
        audioPlayer = nil
    }

    /// Arm start/stop observers for mute intervals. Clears prior arms.
    /// `mode == .off` or empty intervals → no observers; stops any active overlay.
    func apply(
        muteIntervals: [(start: TimeInterval, end: TimeInterval)],
        mode: MuteOverlayMode
    ) {
        reset()

        self.muteIntervals = muteIntervals.sorted { $0.start < $1.start }
        self.mode = mode

        guard mode != .off, !self.muteIntervals.isEmpty else { return }
        guard let resourceName = mode.resourceName, let id = mode.assetID else { return }
        assetID = id

        guard prepareAudioPlayer(resourceName: resourceName) else { return }
        armBoundaryObservers()

        // If already inside a mute window (e.g. apply mid-playback), start immediately.
        let now = player.currentTime().seconds
        if let _ = containingInterval(at: now) {
            startOverlay(at: now)
        }
    }

    /// After seek completes: stop orphan overlay; start only if landed inside a mute window.
    ///
    /// Landing outside while still active emits one `overlayStop` so
    /// `activeOverlayCount` reaches 0 (AC5). If a boundary stop already ran
    /// during the seek, `isOverlayActive` is false and no second event is emitted.
    /// AC5 “no additional events” applies after this resync settles.
    func handleSeekCompleted(currentTime: TimeInterval) {
        isSeekResyncing = true
        defer { isSeekResyncing = false }

        // Disarm while we reconcile so residual boundary fires cannot race.
        removeBoundaryObserver()

        let landedInside = mode != .off && containingInterval(at: currentTime) != nil

        if isOverlayActive {
            if landedInside {
                // Still inside a mute window — keep playing; no event churn.
            } else {
                stopOverlay(at: currentTime, recordEvent: true)
            }
        } else if landedInside {
            startOverlay(at: currentTime)
        } else {
            audioPlayer?.pause()
        }

        if mode != .off, !muteIntervals.isEmpty {
            armBoundaryObservers()
        }
    }

    /// Tear down observers + stop playback.
    func reset() {
        removeBoundaryObserver()
        stopOverlay(at: player.currentTime().seconds, recordEvent: true)
        muteIntervals = []
        mode = .off
        audioPlayer?.stop()
        audioPlayer = nil
        isOverlayActive = false
        isSeekResyncing = false
    }

    // MARK: - Private

    private func prepareAudioPlayer(resourceName: String) -> Bool {
        guard let url = assetBundle.url(forResource: resourceName, withExtension: "wav")
            ?? assetBundle.url(forResource: resourceName, withExtension: "wav", subdirectory: "Fixtures/audio")
        else {
            return false
        }
        do {
            let prepared = try AVAudioPlayer(contentsOf: url)
            prepared.numberOfLoops = -1
            prepared.prepareToPlay()
            audioPlayer = prepared
            return true
        } catch {
            audioPlayer = nil
            return false
        }
    }

    private func armBoundaryObservers() {
        removeBoundaryObserver()

        var times: [NSValue] = []
        for interval in muteIntervals {
            times.append(NSValue(time: CMTime(seconds: interval.start, preferredTimescale: 600)))
            times.append(NSValue(time: CMTime(seconds: interval.end, preferredTimescale: 600)))
        }
        guard !times.isEmpty else { return }

        boundaryObserverToken = player.addBoundaryTimeObserver(
            forTimes: times,
            queue: .main
        ) { [weak self] in
            MainActor.assumeIsolated {
                self?.handleBoundaryFire()
            }
        }
    }

    private func removeBoundaryObserver() {
        if let token = boundaryObserverToken {
            player.removeTimeObserver(token)
            boundaryObserverToken = nil
        }
    }

    private func handleBoundaryFire() {
        guard !isSeekResyncing, mode != .off else { return }

        let t = player.currentTime().seconds

        if let start = matchingStart(at: t), !isOverlayActive {
            startOverlay(at: start)
            return
        }

        if matchingEnd(at: t) != nil, isOverlayActive {
            stopOverlay(at: t, recordEvent: true)
        }
    }

    private func startOverlay(at time: TimeInterval) {
        guard !isOverlayActive else { return }
        guard let audioPlayer else { return }

        // Snapshot episode transport before secondary AVAudioPlayer.play() — on
        // simulator the session handoff can park AVPlayer at rate 0 and stall the
        // playhead (OverlaySyncTests playhead-wait timeouts).
        let episodeWasPlaying =
            player.timeControlStatus == .playing || abs(player.rate) > 0.0001
        let resumeRate: Float = abs(player.rate) > 0.0001 ? player.rate : 1.0

        audioPlayer.currentTime = 0
        audioPlayer.play()
        isOverlayActive = true
        eventRecorder?.overlayStart(at: time, assetID: assetID)
        reassertEpisodePlaybackIfNeeded(wasPlaying: episodeWasPlaying, rate: resumeRate)
    }

    private func stopOverlay(at time: TimeInterval, recordEvent: Bool) {
        let episodeWasPlaying =
            player.timeControlStatus == .playing || abs(player.rate) > 0.0001
        let resumeRate: Float = abs(player.rate) > 0.0001 ? player.rate : 1.0

        guard isOverlayActive else {
            audioPlayer?.pause()
            return
        }
        audioPlayer?.pause()
        isOverlayActive = false
        if recordEvent {
            eventRecorder?.overlayStop(at: time)
        }
        reassertEpisodePlaybackIfNeeded(wasPlaying: episodeWasPlaying, rate: resumeRate)
    }

    /// Keep the episode AVPlayer advancing after overlay start/stop (ADR-017 secondary player).
    private func reassertEpisodePlaybackIfNeeded(wasPlaying: Bool, rate: Float) {
        guard wasPlaying else { return }
        guard player.timeControlStatus != .playing || abs(player.rate) < 0.0001 else { return }
        player.playImmediately(atRate: rate > 0.0001 ? rate : 1.0)
    }

    private func containingInterval(at time: TimeInterval) -> (start: TimeInterval, end: TimeInterval)? {
        muteIntervals.first { time >= $0.start - matchEpsilon && time < $0.end }
    }

    private func matchingStart(at time: TimeInterval) -> TimeInterval? {
        muteIntervals.first { abs(time - $0.start) <= matchEpsilon }?.start
    }

    private func matchingEnd(at time: TimeInterval) -> TimeInterval? {
        muteIntervals.first { abs(time - $0.end) <= matchEpsilon }?.end
    }
}
