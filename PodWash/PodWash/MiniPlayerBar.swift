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
    let isPreparingNextEpisode: Bool
    let preparingNextAnnouncement: String?
    let comingUpItems: [ComingUpItem]
    let episodeDuration: Double
    let processedEnd: Double
    let muteIntervals: [CensorInterval]
    let onExpand: () -> Void
    let onTogglePlayPause: () -> Void
    let onSeekTo: (Double) -> Void
    let onSkipToNextShow: () -> Void

    var body: some View {
        TimelineView(.periodic(from: .now, by: 0.25)) { _ in
            let _ = engine.uiRefreshToken
            let isPlaying = engine.isPlaying
            let isAnalyzing = (isPreparingPlayback || isPreparingNextEpisode) && !isPlaying
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
                if !comingUpItems.isEmpty {
                    ComingUpStrip(items: comingUpItems)
                }

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
                                if isPreparingNextEpisode, let preparingNextAnnouncement {
                                    Text(preparingNextAnnouncement)
                                        .font(.caption)
                                        .foregroundStyle(.secondary)
                                        .lineLimit(1)
                                        .accessibilityIdentifier("preparingNextLabel")
                                } else if !podcastTitle.isEmpty {
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
                    .accessibilityValue(
                        isPreparingNextEpisode
                            ? (preparingNextAnnouncement ?? "preparing")
                            : ""
                    )

                    Button(action: onSkipToNextShow) {
                        Image(systemName: "forward.end.fill")
                            .font(.body)
                            .frame(width: 36, height: 44)
                    }
                    .accessibilityIdentifier("miniPlayerNextShow")
                    .accessibilityLabel("Next show")
                    .accessibilityHint("Skips to the next show and dismisses this episode from autoplay.")

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

/// Coming up strip — next 2–3 smart-autoplay predictions (ADR-029).
struct ComingUpStrip: View {
    let items: [ComingUpItem]

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text("Coming up")
                .font(.caption2)
                .fontWeight(.semibold)
                .foregroundStyle(.secondary)
                .padding(.horizontal, 16)
                .padding(.top, 8)
            ForEach(Array(items.enumerated()), id: \.element.episodeID) { index, item in
                HStack(spacing: 6) {
                    Text(item.podcastTitle)
                        .font(.caption2)
                        .fontWeight(.medium)
                        .lineLimit(1)
                    Text("·")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                    Text(item.episodeTitle)
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                    if item.isBinge {
                        Text("Binge")
                            .font(.caption2)
                            .foregroundStyle(.tertiary)
                    }
                }
                .padding(.horizontal, 16)
                .accessibilityElement(children: .combine)
                .accessibilityIdentifier("comingUpRow_\(index)")
                .accessibilityLabel("\(item.podcastTitle), \(item.episodeTitle)")
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("comingUpList")
        .accessibilityLabel("Coming up")
    }
}
