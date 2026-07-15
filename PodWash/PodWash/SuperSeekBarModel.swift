//
//  SuperSeekBarModel.swift
//  PodWash
//
//  Slice 25 — Pure playhead / remaining / frontier-clamp math (ADR-021 §2, §6).
//

import Foundation

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
}
