//
//  SuperSeekBarModel.swift
//  PodWash
//
//  Slice 25 — Pure playhead / remaining / frontier-clamp math (ADR-021 §2, §6).
//  Slice 27 — Mute marker filter + normalize + AX suffix (ADR-023 §3, §5).
//

import Foundation

/// Normalized mute span on the seek bar ([0, 1] relative to episode duration).
struct MuteMarker: Equatable, Sendable {
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

    /// Append `,muteMarkers:N` when `muteMarkerCount != nil`; otherwise return `timelineValue` unchanged.
    static func accessibilityValue(
        timelineValue: String,
        muteMarkerCount: Int?
    ) -> String {
        guard let muteMarkerCount else { return timelineValue }
        return "\(timelineValue),muteMarkers:\(muteMarkerCount)"
    }
}
