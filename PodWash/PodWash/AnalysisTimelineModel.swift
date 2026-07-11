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
