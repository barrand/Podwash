//
//  AnalysisTimelineModelTests.swift
//  PodWashTests
//
//  Slice 20 — Analysis timeline model (AC1–AC2).
//  Golden counts are hand-computed from docs/slices/slice-20-analysis-timeline.md
//  fixture strategy and docs/adr/018-analysis-timeline.md bucket rules — not
//  generated from implementation under test.
//

import XCTest
@testable import PodWash

final class AnalysisTimelineModelTests: XCTestCase {

    /// Pinned fixture: 120.0 s episode → 12 × 10.0 s buckets (slice-20 § Fixture strategy).
    private let episodeDuration = 120.0
    private let segmentCount = 12

    // MARK: - AC1: mid-analysis color counts

    func testMidAnalysisColorCounts() {
        let snapshot = AnalysisProgressSnapshot(
            episodeDuration: episodeDuration,
            processedEnd: 50.0,
            processingStart: 50.0,
            processingEnd: 60.0,
            adRanges: []
        )

        let colors = AnalysisTimelineModel.segmentColors(
            snapshot: snapshot,
            segmentCount: segmentCount
        )

        XCTAssertEqual(colors.count, segmentCount)
        XCTAssertEqual(count(colors, color: .green), 5)
        XCTAssertEqual(count(colors, color: .blue), 1)
        XCTAssertEqual(count(colors, color: .grey), 6)
        XCTAssertEqual(count(colors, color: .yellow), 0)

        XCTAssertEqual(
            AnalysisTimelineModel.accessibilityValue(from: colors),
            "ready:5,processing:1,pending:6"
        )
    }

    // MARK: - AC2: completed timeline yellow segments

    func testCompletedTimelineYellowSegments() {
        let snapshot = AnalysisProgressSnapshot(
            episodeDuration: episodeDuration,
            processedEnd: 120.0,
            processingStart: 120.0,
            processingEnd: 120.0,
            adRanges: [AdTimeRange(start: 20.0, end: 35.0)]
        )

        let colors = AnalysisTimelineModel.segmentColors(
            snapshot: snapshot,
            segmentCount: segmentCount
        )

        XCTAssertEqual(colors.count, segmentCount)
        XCTAssertEqual(count(colors, color: .yellow), 2)
        XCTAssertEqual(count(colors, color: .green), 10)
        XCTAssertEqual(count(colors, color: .blue), 0)
        XCTAssertEqual(count(colors, color: .grey), 0)

        XCTAssertEqual(
            AnalysisTimelineModel.accessibilityValue(from: colors),
            "ready:12,processing:0,pending:0"
        )
    }

    // MARK: - Helpers

    private func count(_ colors: [TimelineSegmentColor], color: TimelineSegmentColor) -> Int {
        colors.filter { $0 == color }.count
    }
}
