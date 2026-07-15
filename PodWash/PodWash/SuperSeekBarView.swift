//
//  SuperSeekBarView.swift
//  PodWash
//
//  Slice 25 — Full-player combined timeline + playhead + tap-to-seek (ADR-021 §6).
//  Slice 27 — Mute marker overlays + muteMarkers AX suffix (ADR-023 §5–§6).
//

import SwiftUI

struct SuperSeekBarView: View {
    let colors: [TimelineSegmentColor]?
    let elapsed: Double
    let duration: Double
    let processedEnd: Double
    /// Precomputed mute markers for paint; empty while in flight / cleaning off.
    let muteMarkers: [MuteMarker]
    /// When non-nil, append `,muteMarkers:N` to timeline AX (complete colored bars only).
    let muteMarkerCountForAccessibility: Int?
    let onSeek: (Double) -> Void

    private let barHeight = AnalysisTimelineModel.fullPlayerTimelineHeight
    private let minimumTickWidth: CGFloat = 2

    init(
        colors: [TimelineSegmentColor]?,
        elapsed: Double,
        duration: Double,
        processedEnd: Double,
        muteMarkers: [MuteMarker] = [],
        muteMarkerCountForAccessibility: Int? = nil,
        onSeek: @escaping (Double) -> Void
    ) {
        self.colors = colors
        self.elapsed = elapsed
        self.duration = duration
        self.processedEnd = processedEnd
        self.muteMarkers = muteMarkers
        self.muteMarkerCountForAccessibility = muteMarkerCountForAccessibility
        self.onSeek = onSeek
    }

    var body: some View {
        GeometryReader { geo in
            let width = max(geo.size.width, 1)
            let playheadX = SuperSeekBarModel.normalizedPlayhead(
                elapsed: elapsed,
                duration: duration
            ) * width

            ZStack(alignment: .leading) {
                if let colors, !colors.isEmpty {
                    HStack(spacing: 0) {
                        ForEach(Array(colors.enumerated()), id: \.offset) { _, color in
                            Rectangle()
                                .fill(Self.swiftUIColor(color))
                        }
                    }
                    .frame(height: barHeight)
                } else {
                    Rectangle()
                        .fill(Color(uiColor: .systemGray5))
                        .frame(height: barHeight)
                }

                ForEach(Array(muteMarkers.enumerated()), id: \.offset) { _, marker in
                    muteMarkerOverlay(marker: marker, barWidth: width)
                }

                Capsule()
                    .fill(Color.primary)
                    .frame(width: 3, height: barHeight + 8)
                    .offset(x: max(0, playheadX - 1.5))
            }
            .frame(maxHeight: .infinity)
            .contentShape(Rectangle())
            .gesture(
                DragGesture(minimumDistance: 0)
                    .onEnded { value in
                        let fraction = min(1, max(0, value.location.x / width))
                        let requested = fraction * duration
                        let clamped = SuperSeekBarModel.clampedSeek(
                            requested: requested,
                            processedEnd: processedEnd
                        )
                        onSeek(clamped)
                    }
            )
        }
        .frame(height: barHeight + 8)
        .accessibilityElement(children: .ignore)
        .accessibilityIdentifier("playback.superSeekBar")
        .accessibilityLabel("Playback position")
        .accessibilityHint(
            "Tap to seek within analyzed audio. Seeks past unscanned audio move to the analyzed frontier. When analysis is complete, profanity mute regions appear as red marks on the bar."
        )
        .modifier(SuperSeekBarAccessibilityValueModifier(value: accessibilityValueString))
    }

    private var accessibilityValueString: String? {
        guard let colors, !colors.isEmpty else { return nil }
        let timeline = AnalysisTimelineModel.accessibilityValue(from: colors)
        return SuperSeekBarModel.accessibilityValue(
            timelineValue: timeline,
            muteMarkerCount: muteMarkerCountForAccessibility
        )
    }

    private func muteMarkerOverlay(marker: MuteMarker, barWidth: CGFloat) -> some View {
        let leadingX = marker.startNormalized * barWidth
        let trailingX = marker.endNormalized * barWidth
        let spanWidth = trailingX - leadingX
        let markerWidth = max(spanWidth, minimumTickWidth)
        // Ternary avoids ViewBuilder treating if/else assignments as View expressions.
        let offsetX = spanWidth >= minimumTickWidth
            ? leadingX
            : max(0, leadingX - minimumTickWidth / 2)

        return Rectangle()
            .fill(Color.red.opacity(0.85))
            .overlay {
                if markerWidth >= 4 {
                    Rectangle()
                        .strokeBorder(Color.primary.opacity(0.25), lineWidth: 1)
                }
            }
            .frame(width: markerWidth, height: barHeight)
            .offset(x: offsetX)
            .allowsHitTesting(false)
    }

    private static func swiftUIColor(_ color: TimelineSegmentColor) -> Color {
        switch color {
        case .green: return Color(uiColor: .systemGreen)
        case .blue: return Color(uiColor: .systemBlue)
        case .grey: return Color(uiColor: .systemGray4)
        case .yellow: return Color(uiColor: .systemYellow)
        }
    }
}

/// Omits `accessibilityValue` when segment colors are hidden (cleaning-off / no snapshot).
private struct SuperSeekBarAccessibilityValueModifier: ViewModifier {
    let value: String?

    @ViewBuilder
    func body(content: Content) -> some View {
        if let value {
            content.accessibilityValue(value)
        } else {
            content
        }
    }
}
