//
//  SuperSeekBarModel.swift
//  PodWash
//
//  Slice 25 — Pure playhead / remaining / frontier-clamp math (ADR-021 §2, §6).
//  Slice 27 — Mute marker filter + normalize + AX suffix (ADR-023 §3, §5).
//  Slice 33 — Timestamp ad bands + analysis progress (ADR-030 §3, §5).
//

import Foundation

/// Normalized mute span on the seek bar ([0, 1] relative to episode duration).
struct MuteMarker: Equatable, Sendable {
    var startNormalized: Double
    var endNormalized: Double
}

/// Normalized ad / unrelated-skip span on the seek bar ([0, 1] relative to duration).
struct AdBand: Equatable, Sendable {
    var startNormalized: Double
    var endNormalized: Double
}

/// Pure seek-bar math — opted out of default MainActor isolation for XCTest.
nonisolated enum SuperSeekBarModel {
    /// elapsed / duration → normalized playhead in [0, 1] (AC7: 15/120 → 0.125).
    static func normalizedPlayhead(elapsed: Double, duration: Double) -> Double {
        guard duration > 0 else { return 0 }
        return min(1, max(0, elapsed / duration))
    }

    /// max(0, duration − elapsed); UI formats whole seconds for `playback.remaining`.
    static func remaining(elapsed: Double, duration: Double) -> Double {
        max(0, duration - elapsed)
    }

    /// Clamp requested seek into [0, processedEnd] (AC7: 90 → 60 when frontier 60).
    static func clampedSeek(requested: Double, processedEnd: Double) -> Double {
        min(max(0, requested), max(0, processedEnd))
    }

    /// Intervals with `source == .profanity` && `action == .mute`, normalized by duration.
    /// Empty when `duration <= 0`. Does **not** apply the complete-only UI gate.
    static func muteMarkers(
        from intervals: [CensorInterval],
        duration: Double
    ) -> [MuteMarker] {
        guard duration > 0 else { return [] }
        return intervals.compactMap { interval in
            guard interval.source == .profanity, interval.action == .mute else { return nil }
            guard interval.end > interval.start else { return nil }
            let start = min(1, max(0, interval.start / duration))
            let end = min(1, max(0, interval.end / duration))
            guard end > start else { return nil }
            return MuteMarker(startNormalized: start, endNormalized: end)
        }
    }

    /// Intervals with `source == .unrelatedContent` && `action == .skip`, normalized by duration.
    /// Empty when `duration <= 0`. Same predicate as `TranscriptViewModel.make` skip set.
    static func adBands(
        from intervals: [CensorInterval],
        duration: Double
    ) -> [AdBand] {
        guard duration > 0 else { return [] }
        let bands = intervals.compactMap { interval -> AdBand? in
            guard interval.source == .unrelatedContent, interval.action == .skip else { return nil }
            guard interval.end > interval.start else { return nil }
            let start = min(1, max(0, interval.start / duration))
            let end = min(1, max(0, interval.end / duration))
            guard end > start else { return nil }
            return AdBand(startNormalized: start, endNormalized: end)
        }
        return bands.sorted { $0.startNormalized < $1.startNormalized }
    }

    /// `processedEnd / duration` clamped to [0, 1]; `0` when `duration <= 0`.
    static func analysisProgress(processedEnd: Double, duration: Double) -> Double {
        guard duration > 0 else { return 0 }
        return min(1, max(0, processedEnd / duration))
    }

    /// Complete-bar AX: `adBands:N,<start>-<end>…,muteMarkers:M` (ADR-030 §5).
    static func accessibilityValue(
        adBands: [AdBand],
        muteMarkerCount: Int
    ) -> String {
        var tokens: [String] = ["adBands:\(adBands.count)"]
        for band in adBands {
            tokens.append(
                String(format: "%.4f-%.4f", band.startNormalized, band.endNormalized)
            )
        }
        tokens.append("muteMarkers:\(muteMarkerCount)")
        return tokens.joined(separator: ",")
    }

    /// Formats analysis progress for AX (`0.0000`–`1.0000`, 4 decimal places).
    static func analysisProgressAccessibilityValue(
        processedEnd: Double,
        duration: Double
    ) -> String {
        String(format: "%.4f", analysisProgress(processedEnd: processedEnd, duration: duration))
    }
}
