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
    /// `nonisolated(unsafe)`: invalidated from `nonisolated deinit`.
    private nonisolated(unsafe) var silencePollTimer: Timer?
    private var muteIntervals: [(start: TimeInterval, end: TimeInterval)] = []
    private var mode: MuteOverlayMode = .off
    private var assetID: String = "beep"
    private var isOverlayActive = false
    /// Suppresses boundary handling while seek resync runs (avoids double stop/start).
    private var isSeekResyncing = false
    private let matchEpsilon: TimeInterval = 0.05
    /// Interval whose start event was last emitted (silence-poll stop pairing).
    private var activeSilenceInterval: (start: TimeInterval, end: TimeInterval)?

    /// Under XCTest / UITest / `PODWASH_SILENCE_HOST_AUDIO`, overlay volume is 0
    /// so verify emits no host-audible beeps (task-004 / task-018).
    private static let silenceOverlayForTests: Bool = HostAudioSilence.isEnabled

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
        silencePollTimer?.invalidate()
        silencePollTimer = nil
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
        armSilencePollingIfNeeded()

        // If already inside a mute window (e.g. apply mid-playback), start immediately.
        let now = player.currentTime().seconds
        if let interval = containingInterval(at: now) {
            startOverlay(at: interval.start, interval: interval)
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
        stopSilencePolling()

        let landedInside = mode != .off && containingInterval(at: currentTime) != nil

        if isOverlayActive {
            if landedInside {
                // Still inside a mute window — keep playing; no event churn.
            } else {
                stopOverlay(at: currentTime, recordEvent: true)
            }
        } else if landedInside, let interval = containingInterval(at: currentTime) {
            startOverlay(at: interval.start, interval: interval)
        } else {
            audioPlayer?.pause()
        }

        if mode != .off, !muteIntervals.isEmpty {
            armBoundaryObservers()
            armSilencePollingIfNeeded()
        }
    }

    /// Test seam: volume of the active overlay player (0 when silent under XCTest).
    var overlayPlayerVolumeForTesting: Float {
        audioPlayer?.volume ?? 0
    }

    /// Tear down observers + stop playback.
    func reset() {
        removeBoundaryObserver()
        stopSilencePolling()
        stopOverlay(at: player.currentTime().seconds, recordEvent: true)
        muteIntervals = []
        mode = .off
        audioPlayer?.stop()
        audioPlayer = nil
        isOverlayActive = false
        isSeekResyncing = false
        activeSilenceInterval = nil
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
            if Self.silenceOverlayForTests {
                prepared.volume = 0
            }
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
            // Hop via Task — assumeIsolated can SIGABRT under XCTest host pressure.
            Task { @MainActor [weak self] in
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

    /// Silence-host playhead pumps seek across mute edges without firing boundary
    /// observers — poll so overlay start/stop events still land on schedule times.
    private func armSilencePollingIfNeeded() {
        stopSilencePolling()
        guard Self.silenceOverlayForTests else { return }
        let timer = Timer(timeInterval: 0.02, repeats: true) { [weak self] _ in
            Task { @MainActor [weak self] in
                self?.pollSilenceOverlayState()
            }
        }
        RunLoop.main.add(timer, forMode: .common)
        silencePollTimer = timer
    }

    private func stopSilencePolling() {
        silencePollTimer?.invalidate()
        silencePollTimer = nil
    }

    private func pollSilenceOverlayState() {
        guard !isSeekResyncing, mode != .off else { return }
        let t = player.currentTime().seconds
        guard t.isFinite else { return }

        if let interval = containingInterval(at: t) {
            if !isOverlayActive {
                startOverlay(at: interval.start, interval: interval)
            }
            return
        }

        if isOverlayActive {
            let stopAt = activeSilenceInterval?.end ?? t
            stopOverlay(at: stopAt, recordEvent: true)
        }
    }

    private func handleBoundaryFire() {
        guard !isSeekResyncing, mode != .off else { return }

        let t = player.currentTime().seconds

        if let start = matchingStart(at: t), !isOverlayActive {
            let interval = muteIntervals.first { abs($0.start - start) <= matchEpsilon }
            startOverlay(at: start, interval: interval)
            return
        }

        if let end = matchingEnd(at: t), isOverlayActive {
            stopOverlay(at: end, recordEvent: true)
        }
    }

    private func startOverlay(
        at time: TimeInterval,
        interval: (start: TimeInterval, end: TimeInterval)? = nil
    ) {
        guard !isOverlayActive else { return }
        guard let audioPlayer else { return }

        // Snapshot episode transport before secondary AVAudioPlayer.play() — on
        // simulator the session handoff can park AVPlayer at rate 0 and stall the
        // playhead (OverlaySyncTests playhead-wait timeouts).
        let episodeWasPlaying =
            player.timeControlStatus == .playing || abs(player.rate) > 0.0001
        let resumeRate: Float = abs(player.rate) > 0.0001 ? player.rate : 1.0

        audioPlayer.currentTime = 0
        if Self.silenceOverlayForTests {
            audioPlayer.volume = 0
            // Do not call play() under host silence — secondary AVAudioPlayer
            // steals the session and freezes the muted episode clock.
        } else {
            audioPlayer.play()
        }
        isOverlayActive = true
        activeSilenceInterval = interval
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
        activeSilenceInterval = nil
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
        if abs(player.rate) < 0.0001 {
            player.rate = rate > 0.0001 ? rate : 1.0
        }
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
