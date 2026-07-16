//
//  SuperSeekBarView.swift
//  PodWash
//
//  Slice 25 — Full-player combined timeline + playhead + tap-to-seek (ADR-021 §6).
//  Slice 27 — Mute marker overlays + muteMarkers AX suffix (ADR-023 §5–§6).
//  Slice 30 — Shared chrome for mini + full (ADR-026); height + AX id parameterized.
//  Slice 33 — Timestamp yellow ad bands + colorless in-flight track (ADR-030).
//

import SwiftUI

struct SuperSeekBarView: View {
    /// When true, paint solid green content track + ad/mute overlays (complete only).
    let showsCompleteContentTrack: Bool
    let adBands: [AdBand]
    let elapsed: Double
    let duration: Double
    let processedEnd: Double
    /// Precomputed mute markers for paint; empty while in flight / cleaning off.
    let muteMarkers: [MuteMarker]
    /// When non-nil, emit complete `adBands:…,muteMarkers:M` AX (complete bars only).
    let muteMarkerCountForAccessibility: Int?
    let barHeight: CGFloat
    let accessibilityIdentifier: String
    let onSeek: (Double) -> Void

    private let minimumTickWidth: CGFloat = 2

    init(
        showsCompleteContentTrack: Bool,
        adBands: [AdBand] = [],
        elapsed: Double,
        duration: Double,
        processedEnd: Double,
        muteMarkers: [MuteMarker] = [],
        muteMarkerCountForAccessibility: Int? = nil,
        barHeight: CGFloat = AnalysisTimelineModel.fullPlayerTimelineHeight,
        accessibilityIdentifier: String = "playback.superSeekBar",
        onSeek: @escaping (Double) -> Void
    ) {
        self.showsCompleteContentTrack = showsCompleteContentTrack
        self.adBands = adBands
        self.elapsed = elapsed
        self.duration = duration
        self.processedEnd = processedEnd
        self.muteMarkers = muteMarkers
        self.muteMarkerCountForAccessibility = muteMarkerCountForAccessibility
        self.barHeight = barHeight
        self.accessibilityIdentifier = accessibilityIdentifier
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
                if showsCompleteContentTrack {
                    Rectangle()
                        .fill(BrandTheme.primary.opacity(0.35))
                        .frame(height: barHeight)
                } else {
                    Rectangle()
                        .fill(Color(uiColor: .systemGray5))
                        .frame(height: barHeight)
                }

                ForEach(Array(adBands.enumerated()), id: \.offset) { _, band in
                    adBandOverlay(band: band, barWidth: width)
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
        .accessibilityIdentifier(accessibilityIdentifier)
        .accessibilityLabel("Playback position")
        .accessibilityHint(
            "Tap to seek within analyzed audio. Seeks past unscanned audio move to the analyzed frontier. When analysis is complete, skipped ad regions appear as yellow bands and profanity mute regions as red marks on the bar."
        )
        .modifier(SuperSeekBarAccessibilityValueModifier(value: accessibilityValueString))
    }

    private var accessibilityValueString: String? {
        guard let muteMarkerCountForAccessibility else { return nil }
        return SuperSeekBarModel.accessibilityValue(
            adBands: adBands,
            muteMarkerCount: muteMarkerCountForAccessibility
        )
    }

    private func adBandOverlay(band: AdBand, barWidth: CGFloat) -> some View {
        let leadingX = band.startNormalized * barWidth
        let trailingX = band.endNormalized * barWidth
        let spanWidth = trailingX - leadingX
        let bandWidth = max(spanWidth, minimumTickWidth)
        let offsetX = spanWidth >= minimumTickWidth
            ? leadingX
            : max(0, leadingX - minimumTickWidth / 2)

        return Rectangle()
            .fill(BrandTheme.accent.opacity(0.85))
            .frame(width: bandWidth, height: barHeight)
            .offset(x: offsetX)
            .allowsHitTesting(false)
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
}

/// Omits `accessibilityValue` when complete paint is hidden (in-flight / cleaning-off).
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
