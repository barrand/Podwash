//
//  AnalysisChunking.swift
//  PodWash
//
//  Slice 25 — Progressive analysis chunk frontiers (ADR-021 §2–§3).
//

import Foundation

/// Pure chunk-frontier math — opted out of default MainActor isolation so
/// `@Sendable` partial-interval handlers can read `chunkSize` safely.
nonisolated enum AnalysisChunking {
    /// Binding progressive chunk length (slice fixture + production contract).
    static let chunkSize: TimeInterval = 30.0

    /// Half-open processing window after completing `processedEnd`, one bucket wide
    /// for timeline paint (matches Slice 20 fixture: after 30 → processing [30, 40)).
    static func inFlightSnapshot(
        duration: Double,
        processedEnd: Double,
        bucketWidth: Double? = nil
    ) -> AnalysisProgressSnapshot {
        let width = bucketWidth ?? (duration / Double(AnalysisTimelineModel.defaultSegmentCount))
        let clampedProcessed = min(max(0, processedEnd), duration)
        let processingEnd = min(duration, clampedProcessed + max(width, 0))
        return AnalysisProgressSnapshot(
            episodeDuration: duration,
            processedEnd: clampedProcessed,
            processingStart: clampedProcessed,
            processingEnd: processingEnd,
            adRanges: []
        )
    }

    /// Chunk end times: `chunkSize, 2×chunkSize, …, duration` (last may be shorter).
    static func chunkEnds(duration: Double) -> [Double] {
        guard duration > 0 else { return [] }
        var ends: [Double] = []
        var end = min(chunkSize, duration)
        while true {
            ends.append(end)
            if end >= duration { break }
            end = min(end + chunkSize, duration)
        }
        return ends
    }
}
