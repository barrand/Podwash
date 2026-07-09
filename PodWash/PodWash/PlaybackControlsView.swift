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

    var body: some View {
        TimelineView(.periodic(from: .now, by: 0.25)) { _ in
            let _ = engine.uiRefreshToken
            let isPlaying = engine.avPlayer.timeControlStatus == .playing
            let elapsedSeconds = engine.avPlayer.currentTime().seconds

            VStack(spacing: 24) {
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
                        Image(systemName: isPlaying ? "pause.circle.fill" : "play.circle.fill")
                            .font(.system(size: 56))
                    }
                    .accessibilityIdentifier("playback.playPause")
                    .accessibilityLabel(isPlaying ? "Pause" : "Play")
                    .accessibilityValue(isPlaying ? "playing" : "paused")

                    Button(action: { engine.seek(by: 15) }) {
                        Image(systemName: "goforward.15")
                            .font(.title)
                    }
                    .accessibilityIdentifier("playback.seekForward15")
                    .accessibilityLabel("Seek forward 15 seconds")
                }
            }
            .padding()
        }
    }

    private func togglePlayPause() {
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
