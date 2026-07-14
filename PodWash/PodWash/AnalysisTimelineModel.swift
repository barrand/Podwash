//
//  AnalysisTimelineModel.swift
//  PodWash
//
//  Slice 20 — Pure segment bucketing + color assignment (ADR-018). No SwiftUI.
//

import Foundation

enum TimelineSegmentColor: String, Equatable, Sendable {
    case green
    case blue
    case grey
    case yellow
}

enum AnalysisTimelineModel {
    static let defaultSegmentCount = 12

    /// Mini-player strip height (task-011).
    static let miniPlayerTimelineHeight = 12.0
    /// Full-player strip height (task-011).
    static let fullPlayerTimelineHeight = 20.0

    /// Terminal snapshot for player chrome from cached analysis intervals.
    ///
    /// - Parameters:
    ///   - intervals: Playback-projected intervals (profanity + enabled unrelated).
    ///   - adRangeIntervals: Full analyzed union for yellow buckets; defaults to `intervals`.
    ///     Pass the cache union so ad spans appear on the timeline even when unrelated
    ///     skip/mute is disabled (ADR-013 playback filter vs ADR-018 display).
    static func completeSnapshot(
        duration: Double,
        intervals: [CensorInterval],
        adRangeIntervals: [CensorInterval]? = nil
    ) -> AnalysisProgressSnapshot {
        let adSource = adRangeIntervals ?? intervals
        let adRanges = adSource
            .filter { $0.source == .unrelatedContent }
            .map { AdTimeRange(start: $0.start, end: $0.end) }
        return AnalysisProgressSnapshot(
            episodeDuration: duration,
            processedEnd: duration,
            processingStart: duration,
            processingEnd: duration,
            adRanges: adRanges
        )
    }

    /// First snapshot when analysis begins (one blue bucket at the start).
    static func startSnapshot(duration: Double) -> AnalysisProgressSnapshot {
        let bucketWidth = duration / Double(defaultSegmentCount)
        return AnalysisProgressSnapshot(
            episodeDuration: duration,
            processedEnd: 0,
            processingStart: 0,
            processingEnd: bucketWidth,
            adRanges: []
        )
    }

    /// Mid-analysis snapshot while ASR is in flight (time-based UI progress; not ASR chunk truth).
    static func inFlightSnapshot(
        duration: Double,
        processedEnd: Double
    ) -> AnalysisProgressSnapshot {
        let bucketWidth = duration / Double(defaultSegmentCount)
        let clampedProcessed = min(max(0, processedEnd), duration)
        let processingEnd = min(duration, clampedProcessed + bucketWidth)
        return AnalysisProgressSnapshot(
            episodeDuration: duration,
            processedEnd: clampedProcessed,
            processingStart: clampedProcessed,
            processingEnd: processingEnd,
            adRanges: []
        )
    }

    /// Returns exactly `segmentCount` colors. Bucket width = duration / segmentCount.
    static func segmentColors(
        snapshot: AnalysisProgressSnapshot,
        segmentCount: Int = defaultSegmentCount
    ) -> [TimelineSegmentColor] {
        guard segmentCount > 0, snapshot.episodeDuration > 0 else { return [] }

        let width = snapshot.episodeDuration / Double(segmentCount)
        let isComplete = snapshot.processedEnd >= snapshot.episodeDuration

        return (0..<segmentCount).map { index in
            let bucketStart = Double(index) * width
            let bucketEnd: Double
            if index == segmentCount - 1 {
                bucketEnd = snapshot.episodeDuration
            } else {
                bucketEnd = Double(index + 1) * width
            }

            if isComplete,
               snapshot.adRanges.contains(where: { overlaps($0.start, $0.end, bucketStart, bucketEnd) }) {
                return .yellow
            }
            if overlaps(
                snapshot.processingStart,
                snapshot.processingEnd,
                bucketStart,
                bucketEnd
            ) {
                return .blue
            }
            if bucketEnd <= snapshot.processedEnd {
                return .green
            }
            return .grey
        }
    }

    /// `ready` = green + yellow; `processing` = blue; `pending` = grey.
    static func accessibilityValue(from colors: [TimelineSegmentColor]) -> String {
        let ready = colors.filter { $0 == .green || $0 == .yellow }.count
        let processing = colors.filter { $0 == .blue }.count
        let pending = colors.filter { $0 == .grey }.count
        return "ready:\(ready),processing:\(processing),pending:\(pending)"
    }

    /// Half-open ranges `[aStart, aEnd)` and `[bStart, bEnd)` overlap iff intersection length > 0.
    private static func overlaps(
        _ aStart: Double,
        _ aEnd: Double,
        _ bStart: Double,
        _ bEnd: Double
    ) -> Bool {
        max(0, min(aEnd, bEnd) - max(aStart, bStart)) > 0
    }
}
