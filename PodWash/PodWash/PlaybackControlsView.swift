//
//  PlaybackControlsView.swift
//  PodWash
//
//  Slice 03 — Minimal play/pause/seek UI (see slice-03-ux.md).
//  Slice 25 — Super seek bar + elapsed/remaining (slice-25-ux.md).
//  Slice 33 — Analysis progress chrome + timestamp ad bands (ADR-030).
//

import AVFoundation
import SwiftUI

struct PlaybackControlsView: View {
    @Bindable var engine: PlaybackEngine
    let readiness: AppShellModel.PlaybackReadiness
    /// When true, paint complete green + ad/mute overlays (ADR-030).
    let showsCompleteSeekBarPaint: Bool
    let episodeDuration: Double
    /// Applied / cached intervals for mute-marker + ad-band overlays (ADR-023 / ADR-030).
    let muteIntervals: [CensorInterval]
    let onTogglePlayPause: (() -> Void)?
    let onSeekTo: ((Double) -> Void)?
    let onSeekBy: ((Double) -> Void)?

    @State private var sleepClock = SystemMonotonicClock()

    /// The terminal seek-bar paint and transport must transition together. The
    /// preparation task may still be unwinding after the terminal snapshot has
    /// arrived, but that must not leave a completed episode showing a spinner.
    static func showsAnalysisIndicator(
        isPreparingPlayback: Bool,
        isPlaybackRequested: Bool,
        isSeekBarAnalysisComplete: Bool
    ) -> Bool {
        isPreparingPlayback && !isPlaybackRequested && !isSeekBarAnalysisComplete
    }

    init(
        engine: PlaybackEngine,
        readiness: AppShellModel.PlaybackReadiness = .ready,
        showsCompleteSeekBarPaint: Bool = false,
        episodeDuration: Double = 0,
        muteIntervals: [CensorInterval] = [],
        onTogglePlayPause: (() -> Void)? = nil,
        onSeekTo: ((Double) -> Void)? = nil,
        onSeekBy: ((Double) -> Void)? = nil
    ) {
        self.engine = engine
        self.readiness = readiness
        self.showsCompleteSeekBarPaint = showsCompleteSeekBarPaint
        self.episodeDuration = episodeDuration
        self.muteIntervals = muteIntervals
        self.onTogglePlayPause = onTogglePlayPause
        self.onSeekTo = onSeekTo
        self.onSeekBy = onSeekBy
    }

    @State private var sleepTimer: SleepTimer?
    /// Drives sleep-button accessibility; mirrors timer arm/cancel/fire.
    @State private var sleepAccessibilityValue = "off"

    var body: some View {
        TimelineView(.periodic(from: .now, by: 0.25)) { _ in
            let _ = engine.uiRefreshToken
            // AVPlayer may briefly report `.waitingToPlayAtSpecifiedRate` during
            // normal playback. Render transport intent rather than that volatile
            // status so the control cannot flash between Pause and Analyzing.
            let isPlaying = engine.isPlaybackRequested
            let elapsedSeconds = engine.avPlayer.currentTime().seconds
            let duration = episodeDuration > 0 ? episodeDuration : engine.duration
            let remainingSeconds = SuperSeekBarModel.remaining(
                elapsed: elapsedSeconds,
                duration: duration
            )
            let showCompletePaint = showsCompleteSeekBarPaint
            let adBands = showCompletePaint
                ? SuperSeekBarModel.adBands(from: muteIntervals, duration: duration)
                : []
            let muteMarkers = showCompletePaint
                ? SuperSeekBarModel.muteMarkers(from: muteIntervals, duration: duration)
                : []
            let muteMarkerCountForAccessibility: Int? = showCompletePaint
                ? muteMarkers.count
                : nil

            VStack(spacing: 24) {
                if readiness == .ready {
                    VStack(spacing: 4) {
                    SuperSeekBarView(
                        showsCompleteContentTrack: showCompletePaint,
                        adBands: adBands,
                        elapsed: elapsedSeconds,
                        duration: duration,
                        muteMarkers: muteMarkers,
                        muteMarkerCountForAccessibility: muteMarkerCountForAccessibility,
                        barHeight: AnalysisTimelineModel.fullPlayerTimelineHeight,
                        accessibilityIdentifier: "playback.superSeekBar",
                        onSeek: { seconds in
                            if let onSeekTo {
                                onSeekTo(seconds)
                            } else {
                                engine.seek(to: seconds)
                            }
                        }
                    )
                    .frame(maxWidth: .infinity)
                    }
                }

                HStack {
                    Text(formattedElapsed(elapsedSeconds))
                        .font(.system(.title2, design: .monospaced))
                        .accessibilityIdentifier("playback.elapsed")
                        .accessibilityLabel("Elapsed time")
                        .accessibilityValue(secondsAccessibilityValue(elapsedSeconds))

                    Spacer()

                    Text(formattedElapsed(remainingSeconds))
                        .font(.system(.title2, design: .monospaced))
                        .accessibilityIdentifier("playback.remaining")
                        .accessibilityLabel("Remaining time")
                        .accessibilityValue(secondsAccessibilityValue(remainingSeconds))
                }
                .opacity(readiness == .ready ? 1 : 0)
                .accessibilityHidden(readiness != .ready)

                if readiness == .ready {
                HStack(spacing: 32) {
                    Button(action: { seekBy(-15) }) {
                        Image(systemName: "gobackward.15")
                            .font(.title)
                    }
                    .accessibilityIdentifier("playback.seekBack15")
                    .accessibilityLabel("Seek back 15 seconds")

                    Button(action: togglePlayPause) {
                        Image(systemName: isPlaying ? "pause.circle.fill" : "play.circle.fill")
                            .font(.system(size: 56))
                            .foregroundStyle(BrandTheme.primary)
                    }
                    .accessibilityIdentifier("playback.playPause")
                    .accessibilityLabel(isPlaying ? "Pause" : "Play")
                    .accessibilityValue(isPlaying ? "playing" : "paused")

                    Button(action: { seekBy(15) }) {
                        Image(systemName: "goforward.15")
                            .font(.title)
                    }
                    .accessibilityIdentifier("playback.seekForward15")
                    .accessibilityLabel("Seek forward 15 seconds")
                }
                } else {
                    preparationStatus
                }
                // Brand accent sentinel (ADR-019 §4) — sibling of transport row; ids unchanged.
                Color.clear
                    .frame(width: 1, height: 1)
                    .accessibilityElement(children: .ignore)
                    .accessibilityIdentifier("themePrimaryAccent")
                    .accessibilityLabel("Brand primary accent")
                    .accessibilityValue("brandPrimary")
                    .allowsHitTesting(false)

                if readiness == .ready {
                HStack(spacing: 24) {
                    Button(action: { engine.cycleRate() }) {
                        Text(engine.rateAccessibilityValue + "×")
                            .font(.system(.body, design: .rounded))
                            .frame(minWidth: 56)
                    }
                    .accessibilityIdentifier("speedButton")
                    .accessibilityLabel("Playback speed")
                    .accessibilityValue(engine.rateAccessibilityValue)

                    Button(action: cycleSleepTimer) {
                        Text(sleepTimerVisibleLabel)
                            .font(.system(.body, design: .rounded))
                            .frame(minWidth: 56)
                    }
                    .accessibilityIdentifier("sleepTimerButton")
                    .accessibilityLabel("Sleep timer")
                    .accessibilityValue(sleepAccessibilityValue)
                    // Keep Off/15m/30m/60m queryable as StaticText under the button
                    // (Button + accessibilityLabel otherwise collapses Text out of AX).
                    .accessibilityChildren {
                        Text(sleepTimerVisibleLabel)
                            .accessibilityIdentifier(sleepTimerVisibleLabel)
                    }
                }
                }
            }
            .padding()
        }
        .onAppear {
            ensureSleepTimer()
            sleepClock.startTicking()
        }
        .onDisappear {
            sleepClock.stopTicking()
        }
    }

    private func ensureSleepTimer() {
        guard sleepTimer == nil else { return }
        let timer = SleepTimer(engine: engine, clock: sleepClock)
        timer.onFire = {
            sleepAccessibilityValue = "off"
        }
        sleepTimer = timer
    }

    private func cycleSleepTimer() {
        ensureSleepTimer()
        sleepTimer?.cyclePreset()
        sleepAccessibilityValue = sleepTimer?.accessibilityValue ?? "off"
    }

    private var sleepTimerVisibleLabel: String {
        switch sleepAccessibilityValue {
        case "900": return "15m"
        case "1800": return "30m"
        case "3600": return "60m"
        default: return "Off"
        }
    }

    private func togglePlayPause() {
        if let onTogglePlayPause {
            onTogglePlayPause()
            return
        }
        if engine.isPlaying {
            engine.pause()
        } else {
            engine.play()
        }
    }

    private func seekBy(_ delta: Double) {
        if let onSeekBy {
            onSeekBy(delta)
            return
        }
        let current = engine.avPlayer.currentTime().seconds
        let duration = episodeDuration > 0 ? episodeDuration : engine.duration
        engine.seek(to: min(max(0, current + delta), duration))
    }

    @ViewBuilder
    private var preparationStatus: some View {
        VStack(spacing: 12) {
            if readiness == .preparing {
                ProgressView()
                Text("Preparing clean playback")
                    .accessibilityIdentifier("playback.preparing")
            } else {
                Text("Preparation needs attention")
                    .accessibilityIdentifier("playback.preparationFailed")
            }
        }
        .foregroundStyle(.secondary)
    }

    private func secondsAccessibilityValue(_ seconds: TimeInterval) -> String {
        String(Int(seconds.rounded(.down)))
    }

    private func formattedElapsed(_ seconds: TimeInterval) -> String {
        let total = max(0, Int(seconds.rounded(.down)))
        let minutes = total / 60
        let remainder = total % 60
        return String(format: "%d:%02d", minutes, remainder)
    }
}
