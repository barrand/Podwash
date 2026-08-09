//
//  MiniPlayerBar.swift
//  PodWash
//
//  Slice 23 — Compact player chrome above the tab bar (ADR-015 §4, slice-23-ux.md).
//  Slice 30 — Hosts shared SuperSeekBarView (ADR-026 / slice-30-ux.md).
//  Slice 33 — Analysis progress + timestamp ad bands (ADR-030).
//

import AVFoundation
import SwiftUI

struct MiniPlayerBar: View {
    /// QueueStatusButton plus the playback controls, including a small scrolling
    /// margin. The tab bar owns the seek bar below this card separately.
    static let shellOverlayClearance: CGFloat = 112

    @Bindable var engine: PlaybackEngine
    let readiness: AppShellModel.PlaybackReadiness
    let episodeTitle: String
    let podcastTitle: String
    let showsCompleteSeekBarPaint: Bool
    let isPreparingNextEpisode: Bool
    let preparingNextAnnouncement: String?
    let queuePresentation: QueuePresentation
    let episodeDuration: Double
    let muteIntervals: [CensorInterval]
    /// The tab shell can host this below the player controls, immediately above its tab bar.
    let showsSuperSeekBar: Bool
    let onExpand: () -> Void
    let onTogglePlayPause: () -> Void
    let onSeekTo: (Double) -> Void
    let onSkipToNext: () -> Void
    let onOpenPreparation: () -> Void

    var body: some View {
        TimelineView(.periodic(from: .now, by: 0.25)) { _ in
            let _ = engine.uiRefreshToken
            // Keep the transport state stable while AVPlayer temporarily waits.
            let isPlaying = engine.isPlaybackRequested
            let elapsedSeconds = engine.avPlayer.currentTime().seconds
            let duration = episodeDuration > 0 ? episodeDuration : engine.duration
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

            VStack(spacing: 0) {
                QueueStatusButton(presentation: queuePresentation, onOpen: onOpenPreparation)

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
                                if readiness == .preparing {
                                    Text("Preparing clean playback")
                                        .font(.caption)
                                        .foregroundStyle(.secondary)
                                        .accessibilityIdentifier("miniPlayer.preparing")
                                } else if readiness == .failed {
                                    Text("Preparation needs attention")
                                        .font(.caption)
                                        .foregroundStyle(.secondary)
                                        .accessibilityIdentifier("miniPlayer.preparationFailed")
                                } else if isPreparingNextEpisode, let preparingNextAnnouncement {
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

                    if readiness == .ready { Button(action: onSkipToNext) {
                        Image(systemName: "forward.end.fill")
                            .font(.body)
                            .frame(width: 36, height: 44)
                    }
                    .accessibilityIdentifier("miniPlayerNext")
                    .accessibilityLabel("Next")
                    .accessibilityHint("Plays the next episode in Up Next.")
                    }

                    if readiness == .ready { Button(action: onTogglePlayPause) {
                        Image(systemName: isPlaying ? "pause.fill" : "play.fill")
                            .font(.title3)
                            .frame(width: 44, height: 44)
                    }
                    .accessibilityIdentifier("miniPlayerPlayPause")
                    .accessibilityLabel(isPlaying ? "Pause" : "Play")
                    .accessibilityValue(isPlaying ? "playing" : "paused")
                    } else if readiness == .preparing {
                        ProgressView()
                            .controlSize(.small)
                            .frame(width: 44, height: 44)
                            .accessibilityIdentifier("miniPlayer.preparingProgress")
                            .accessibilityLabel("Preparing clean playback")
                    }
                }
                .padding(.horizontal, 16)
                .padding(.vertical, 10)

                if showsSuperSeekBar && readiness == .ready {
                    MiniPlayerSeekBar(
                        showsCompleteContentTrack: showCompletePaint,
                        adBands: adBands,
                        elapsed: elapsedSeconds,
                        duration: duration,
                        muteMarkers: muteMarkers,
                        muteMarkerCountForAccessibility: muteMarkerCountForAccessibility,
                        onSeekTo: onSeekTo
                    )
                }
            }
            .frame(maxWidth: .infinity)
            // `.bar` is a translucent material. This player overlays scrolling
            // content, so use the app's opaque surface instead.
            .background(BrandTheme.surface)
        }
    }
}

/// Shared mini-player analysis progress and seek chrome. The tab shell places it in the
/// space directly above the tab navigation; sheets place it inside the mini-player card.
struct MiniPlayerSeekBar: View {
    let showsCompleteContentTrack: Bool
    let adBands: [AdBand]
    let elapsed: Double
    let duration: Double
    let muteMarkers: [MuteMarker]
    let muteMarkerCountForAccessibility: Int?
    let onSeekTo: (Double) -> Void

    var body: some View {
        VStack(spacing: 4) {
            SuperSeekBarView(
                showsCompleteContentTrack: showsCompleteContentTrack,
                adBands: adBands,
                elapsed: elapsed,
                duration: duration,
                muteMarkers: muteMarkers,
                muteMarkerCountForAccessibility: muteMarkerCountForAccessibility,
                barHeight: AnalysisTimelineModel.miniPlayerTimelineHeight,
                accessibilityIdentifier: "miniPlayer.superSeekBar",
                onSeek: onSeekTo
            )
        }
        .padding(.horizontal, 16)
        .padding(.bottom, 8)
    }
}
