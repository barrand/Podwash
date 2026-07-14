//
//  PlaybackControlsView.swift
//  PodWash
//
//  Slice 03 — Minimal play/pause/seek UI (see slice-03-ux.md).
//

import AVFoundation
import SwiftUI

struct PlaybackControlsView: View {
    @Bindable var engine: PlaybackEngine
    let timelineColors: [TimelineSegmentColor]?
    let isPreparingPlayback: Bool
    let onTogglePlayPause: (() -> Void)?

    @State private var sleepClock = SystemMonotonicClock()

    init(
        engine: PlaybackEngine,
        timelineColors: [TimelineSegmentColor]? = nil,
        isPreparingPlayback: Bool = false,
        onTogglePlayPause: (() -> Void)? = nil
    ) {
        self.engine = engine
        self.timelineColors = timelineColors
        self.isPreparingPlayback = isPreparingPlayback
        self.onTogglePlayPause = onTogglePlayPause
    }
    @State private var sleepTimer: SleepTimer?
    /// Drives sleep-button accessibility; mirrors timer arm/cancel/fire.
    @State private var sleepAccessibilityValue = "off"

    var body: some View {
        TimelineView(.periodic(from: .now, by: 0.25)) { _ in
            let _ = engine.uiRefreshToken
            let isPlaying = engine.avPlayer.timeControlStatus == .playing
            let isAnalyzing = isPreparingPlayback && !isPlaying
            let elapsedSeconds = engine.avPlayer.currentTime().seconds

            VStack(spacing: 24) {
                if let timelineColors, !timelineColors.isEmpty {
                    AnalysisTimelineView(
                        colors: timelineColors,
                        height: AnalysisTimelineModel.fullPlayerTimelineHeight,
                        accessibilityIdentifier: "playbackAnalysisTimeline"
                    )
                    .frame(maxWidth: .infinity)
                }

                Text(formattedElapsed(elapsedSeconds))
                    .font(.system(.title2, design: .monospaced))
                    .accessibilityIdentifier("playback.elapsed")
                    .accessibilityLabel("Elapsed time")
                    .accessibilityValue(elapsedAccessibilityValue(elapsedSeconds))

                HStack(spacing: 32) {
                    Button(action: { engine.seek(by: -15) }) {
                        Image(systemName: "gobackward.15")
                            .font(.title)
                    }
                    .accessibilityIdentifier("playback.seekBack15")
                    .accessibilityLabel("Seek back 15 seconds")

                    Button(action: togglePlayPause) {
                        Image(systemName: isAnalyzing ? "waveform" : (isPlaying ? "pause.circle.fill" : "play.circle.fill"))
                            .font(.system(size: 56))
                            .foregroundStyle(BrandTheme.primary)
                            .symbolEffect(.variableColor.iterative, isActive: isAnalyzing)
                    }
                    .accessibilityIdentifier("playback.playPause")
                    .accessibilityLabel(isAnalyzing ? "Analyzing" : (isPlaying ? "Pause" : "Play"))
                    .accessibilityValue(isAnalyzing ? "analyzing" : (isPlaying ? "playing" : "paused"))
                    .accessibilityHint(isAnalyzing ? "Playback starts when analysis finishes." : "")

                    Button(action: { engine.seek(by: 15) }) {
                        Image(systemName: "goforward.15")
                            .font(.title)
                    }
                    .accessibilityIdentifier("playback.seekForward15")
                    .accessibilityLabel("Seek forward 15 seconds")
                }
                // Brand accent sentinel (ADR-019 §4) — sibling of transport row; ids unchanged.
                Color.clear
                    .frame(width: 1, height: 1)
                    .accessibilityElement(children: .ignore)
                    .accessibilityIdentifier("themePrimaryAccent")
                    .accessibilityLabel("Brand primary accent")
                    .accessibilityValue("brandPrimary")
                    .allowsHitTesting(false)

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
                        Image(systemName: sleepAccessibilityValue == "off"
                              ? "moon.zzz"
                              : "moon.zzz.fill")
                            .font(.title2)
                    }
                    .accessibilityIdentifier("sleepTimerButton")
                    .accessibilityLabel("Sleep timer")
                    .accessibilityValue(sleepAccessibilityValue)
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

    private func togglePlayPause() {
        if let onTogglePlayPause {
            onTogglePlayPause()
            return
        }
        if isPreparingPlayback && !engine.isPlaying {
            return
        }
        if engine.isPlaying {
            engine.pause()
        } else {
            engine.play()
        }
    }

    private func elapsedAccessibilityValue(_ seconds: TimeInterval) -> String {
        String(Int(seconds.rounded(.down)))
    }

    private func formattedElapsed(_ seconds: TimeInterval) -> String {
        let total = max(0, Int(seconds.rounded(.down)))
        let minutes = total / 60
        let remainder = total % 60
        return String(format: "%d:%02d", minutes, remainder)
    }
}
