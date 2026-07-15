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
    /// TAL 891 “The Test Case” duration (~72:05) — task-019 AC1–AC2.
    private let tal891Duration = 4325.0
    /// TAL 891 duration (~71:59) — task-025 AC3 yellow-bucket contract.
    private let tal891Task025Duration = 4319.0
    private let segmentCount = 12

    private var innerProjectDir: URL {
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
    }

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

    // MARK: - Task 019: super seek bar yellow vs applied skip (AC1–AC2)

    func testCompletedTimelineAllGreenWhenNoAdRanges() {
        let snapshot = AnalysisProgressSnapshot(
            episodeDuration: tal891Duration,
            processedEnd: tal891Duration,
            processingStart: tal891Duration,
            processingEnd: tal891Duration,
            adRanges: []
        )

        let colors = AnalysisTimelineModel.segmentColors(
            snapshot: snapshot,
            segmentCount: segmentCount
        )

        XCTAssertEqual(colors.count, segmentCount)
        XCTAssertEqual(count(colors, color: .yellow), 0)
        XCTAssertEqual(count(colors, color: .green), segmentCount)
        XCTAssertEqual(count(colors, color: .blue), 0)
        XCTAssertEqual(count(colors, color: .grey), 0)
    }

    func testYellowOnlyOnBucketsOverlappingMidEpisodeAd() {
        let adRange = AdTimeRange(start: 600.0, end: 660.0)
        let snapshot = AnalysisProgressSnapshot(
            episodeDuration: tal891Duration,
            processedEnd: tal891Duration,
            processingStart: tal891Duration,
            processingEnd: tal891Duration,
            adRanges: [adRange]
        )

        let colors = AnalysisTimelineModel.segmentColors(
            snapshot: snapshot,
            segmentCount: segmentCount
        )
        let bucketWidth = tal891Duration / Double(segmentCount)

        XCTAssertEqual(colors.count, segmentCount)
        XCTAssertEqual(colors[0], .green, "Opening bucket must stay green when ad is mid-episode only")
        XCTAssertGreaterThan(count(colors, color: .yellow), 0)

        for index in 0..<segmentCount {
            let bucketStart = Double(index) * bucketWidth
            let bucketEnd = index == segmentCount - 1
                ? tal891Duration
                : Double(index + 1) * bucketWidth
            let overlapsAd = max(0, min(adRange.end, bucketEnd) - max(adRange.start, bucketStart)) > 0
            if overlapsAd {
                XCTAssertEqual(
                    colors[index],
                    .yellow,
                    "Bucket \(index) [\(bucketStart), \(bucketEnd)) overlaps ad and should be yellow"
                )
            } else {
                XCTAssertEqual(
                    colors[index],
                    .green,
                    "Bucket \(index) [\(bucketStart), \(bucketEnd)) does not overlap ad and should be green"
                )
            }
        }
    }

    /// Yellow buckets use the full analyze union, not playback-projected intervals.
    func testCompleteSnapshotYellowFromUnionWhenUnrelatedFilteredFromPlayback() {
        let union = [
            CensorInterval(start: 20.0, end: 35.0, action: .skip, source: .unrelatedContent),
            CensorInterval(start: 50.0, end: 55.0, action: .mute, source: .profanity),
        ]
        let projected = [union[1]]

        let snapshot = AnalysisTimelineModel.completeSnapshot(
            duration: episodeDuration,
            intervals: projected,
            adRangeIntervals: union
        )
        let colors = AnalysisTimelineModel.segmentColors(snapshot: snapshot, segmentCount: segmentCount)
        XCTAssertGreaterThan(count(colors, color: .yellow), 0)

        let playbackOnly = AnalysisTimelineModel.completeSnapshot(
            duration: episodeDuration,
            intervals: projected
        )
        let playbackColors = AnalysisTimelineModel.segmentColors(
            snapshot: playbackOnly,
            segmentCount: segmentCount
        )
        XCTAssertEqual(count(playbackColors, color: .yellow), 0)
    }

    // MARK: - Task 025: yellow only on three golden ad clusters (AC3)

    func testYellowOnlyOnThreeGoldenAdClusters() throws {
        let golden = try loadThreeSponsorGolden()
        XCTAssertEqual(golden.count, 3, "Fixture must define exactly 3 hand-labeled sponsor clusters")

        let adRanges = golden.map { AdTimeRange(start: $0.start, end: $0.end) }
        let snapshot = AnalysisProgressSnapshot(
            episodeDuration: tal891Task025Duration,
            processedEnd: tal891Task025Duration,
            processingStart: tal891Task025Duration,
            processingEnd: tal891Task025Duration,
            adRanges: adRanges
        )

        let colors = AnalysisTimelineModel.segmentColors(
            snapshot: snapshot,
            segmentCount: segmentCount
        )
        let bucketWidth = tal891Task025Duration / Double(segmentCount)

        XCTAssertEqual(colors.count, segmentCount)

        let bucket0End = bucketWidth
        let bucket0OverlapsAd = adRanges.contains {
            bucketOverlaps($0.start, $0.end, bucketStart: 0, bucketEnd: bucket0End)
        }
        XCTAssertEqual(
            colors[0],
            bucket0OverlapsAd ? .yellow : .green,
            "Bucket 0 must be green unless a golden cluster overlaps it"
        )

        for index in 0..<segmentCount {
            let bucketStart = Double(index) * bucketWidth
            let bucketEnd = index == segmentCount - 1
                ? tal891Task025Duration
                : Double(index + 1) * bucketWidth
            let overlapsAd = adRanges.contains {
                bucketOverlaps($0.start, $0.end, bucketStart: bucketStart, bucketEnd: bucketEnd)
            }
            XCTAssertEqual(
                colors[index],
                overlapsAd ? .yellow : .green,
                "Bucket \(index) [\(bucketStart), \(bucketEnd)) overlap mismatch"
            )
        }

        XCTAssertLessThanOrEqual(
            contiguousYellowRuns(in: colors),
            3,
            "Adjacent yellow buckets from one cluster count as one run; expected ≤ 3 contiguous yellow runs"
        )
    }

    // MARK: - Helpers

    private func segmentationFixtureURL(
        _ name: String,
        file: StaticString = #filePath,
        line: UInt = #line
    ) throws -> URL {
        let bundle = Bundle(for: type(of: self))
        if let url = bundle.url(forResource: name, withExtension: "json", subdirectory: "Fixtures/segmentation")
            ?? bundle.url(forResource: name, withExtension: "json") {
            return url
        }
        let sourceURL = innerProjectDir
            .appendingPathComponent("PodWashTests/Fixtures/segmentation/\(name).json")
        if FileManager.default.fileExists(atPath: sourceURL.path) {
            return sourceURL
        }
        XCTFail("Missing segmentation fixture '\(name).json'", file: file, line: line)
        throw CocoaError(.fileNoSuchFile)
    }

    private func loadThreeSponsorGolden() throws -> [GoldenSegment] {
        let url = try segmentationFixtureURL("three_sponsor_golden")
        return try JSONDecoder().decode([GoldenSegment].self, from: Data(contentsOf: url))
    }

    private func count(_ colors: [TimelineSegmentColor], color: TimelineSegmentColor) -> Int {
        colors.filter { $0 == color }.count
    }

    private func bucketOverlaps(
        _ rangeStart: Double,
        _ rangeEnd: Double,
        bucketStart: Double,
        bucketEnd: Double
    ) -> Bool {
        max(0, min(rangeEnd, bucketEnd) - max(rangeStart, bucketStart)) > 0
    }

    private func contiguousYellowRuns(in colors: [TimelineSegmentColor]) -> Int {
        var runs = 0
        var inRun = false
        for color in colors {
            if color == .yellow {
                if !inRun {
                    runs += 1
                    inRun = true
                }
            } else {
                inRun = false
            }
        }
        return runs
    }
}
