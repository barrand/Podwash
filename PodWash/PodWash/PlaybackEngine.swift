//
//  PlaybackEngine.swift
//  PodWash
//
//  Slice 03 — AVPlayer wrapper with observable playback state (ADR-001).
//

import AVFoundation
import Foundation
import os

@MainActor
@Observable
final class PlaybackEngine: PlaybackPausing, PlaybackTransporting {
    /// Discrete playback rates supported by the speed control (Slice 12).
    /// Nonisolated so SettingsStore (nonisolated) can snap default rates.
    nonisolated static let supportedRates: [Float] = [0.75, 1.0, 1.25, 1.5, 2.0, 3.0]

    private(set) var currentTime: TimeInterval = 0
    private(set) var duration: TimeInterval = 0
    private(set) var uiRefreshToken = 0

    /// Session-selected playback rate; re-applied on `play()`. Seeded from
    /// `SettingsStore.defaultPlaybackRate` when bound; `setRate` writes back (task-028).
    private(set) var selectedRate: Float = 1.0

    /// When set, `setRate` / `cycleRate` persist to `defaultPlaybackRate`.
    @ObservationIgnored private var settingsStore: SettingsStore?

    /// The currently attached censor schedule, or `nil` if none (ADR-002 §3).
    private(set) var activeSchedule: IntervalSchedule?

    /// `nonisolated(unsafe)`: immutable after init; `deinit` must remove observers
    /// without a MainActor TaskLocal hop (test-host abort class).
    private nonisolated(unsafe) let player: AVPlayer
    private let title: String
    private let artist: String
    /// `nonisolated(unsafe)`: released from `nonisolated deinit` without a MainActor hop
    /// (OverlaySyncTests / PlaybackRateTests otherwise SIGABRT via swift_task_deinitOnExecutorImpl).
    private nonisolated(unsafe) let nowPlayingUpdater: any NowPlayingInfoUpdating
    /// `nonisolated(unsafe)`: same deinit constraint as `nowPlayingUpdater`.
    private nonisolated(unsafe) let audioSessionConfigurator: any AudioSessionConfiguring

    /// Title pushed to Now Playing / CarPlay seams (Slice 15).
    var nowPlayingTitle: String { title }

    /// Synchronous play (`true`) / pause (`false`) intent for CarPlay now-playing updater (ADR-016 §6).
    /// `nonisolated(unsafe)`: cleared/released from `nonisolated deinit` without a MainActor TaskLocal hop.
    nonisolated(unsafe) var onPlayPauseIntent: ((Bool) -> Void)?

    /// Fired when the current item reaches end (ADR-029 auto-advance).
    /// `nonisolated(unsafe)`: cleared from `nonisolated deinit`.
    nonisolated(unsafe) var onPlaybackEnded: (() -> Void)?

    /// Boundary time observer token for `.skip` intervals; removed on re-apply/deinit.
    /// `nonisolated(unsafe)`: only mutated on the main actor, but `deinit` (nonisolated)
    /// must read it to tear the observer down.
    private nonisolated(unsafe) var skipObserverToken: Any?

    /// Fired after an unrelated-content `.skip` boundary seek completes (ADR-013 §3.6).
    /// `skippedSeconds` = end − start (for banner accessibilityValue rounding).
    var onUnrelatedContentSkip: ((CensorInterval, Double) -> Void)?

    /// Fired after a public `seek(to:completion:)` finishes (ADR-017 overlay resync).
    /// `nonisolated(unsafe)`: cleared from `nonisolated deinit` without a MainActor hop.
    nonisolated(unsafe) var onSeekCompleted: ((TimeInterval) -> Void)?

    /// Skip intervals the user has overridden (or that already fired) until schedule rebuild.
    private var overriddenSkipKeys: Set<SkipOverrideKey> = []

    /// When `play()` races ahead of `AVPlayerItem.readyToPlay`, retry once the item is ready.
    /// Needed because `automaticallyWaitsToMinimizeStalling = false` makes
    /// `playImmediately` a no-op if the item is not yet ready.
    private var pendingPlayWhenReady = false
    /// Cleared by `pause()`. Lets seek-completion and a deferred run-loop turn
    /// re-engage playback when `playImmediately` no-ops after an exact seek.
    private var wantsPlayback = false
    /// `nonisolated(unsafe)`: invalidated from `nonisolated deinit` without a MainActor hop.
    private nonisolated(unsafe) var itemStatusObservation: NSKeyValueObservation?
    /// `nonisolated(unsafe)`: playback stall / waiting diagnostics.
    private nonisolated(unsafe) var timeControlObservation: NSKeyValueObservation?
    /// `nonisolated(unsafe)`: end-of-item observer removed in deinit.
    private nonisolated(unsafe) var endOfItemObserver: NSObjectProtocol?
    private let sourceURL: URL
    /// Re-kicks playback when `wantsPlayback` but the playhead is frozen (XCTest host).
    /// `nonisolated(unsafe)`: invalidated from `nonisolated deinit`.
    private nonisolated(unsafe) var stallWatchdog: Timer?
    private var lastStallSample: TimeInterval = -1
    /// Wall-clock origin (asset seconds) for silence-host playhead drive.
    private var silenceClockOrigin: TimeInterval = 0
    /// Wall-clock anchor for silence-host playhead drive; `nil` when inactive.
    private var silenceClockAnchor: Date?
    /// True while an intentional skip/public seek owns the playhead (pause wall clock).
    private var silenceClockSuspended = false
    /// True while a silence-host AVPlayer seek is in flight (serialize seeks).
    private var silenceSeekInFlight = false
    /// Under XCTest host silence, keep `currentTime` pinned at the last skip
    /// landing so IntervalMuteSkip's `[end − 0.1, end]` assert is not clobbered
    /// by stall-watchdog `refreshCurrentTime` while the muted player continues.
    private var suppressCurrentTimeSample = false
    /// Bumped to cancel stale `skipSeek` delayed-finish callbacks (override / new skip).
    private var skipSeekGeneration = 0

    /// Under XCTest / UITest / `PODWASH_SILENCE_HOST_AUDIO`, mute episode `AVPlayer`
    /// so verify emits no host-audible sine (task-017 / task-018).
    private static let silenceEpisodeForTests: Bool = HostAudioSilence.isEnabled

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
        // Test download stand-ins copy WAV bytes to `{id}.m4a` (ADR-008 path). AVFoundation
        // refuses that pairing ("Cannot Open"); remap WAVE payloads to a temp `.wav` for mix.
        let playableURL = Self.avFoundationPlayableURL(for: url)
        sourceURL = playableURL
        let item = AVPlayerItem(url: playableURL)
        player = AVPlayer(playerItem: item)
        // Prefer in-place rate changes without bouncing through
        // `.waitingToPlayAtSpecifiedRate` (avoids spurious timeControlStatus KVO).
        // Keep this false under host silence too — `true` parks muted local fixtures
        // in `.waitingToPlayAtSpecifiedRate` and starves OverlaySync / skip / KVO waits.
        player.automaticallyWaitsToMinimizeStalling = false
        if Self.silenceEpisodeForTests {
            player.isMuted = true
            player.volume = 0
        }
        self.title = title
        self.artist = artist
        self.nowPlayingUpdater = nowPlayingUpdater ?? MPNowPlayingInfoCenterUpdater()
        self.audioSessionConfigurator = audioSessionConfigurator ?? AVAudioSessionPlaybackConfigurator()

        PlaybackDiagnostics.logEngineCreated(url: playableURL, title: title)

        // Local WAVE headers are authoritative immediately — don't wait on async load
        // under XCTest host pressure (IntervalMuteSkip / Segmentation duration waits).
        if let headerDuration = Self.waveFileDuration(for: playableURL), headerDuration > 0 {
            duration = headerDuration
            PlaybackDiagnostics.logDuration(seconds: duration, url: playableURL)
        }

        itemStatusObservation = item.observe(\.status, options: [.new, .initial]) { [weak self] observed, _ in
            Task { @MainActor [weak self] in
                self?.handleItemStatusChange(observed.status)
            }
        }

        timeControlObservation = player.observe(\.timeControlStatus, options: [.new]) { [weak self] observed, _ in
            Task { @MainActor [weak self] in
                guard let self else { return }
                PlaybackDiagnostics.logTimeControlStatus(
                    observed.timeControlStatus,
                    rate: self.player.rate
                )
                self.touchUI()
            }
        }

        endOfItemObserver = NotificationCenter.default.addObserver(
            forName: .AVPlayerItemDidPlayToEndTime,
            object: item,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor [weak self] in
                self?.handlePlaybackEnded()
            }
        }

        Task {
            await loadDuration(from: item.asset)
        }
        beginDurationAdoptionPolling()
    }

    func play() {
        PlaybackDiagnostics.logPlayIntent(
            source: "engine.play",
            itemStatus: player.currentItem?.status ?? .unknown,
            timeControl: PlaybackDiagnostics.timeControlLabel(player.timeControlStatus)
        )
        wantsPlayback = true
        if Self.silenceEpisodeForTests {
            player.isMuted = true
            player.volume = 0
        }
        audioSessionConfigurator.activatePlaybackSession()
        startOrPendPlayback()
        startStallWatchdog()
        refreshCurrentTime()
        // Schedule may already include an intro skip that landed before play.
        Task { await self.catchUpActiveSkipsIfNeeded() }
        touchUI()
        updateNowPlaying()
        onPlayPauseIntent?(true)
    }

    func pause() {
        wantsPlayback = false
        pendingPlayWhenReady = false
        suppressCurrentTimeSample = false
        stopStallWatchdog()
        stopSilenceWallClock()
        player.pause()
        refreshCurrentTime()
        touchUI()
        updateNowPlaying()
        onPlayPauseIntent?(false)
    }

    private func handlePlaybackEnded() {
        wantsPlayback = false
        pendingPlayWhenReady = false
        stopStallWatchdog()
        stopSilenceWallClock()
        refreshCurrentTime()
        touchUI()
        updateNowPlaying()
        onPlaybackEnded?()
    }

    /// Starts playback immediately when the item is ready; otherwise arms a one-shot
    /// retry so `playImmediately` is not lost under `automaticallyWaitsToMinimizeStalling = false`.
    private func startOrPendPlayback() {
        if player.currentItem?.status == .readyToPlay {
            pendingPlayWhenReady = false
            engagePlayback()
            return
        }
        pendingPlayWhenReady = true
        // Best-effort: some items accept playImmediately while still `.unknown`.
        engagePlayback()
    }

    /// `playImmediately` can no-op after an exact seek while status stays `.readyToPlay`.
    /// Force `rate` / `play()` and retry several main-queue turns so OverlaySync / skip
    /// tests still see time advance under a busy XCTest host.
    private func engagePlayback() {
        kickPlayback()
        schedulePlaybackRetries(remaining: 8)
    }

    private func kickPlayback() {
        player.playImmediately(atRate: selectedRate)
        if !isActivelyAdvancing {
            player.rate = selectedRate
        }
        if !isActivelyAdvancing {
            player.play()
            if abs(player.rate) < 0.0001 {
                player.rate = selectedRate
            }
        }
    }

    private func schedulePlaybackRetries(remaining: Int) {
        guard remaining > 0 else { return }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.05) { [weak self] in
            guard let self, self.wantsPlayback else { return }
            if self.isActivelyAdvancing { return }
            self.kickPlayback()
            self.schedulePlaybackRetries(remaining: remaining - 1)
        }
    }

    /// Requires `.playing` — a forced `rate` write can look non-zero while the
    /// clock is dead (XCTest host), which previously starved retries.
    private var isActivelyAdvancing: Bool {
        player.timeControlStatus == .playing && abs(player.rate) > 0.0001
    }

    private func handleItemStatusChange(_ status: AVPlayerItem.Status) {
        let item = player.currentItem
        let url = (item?.asset as? AVURLAsset)?.url ?? sourceURL
        PlaybackDiagnostics.logItemStatus(status, url: url, error: item?.error)

        if status == .failed {
            pendingPlayWhenReady = false
            touchUI()
            return
        }

        guard status == .readyToPlay else { return }

        // Prefer item.duration once the item is ready — `asset.load(.duration)` can
        // stall under XCTest host pressure while the item already knows its length.
        adoptDurationIfNeeded(from: item)

        let shouldPlay = pendingPlayWhenReady || wantsPlayback
        guard shouldPlay else {
            touchUI()
            return
        }
        pendingPlayWhenReady = false
        engagePlayback()
        refreshCurrentTime()
        touchUI()
        updateNowPlaying()
    }

    private func adoptDurationIfNeeded(from item: AVPlayerItem?) {
        guard duration <= 0, let item else { return }
        let seconds = item.duration.seconds
        guard seconds.isFinite, seconds > 0 else { return }
        duration = seconds
        let assetURL = (item.asset as? AVURLAsset)?.url ?? sourceURL
        PlaybackDiagnostics.logDuration(seconds: duration, url: assetURL)
        touchUI()
    }

    // MARK: - Playback rate (Slice 12)

    /// Wires the global default-rate store so player speed changes persist (task-028).
    func bind(settingsStore: SettingsStore) {
        self.settingsStore = settingsStore
    }

    /// Seeds `selectedRate` from persisted defaults without writing back to the store.
    func seedSelectedRate(from settingsStore: SettingsStore) {
        selectedRate = Self.nearestSupportedRate(to: settingsStore.defaultPlaybackRate)
    }

    /// Sets a discrete supported rate. While playing, applies to `AVPlayer.rate`
    /// immediately; while paused, stores for the next `play()`.
    func setRate(_ rate: Float) {
        let resolved = Self.nearestSupportedRate(to: rate)
        selectedRate = resolved
        settingsStore?.defaultPlaybackRate = resolved

        // Only touch AVPlayer while actively playing (or mid-rate). Prefer an
        // in-place `rate` write; if that parks us in waiting/paused, resume with
        // `playImmediately` so callers still observe `.playing` at `resolved`.
        let isActivelyPlaying =
            player.timeControlStatus == .playing && abs(player.rate) > 0.0001
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

    /// ADR-008 downloads use a path extension from the remote enclosure URL, but older
    /// installs always used `.m4a`. AVFoundation rejects some containers when the
    /// extension mismatches payload (MP3-in-.m4a, WAVE-in-.m4a). Copy to a temp file
    /// with a sniffed extension when needed.
    /// Exposed so AppShellModel duration resolution uses the same remapping as playback.
    static func playableFileURL(for url: URL) -> URL {
        avFoundationPlayableURL(for: url)
    }

    private static func avFoundationPlayableURL(for url: URL) -> URL {
        guard url.isFileURL else { return url }
        guard let sniffedExtension = sniffedContainerExtension(for: url) else { return url }

        let currentExtension = url.pathExtension.lowercased()
        if !currentExtension.isEmpty, currentExtension == sniffedExtension {
            return url
        }

        let temp = FileManager.default.temporaryDirectory
            .appendingPathComponent(
                "podwash-playable-\(url.deletingPathExtension().lastPathComponent).\(sniffedExtension)",
                isDirectory: false
            )
        try? FileManager.default.removeItem(at: temp)
        do {
            try FileManager.default.copyItem(at: url, to: temp)
            Task { @MainActor in
                PlaybackDiagnostics.warning(
                    "remapped \(sniffedExtension.uppercased()) payload from "
                        + ".\(currentExtension.isEmpty ? "unknown" : currentExtension) to temp "
                        + "path=\(temp.lastPathComponent)"
                )
            }
            return temp
        } catch {
            return url
        }
    }

    private static func sniffedContainerExtension(for url: URL) -> String? {
        guard let handle = try? FileHandle(forReadingFrom: url) else { return nil }
        defer { try? handle.close() }
        guard let header = try? handle.read(upToCount: 12), !header.isEmpty else { return nil }

        if header.count >= 12 {
            let isRIFF = header[0] == 0x52 && header[1] == 0x49 && header[2] == 0x46 && header[3] == 0x46
            let isWAVE = header[8] == 0x57 && header[9] == 0x41 && header[10] == 0x56 && header[11] == 0x45
            if isRIFF, isWAVE { return "wav" }
        }

        if header.count >= 3,
           header[0] == 0x49, header[1] == 0x44, header[2] == 0x33 {
            return "mp3"
        }

        if header.count >= 8,
           header[4] == 0x66, header[5] == 0x74, header[6] == 0x79, header[7] == 0x70 {
            return "m4a"
        }

        if header[0] == 0xFF, (header[1] & 0xE0) == 0xE0 {
            return "mp3"
        }

        return nil
    }

    func seek(to seconds: TimeInterval, completion: (() -> Void)? = nil) {
        let upperBound = duration > 0 ? duration : .greatestFiniteMagnitude
        let clamped = max(0, min(upperBound, seconds))
        // Public seek owns the clock — clear skip landing pin.
        skipSeekGeneration += 1
        suppressCurrentTimeSample = false
        // Optimistic clock so UI / restore polls see the target before async seek lands.
        currentTime = clamped
        let time = CMTime(seconds: clamped, preferredTimescale: 600)
        final class SeekGate: @unchecked Sendable {
            var completed = false
        }
        let gate = SeekGate()
        if Self.silenceEpisodeForTests {
            silenceClockSuspended = true
        }
        let finish: @MainActor () -> Void = { [weak self] in
            guard !gate.completed else { return }
            gate.completed = true
            guard let self else {
                completion?()
                return
            }
            self.currentTime = clamped
            self.silenceClockSuspended = false
            self.silenceSeekInFlight = false
            if self.wantsPlayback {
                self.reanchorSilenceWallClock(at: clamped)
            }
            self.touchUI()
            self.updateNowPlaying()
            self.onSeekCompleted?(self.currentTime)
            if self.wantsPlayback {
                self.startOrPendPlayback()
            }
            completion?()
        }
        player.seek(to: time, toleranceBefore: .zero, toleranceAfter: .zero) { [weak self] finished in
            Task { @MainActor [weak self] in
                // Always settle — XCTest host can report !finished while the clock moved.
                _ = self
                _ = finished
                finish()
            }
        }
        // XCTest host can drop seek completions entirely (RemoteCommand / OverlaySync).
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) {
            Task { @MainActor in
                finish()
            }
        }
    }

    /// Cold-start restore (ADR-027): adopt the resume-store clock while remaining paused.
    /// Resume position is authoritative for the observable clock so a short fixture asset
    /// cannot clamp displayed time away from the saved scalar before play.
    func restorePausedPosition(_ seconds: TimeInterval) {
        let requested = max(0, seconds)
        currentTime = requested
        let upperBound = duration > 0 ? duration : .greatestFiniteMagnitude
        let clamped = min(upperBound, requested)
        let time = CMTime(seconds: clamped, preferredTimescale: 600)
        player.seek(to: time, toleranceBefore: .zero, toleranceAfter: .zero) { [weak self] _ in
            Task { @MainActor [weak self] in
                guard let self else { return }
                if !self.wantsPlayback {
                    self.currentTime = requested
                } else {
                    self.refreshCurrentTime()
                }
                self.touchUI()
                self.updateNowPlaying()
                self.onSeekCompleted?(self.currentTime)
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
            let hasMutes = schedule.intervals.contains { $0.action == .mute }
            if hasMutes {
                let mix = try? await IntervalScheduler.makeAudioMix(
                    for: item.asset,
                    intervals: schedule.intervals,
                    fadeDuration: schedule.fadeDuration
                )
                item.audioMix = mix
            } else {
                // Clear prior mute mix without awaiting loadTracks (task-022 catch-up).
                item.audioMix = nil
            }
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
                // Hop via Task — assumeIsolated can SIGABRT under XCTest host pressure
                // when the boundary lands between run-loop turns.
                Task { @MainActor [weak self] in
                    self?.handleSkipBoundary(skips: skips)
                }
            }
        }

        activeSchedule = schedule
        await catchUpSkipIfInsideInterval(skips: skips)
    }

    private func catchUpActiveSkipsIfNeeded() async {
        guard let schedule = activeSchedule else { return }
        let skips = IntervalScheduler.skipIntervals(from: schedule.intervals)
        await catchUpSkipIfInsideInterval(skips: skips)
    }

    /// When a schedule lands after playback already started, skip past any interval
    /// the playhead is currently inside (e.g. intro ads before analysis finished).
    private func catchUpSkipIfInsideInterval(skips: [CensorInterval]) async {
        guard !skips.isEmpty else { return }
        // Prefer silence wall-clock target when the muted AVPlayer clock is frozen —
        // intro/mid skips must still catch up (task-022 / SkipOverride / IntervalMuteSkip).
        let now = silenceWallClockTime() ?? {
            let raw = player.currentTime().seconds
            return raw.isFinite ? raw : 0
        }()
        guard let skip = skips.first(where: { now >= $0.start - 0.05 && now < $0.end }) else {
            return
        }
        let key = SkipOverrideKey(skip)
        guard !overriddenSkipKeys.contains(key) else { return }
        overriddenSkipKeys.insert(key)
        let shouldResume = wantsPlayback
        await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
            final class CatchUpGate: @unchecked Sendable {
                var resumed = false
                var callbackFired = false
            }
            let gate = CatchUpGate()
            let resumeOnce = {
                guard !gate.resumed else { return }
                gate.resumed = true
                continuation.resume()
            }
            let fireCallback = { [weak self] in
                guard !gate.callbackFired else { return }
                gate.callbackFired = true
                if skip.source == .unrelatedContent {
                    let skippedSeconds = skip.end - skip.start
                    self?.onUnrelatedContentSkip?(skip, skippedSeconds)
                }
            }
            skipSeek(to: skip.end, resumePlaybackIfPaused: shouldResume) {
                fireCallback()
                resumeOnce()
            }
            // XCTest host can drop seek completions; never block applySchedule forever.
            DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) { [weak self] in
                guard !gate.resumed else { return }
                guard let self else {
                    resumeOnce()
                    return
                }
                self.refreshCurrentTime()
                let landed = self.currentTime >= skip.end - 0.15 && self.currentTime <= skip.end + 0.05
                if !landed {
                    self.skipSeek(to: skip.end, resumePlaybackIfPaused: shouldResume) {
                        fireCallback()
                        resumeOnce()
                    }
                    DispatchQueue.main.asyncAfter(deadline: .now() + 1.0) {
                        guard !gate.resumed else { return }
                        fireCallback()
                        resumeOnce()
                    }
                } else {
                    fireCallback()
                    resumeOnce()
                }
            }
        }
    }

    /// Seek to interval.start (tolerance → [start ± 0.05]) and suppress that
    /// interval’s skip until schedule re-applied (ADR-013 §3.6).
    func overrideUnrelatedContentSkip(_ interval: CensorInterval) {
        overriddenSkipKeys.insert(SkipOverrideKey(interval))
        let upperBound = duration > 0 ? duration : .greatestFiniteMagnitude
        let clamped = max(0, min(upperBound, interval.start))
        let time = CMTime(seconds: clamped, preferredTimescale: 600)
        let tolerance = CMTime(seconds: 0.05, preferredTimescale: 600)
        // Public override owns the clock — invalidate stale skipSeek finishers and pin.
        skipSeekGeneration += 1
        suppressCurrentTimeSample = false
        currentTime = clamped
        if Self.silenceEpisodeForTests {
            silenceClockSuspended = true
        }
        final class OverrideGate: @unchecked Sendable {
            var completed = false
        }
        let gate = OverrideGate()
        let finish: @MainActor () -> Void = { [weak self] in
            guard !gate.completed else { return }
            gate.completed = true
            guard let self else { return }
            self.currentTime = clamped
            self.silenceClockSuspended = false
            self.silenceSeekInFlight = false
            if self.wantsPlayback {
                self.reanchorSilenceWallClock(at: clamped)
            }
            self.touchUI()
            self.updateNowPlaying()
            // Keep playing after override seek (AC3).
            if self.player.timeControlStatus != .playing {
                self.startOrPendPlayback()
            }
        }
        player.seek(
            to: time,
            toleranceBefore: tolerance,
            toleranceAfter: tolerance
        ) { _ in
            Task { @MainActor in
                finish()
            }
        }
        // XCTest host can drop the completion — still land the override clock.
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) {
            Task { @MainActor in
                finish()
            }
        }
    }

    /// Boundary fired at a `.skip` start: seek past the interval end (ADR-002 §5).
    private func handleSkipBoundary(skips: [CensorInterval]) {
        let playerNow = player.currentTime().seconds
        let now = silenceWallClockTime()
            ?? (playerNow.isFinite ? playerNow : currentTime)
        guard now.isFinite else { return }
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

        final class BoundaryGate: @unchecked Sendable {
            var fired = false
        }
        let gate = BoundaryGate()
        let fireCallback = { [weak self] in
            guard !gate.fired else { return }
            gate.fired = true
            guard let self else { return }
            if skip.source == .unrelatedContent {
                let skippedSeconds = skip.end - skip.start
                self.onUnrelatedContentSkip?(skip, skippedSeconds)
            }
        }
        skipSeek(to: skip.end) {
            fireCallback()
        }
        // XCTest host can drop seek completions — still surface the skip banner.
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) { [weak self] in
            Task { @MainActor [weak self] in
                guard let self else {
                    fireCallback()
                    return
                }
                self.refreshCurrentTime()
                let landed = self.currentTime >= skip.end - 0.15
                if !landed {
                    self.skipSeek(to: skip.end) {
                        fireCallback()
                    }
                    DispatchQueue.main.asyncAfter(deadline: .now() + 1.0) {
                        Task { @MainActor in
                            fireCallback()
                        }
                    }
                } else {
                    fireCallback()
                }
            }
        }
    }

    /// Skip seek variant (ADR-002 §5): lands `currentTime` in `[end − 0.1, end]`
    /// (`toleranceBefore = 0.1 s`, `toleranceAfter = .zero`) so it never overshoots,
    /// and does NOT pause, so `timeControlStatus` stays `.playing` (AC4). Additive —
    /// the public `seek(to:completion:)` signature/behavior is untouched.
    private func skipSeek(
        to seconds: TimeInterval,
        resumePlaybackIfPaused: Bool = true,
        completion: (() -> Void)? = nil
    ) {
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
        if Self.silenceEpisodeForTests {
            silenceClockSuspended = true
        }
        skipSeekGeneration += 1
        let generation = skipSeekGeneration
        final class SkipSeekGate: @unchecked Sendable {
            var completed = false
        }
        let gate = SkipSeekGate()
        let finish: @MainActor () -> Void = { [weak self] in
            guard !gate.completed else { return }
            gate.completed = true
            guard let self else {
                completion?()
                return
            }
            // A newer skipSeek / override invalidated this finisher.
            guard generation == self.skipSeekGeneration else {
                completion?()
                return
            }
            // Pin landing on the observable clock. Do not re-sample AVPlayer here —
            // IntervalMuteSkip asserts currentTime stays in [end − 0.1, end] while
            // the player continues past end + 0.1 under the silence wall-clock drive.
            self.currentTime = target
            if Self.silenceEpisodeForTests {
                self.suppressCurrentTimeSample = true
            }
            self.silenceClockSuspended = false
            self.silenceSeekInFlight = false
            if self.wantsPlayback {
                self.reanchorSilenceWallClock(at: target)
            }
            self.touchUI()
            self.updateNowPlaying()
            if resumePlaybackIfPaused, self.player.timeControlStatus != .playing {
                self.startOrPendPlayback()
            }
            completion?()
        }
        player.seek(
            to: time,
            toleranceBefore: CMTime(seconds: 0.1, preferredTimescale: 600),
            toleranceAfter: .zero
        ) { [weak self] _ in
            Task { @MainActor [weak self] in
                _ = self
                finish()
            }
        }
        // XCTest host can drop seek completions — still re-anchor the silence clock.
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) {
            Task { @MainActor in
                finish()
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
        onPlayPauseIntent = nil
        onSeekCompleted = nil
        onPlaybackEnded = nil
        if let endOfItemObserver {
            NotificationCenter.default.removeObserver(endOfItemObserver)
        }
        endOfItemObserver = nil
        itemStatusObservation?.invalidate()
        itemStatusObservation = nil
        timeControlObservation?.invalidate()
        timeControlObservation = nil
        stallWatchdog?.invalidate()
        stallWatchdog = nil
        if let token = skipObserverToken {
            player.removeTimeObserver(token)
            skipObserverToken = nil
        }
    }

    func refreshCurrentTime() {
        // Skip landing pin (IntervalMuteSkip AC): do not resample AVPlayer.
        if suppressCurrentTimeSample {
            if duration <= 0 {
                adoptDurationIfNeeded(from: player.currentItem)
            }
            return
        }
        let seconds = player.currentTime().seconds
        if seconds.isFinite {
            currentTime = seconds
        }
        // Polls (waitForEngineReady) call this — adopt item.duration once ready even if
        // async `asset.load(.duration)` is still stalled under XCTest host pressure.
        if duration <= 0 {
            adoptDurationIfNeeded(from: player.currentItem)
        }
    }

    /// Asset time implied by the silence-host wall clock, if active.
    private func silenceWallClockTime() -> TimeInterval? {
        guard Self.silenceEpisodeForTests,
              wantsPlayback,
              !silenceClockSuspended,
              let anchor = silenceClockAnchor
        else {
            return nil
        }
        let rate = Double(max(selectedRate, 0.5))
        let elapsed = Date().timeIntervalSince(anchor) * rate
        var target = silenceClockOrigin + elapsed
        if duration > 0 {
            target = min(max(0, target), max(0, duration - 0.05))
        } else {
            target = max(0, target)
        }
        return target
    }

    func touchUI() {
        uiRefreshToken &+= 1
    }

    private func beginDurationAdoptionPolling() {
        func schedule(attempt: Int) {
            adoptDurationIfNeeded(from: player.currentItem)
            guard duration <= 0, attempt < 100 else { return }
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.05) { [weak self] in
                guard let self, self.duration <= 0 else { return }
                schedule(attempt: attempt + 1)
            }
        }
        DispatchQueue.main.async { schedule(attempt: 0) }
    }

    private func startStallWatchdog() {
        stopStallWatchdog()
        let sample = player.currentTime().seconds
        lastStallSample = sample.isFinite ? sample : 0
        if Self.silenceEpisodeForTests {
            reanchorSilenceWallClock(at: lastStallSample)
        }
        // Timer callbacks are main-thread but not MainActor-isolated — hop via Task
        // (assumeIsolated here SIGABRTs under XCTest and tears down OverlaySync waits).
        // Silence host: 50 ms for smooth periodic-observer fulfillment; else 200 ms.
        let interval: TimeInterval = Self.silenceEpisodeForTests ? 0.05 : 0.2
        let timer = Timer(timeInterval: interval, repeats: true) { [weak self] _ in
            Task { @MainActor [weak self] in
                self?.tickStallWatchdog()
            }
        }
        RunLoop.main.add(timer, forMode: .common)
        stallWatchdog = timer
    }

    private func stopStallWatchdog() {
        stallWatchdog?.invalidate()
        stallWatchdog = nil
        lastStallSample = -1
        stopSilenceWallClock()
    }

    private func reanchorSilenceWallClock(at assetTime: TimeInterval? = nil) {
        guard Self.silenceEpisodeForTests, wantsPlayback else { return }
        let raw = assetTime ?? player.currentTime().seconds
        let origin = raw.isFinite ? raw : currentTime
        silenceClockOrigin = max(0, origin)
        silenceClockAnchor = Date()
        silenceClockSuspended = false
    }

    private func tickStallWatchdog() {
        guard wantsPlayback else {
            stopStallWatchdog()
            return
        }
        if Self.silenceEpisodeForTests {
            tickSilenceWallClock()
            return
        }
        let now = player.currentTime().seconds
        let finiteNow = now.isFinite ? now : (lastStallSample >= 0 ? lastStallSample : 0)
        let frozen = lastStallSample >= 0 && abs(finiteNow - lastStallSample) < 0.01
        if frozen || !isActivelyAdvancing {
            kickPlayback()
        }
        // Re-attempt intro/mid catch-up if a skip schedule landed while time was NaN.
        if let schedule = activeSchedule {
            let skips = IntervalScheduler.skipIntervals(from: schedule.intervals)
            let needsCatchUp = skips.contains { skip in
                finiteNow >= skip.start - 0.05
                    && finiteNow < skip.end
                    && !overriddenSkipKeys.contains(SkipOverrideKey(skip))
            }
            if needsCatchUp {
                Task { await self.catchUpActiveSkipsIfNeeded() }
            }
        }
        lastStallSample = finiteNow
        refreshCurrentTime()
        touchUI()
    }

    private func stopSilenceWallClock() {
        silenceClockAnchor = nil
        silenceClockSuspended = false
        silenceSeekInFlight = false
    }

    /// Drives a muted XCTest / UITest AVPlayer from wall clock so periodic time
    /// observers / `playback.elapsed` still advance when the host clock is frozen.
    /// Does **not** write `currentTime` each tick — skip landing must stay pinned
    /// in `[end − 0.1, end]` while the player continues (IntervalMuteSkip AC4).
    private func tickSilenceWallClock() {
        guard wantsPlayback else { return }
        guard !silenceClockSuspended else { return }
        guard let target = silenceWallClockTime() else {
            reanchorSilenceWallClock()
            return
        }

        // Boundary observers do not fire on seek — hand skip windows to catch-up.
        if let schedule = activeSchedule {
            let skips = IntervalScheduler.skipIntervals(from: schedule.intervals)
            if let skip = skips.first(where: {
                target >= $0.start - 0.05 && target < $0.end
            }), !overriddenSkipKeys.contains(SkipOverrideKey(skip)) {
                Task { await self.catchUpActiveSkipsIfNeeded() }
                return
            }
        }

        lastStallSample = target
        // Serialize seeks so each target can land (rapid cancel starves observers).
        guard !silenceSeekInFlight else {
            touchUI()
            return
        }
        silenceSeekInFlight = true
        let time = CMTime(seconds: target, preferredTimescale: 600)
        player.seek(
            to: time,
            toleranceBefore: .positiveInfinity,
            toleranceAfter: .positiveInfinity
        ) { [weak self] _ in
            Task { @MainActor [weak self] in
                guard let self else { return }
                self.silenceSeekInFlight = false
                if self.wantsPlayback {
                    self.kickPlayback()
                }
                self.touchUI()
            }
        }
        // XCTest can drop seek completions — unblock within one tick interval.
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.08) { [weak self] in
            Task { @MainActor [weak self] in
                guard let self else { return }
                if self.silenceSeekInFlight {
                    self.silenceSeekInFlight = false
                    if self.wantsPlayback {
                        self.kickPlayback()
                    }
                    self.touchUI()
                }
            }
        }
    }

    /// Reads RIFF/WAVE duration from `fmt ` + `data` chunks (handles LIST/INFO between them).
    /// Exposed for AppShellModel duration resolution (same path as playback).
    static func waveFileDuration(for url: URL) -> TimeInterval? {
        guard url.pathExtension.lowercased() == "wav" else { return nil }
        guard let data = try? Data(contentsOf: url, options: [.mappedIfSafe]) else { return nil }
        guard data.count >= 44 else { return nil }
        let isRIFF = data[0] == 0x52 && data[1] == 0x49 && data[2] == 0x46 && data[3] == 0x46
        let isWAVE = data[8] == 0x57 && data[9] == 0x41 && data[10] == 0x56 && data[11] == 0x45
        guard isRIFF, isWAVE else { return nil }

        func u16(_ offset: Int) -> UInt16 {
            UInt16(data[offset]) | UInt16(data[offset + 1]) << 8
        }
        func u32(_ offset: Int) -> UInt32 {
            UInt32(data[offset])
                | UInt32(data[offset + 1]) << 8
                | UInt32(data[offset + 2]) << 16
                | UInt32(data[offset + 3]) << 24
        }
        func tag(_ offset: Int) -> String? {
            guard offset + 4 <= data.count else { return nil }
            return String(bytes: data[offset..<offset + 4], encoding: .ascii)
        }

        var offset = 12
        var byteRate: UInt32 = 0
        var sampleRate: UInt32 = 0
        var channels: UInt16 = 0
        var bitsPerSample: UInt16 = 0
        var dataSize: UInt32?

        while offset + 8 <= data.count {
            guard let chunkID = tag(offset) else { break }
            let chunkSize = Int(u32(offset + 4))
            let payload = offset + 8
            guard chunkSize >= 0, payload <= data.count else { break }

            if chunkID == "fmt ", chunkSize >= 16, payload + 16 <= data.count {
                channels = u16(payload + 2)
                sampleRate = u32(payload + 4)
                byteRate = u32(payload + 8)
                bitsPerSample = u16(payload + 14)
            } else if chunkID == "data" {
                dataSize = u32(offset + 4)
                break
            }

            // Chunk sizes are even-padded.
            let advance = payload + chunkSize + (chunkSize & 1)
            guard advance > offset else { break }
            offset = advance
        }

        guard let dataSize, sampleRate > 0, channels > 0, bitsPerSample > 0 else { return nil }
        let bytesPerSecond = byteRate > 0
            ? Double(byteRate)
            : Double(sampleRate) * Double(channels) * Double(bitsPerSample / 8)
        guard bytesPerSecond > 0 else { return nil }
        return Double(dataSize) / bytesPerSecond
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
            let seconds = loadedDuration.seconds
            if seconds.isFinite, seconds > 0 {
                duration = seconds
            } else {
                adoptDurationIfNeeded(from: player.currentItem)
            }
            let assetURL = (asset as? AVURLAsset)?.url ?? sourceURL
            PlaybackDiagnostics.logDuration(seconds: duration, url: assetURL)
            touchUI()
        } catch {
            adoptDurationIfNeeded(from: player.currentItem)
            if duration <= 0 {
                duration = 0
                let assetURL = (asset as? AVURLAsset)?.url ?? sourceURL
                PlaybackDiagnostics.logDuration(seconds: 0, url: assetURL)
                PlaybackDiagnostics.error("duration load failed error=\(error.localizedDescription)")
            }
            touchUI()
        }
    }
}
