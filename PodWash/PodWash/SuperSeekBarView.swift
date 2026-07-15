//
//  SuperSeekBarView.swift
//  PodWash
//
//  Slice 25 — Full-player combined timeline + playhead + tap-to-seek (ADR-021 §6).
//

import SwiftUI

struct SuperSeekBarView: View {
    let colors: [TimelineSegmentColor]?
    let elapsed: Double
    let duration: Double
    let processedEnd: Double
    let onSeek: (Double) -> Void

    private let barHeight = AnalysisTimelineModel.fullPlayerTimelineHeight

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
            "Tap to seek within analyzed audio. Seeks past unscanned audio move to the analyzed frontier."
        )
        .modifier(SuperSeekBarAccessibilityValueModifier(value: accessibilityValueString))
    }

    private var accessibilityValueString: String? {
        guard let colors, !colors.isEmpty else { return nil }
        return AnalysisTimelineModel.accessibilityValue(from: colors)
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
