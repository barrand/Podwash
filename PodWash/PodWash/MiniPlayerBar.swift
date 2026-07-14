//
//  MiniPlayerBar.swift
//  PodWash
//
//  Slice 23 — Compact player chrome above the tab bar (ADR-015 §4, slice-23-ux.md).
//

import SwiftUI

struct MiniPlayerBar: View {
    @Bindable var engine: PlaybackEngine
    let episodeTitle: String
    let podcastTitle: String
    let timelineColors: [TimelineSegmentColor]?
    let onExpand: () -> Void
    let onTogglePlayPause: () -> Void

    var body: some View {
        TimelineView(.periodic(from: .now, by: 0.25)) { _ in
            let _ = engine.uiRefreshToken
            let isPlaying = engine.isPlaying

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
                        Image(systemName: isPlaying ? "pause.fill" : "play.fill")
                            .font(.title3)
                            .frame(width: 44, height: 44)
                    }
                    .accessibilityIdentifier("miniPlayerPlayPause")
                    .accessibilityLabel(isPlaying ? "Pause" : "Play")
                    .accessibilityValue(isPlaying ? "playing" : "paused")
                }
                .padding(.horizontal, 16)
                .padding(.vertical, 10)

                if let timelineColors, !timelineColors.isEmpty {
                    AnalysisTimelineView(
                        colors: timelineColors,
                        height: AnalysisTimelineModel.miniPlayerTimelineHeight,
                        accessibilityIdentifier: "miniPlayerAnalysisTimeline"
                    )
                    .padding(.horizontal, 16)
                    .padding(.bottom, 8)
                }
            }
            .frame(maxWidth: .infinity)
            .background(.bar)
        }
    }
}
