//
//  MiniPlayerBar.swift
//  PodWash
//
//  Slice 23 — Compact player chrome above the tab bar (ADR-015 §4, slice-23-ux.md).
//  Slice 30 — Hosts shared SuperSeekBarView (ADR-026 / slice-30-ux.md).
//

import AVFoundation
import SwiftUI

struct MiniPlayerBar: View {
    @Bindable var engine: PlaybackEngine
    let episodeTitle: String
    let podcastTitle: String
    let timelineColors: [TimelineSegmentColor]?
    let isPreparingPlayback: Bool
    let episodeDuration: Double
    let processedEnd: Double
    let muteIntervals: [CensorInterval]
    let onExpand: () -> Void
    let onTogglePlayPause: () -> Void
    let onSeekTo: (Double) -> Void

    var body: some View {
        TimelineView(.periodic(from: .now, by: 0.25)) { _ in
            let _ = engine.uiRefreshToken
            let isPlaying = engine.isPlaying
            let isAnalyzing = isPreparingPlayback && !isPlaying
            let elapsedSeconds = engine.avPlayer.currentTime().seconds
            let duration = episodeDuration > 0 ? episodeDuration : engine.duration
            let frontier = processedEnd > 0 ? processedEnd : duration
            // Complete gate uses raw processedEnd (not seek frontier fallback).
            let timelineComplete = duration > 0 && processedEnd >= duration
            let showMuteMarkerAX = timelineColors != nil && timelineComplete
            let muteMarkers = showMuteMarkerAX
                ? SuperSeekBarModel.muteMarkers(from: muteIntervals, duration: duration)
                : []
            let muteMarkerCountForAccessibility: Int? = showMuteMarkerAX
                ? muteMarkers.count
                : nil

            VStack(spacing: 0) {
                HStack(spacing: 12) {
                    Button(action: onExpand) {
                        HStack(spacing: 12) {
                            Image(systemName: "music.note")
                                .frame(width: 40, height: 40)
                                .background(.quaternary)
                                .clipShape(RoundedRectangle(cornerRadius: 6))
                                .accessibilityHidden(true)

                            VStack(alignment: .leading, spacing: 2) {
                                Text(episodeTitle)
                                    .font(.subheadline)
                                    .fontWeight(.semibold)
                                    .lineLimit(1)
                                if !podcastTitle.isEmpty {
                                    Text(podcastTitle)
                                        .font(.caption)
                                        .foregroundStyle(.secondary)
                                        .lineLimit(1)
                                }
                            }
                            .frame(maxWidth: .infinity, alignment: .leading)
                        }
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .accessibilityIdentifier("miniPlayer")
                    .accessibilityLabel(episodeTitle.isEmpty ? "Now playing" : episodeTitle)
                    .accessibilityHint("Opens full playback controls.")

                    Button(action: onTogglePlayPause) {
                        Image(systemName: isAnalyzing ? "waveform" : (isPlaying ? "pause.fill" : "play.fill"))
                            .font(.title3)
                            .frame(width: 44, height: 44)
                            .symbolEffect(.variableColor.iterative, isActive: isAnalyzing)
                    }
                    .accessibilityIdentifier("miniPlayerPlayPause")
                    .accessibilityLabel(isAnalyzing ? "Analyzing" : (isPlaying ? "Pause" : "Play"))
                    .accessibilityValue(isAnalyzing ? "analyzing" : (isPlaying ? "playing" : "paused"))
                    .accessibilityHint(isAnalyzing ? "Playback starts when analysis finishes." : "")
                }
                .padding(.horizontal, 16)
                .padding(.vertical, 10)

                SuperSeekBarView(
                    colors: timelineColors,
                    elapsed: elapsedSeconds,
                    duration: duration,
                    processedEnd: frontier,
                    muteMarkers: muteMarkers,
                    muteMarkerCountForAccessibility: muteMarkerCountForAccessibility,
                    barHeight: AnalysisTimelineModel.miniPlayerTimelineHeight,
                    accessibilityIdentifier: "miniPlayer.superSeekBar",
                    onSeek: onSeekTo
                )
                .padding(.horizontal, 16)
                .padding(.bottom, 8)
            }
            .frame(maxWidth: .infinity)
            .background(.bar)
        }
    }
}
