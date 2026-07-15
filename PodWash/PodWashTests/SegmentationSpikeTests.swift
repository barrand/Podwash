//
//  SegmentationSpikeTests.swift
//  PodWashTests
//
//  Slice 18 — Content segmentation spike (FAST / Done gate). Validates the committed
//  segmentation-benchmark-results.json execution-evidence artifact against the independent hand-golden.
//  NO live segmenter inference on the fast path → deterministic + CI-safe.
//  See docs/adr/012-content-segmentation-approach.md §3.5.
//

import XCTest
@testable import PodWash

final class SegmentationSpikeTests: XCTestCase {

    private let precisionFloor = 0.700
    private let recallFloor = 0.500
    private let iouThreshold = 0.5
    private let adrNumericTolerance = 0.001
    private let benchmarkArtifactName = "segmentation-benchmark-results"

    // MARK: - Path helpers

    private var innerProjectDir: URL {
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
    }

    private var repoRoot: URL {
        innerProjectDir.deletingLastPathComponent()
    }

    private func segmentationFixtureURL(
        _ name: String,
        _ ext: String,
        file: StaticString = #filePath,
        line: UInt = #line
    ) throws -> URL {
        let bundle = Bundle(for: type(of: self))
        if let url = bundle.url(forResource: name, withExtension: ext, subdirectory: "Fixtures/segmentation")
            ?? bundle.url(forResource: name, withExtension: ext) {
            return url
        }
        let sourceURL = innerProjectDir
            .appendingPathComponent("PodWashTests/Fixtures/segmentation/\(name).\(ext)")
        if FileManager.default.fileExists(atPath: sourceURL.path) {
            return sourceURL
        }
        XCTFail("Missing segmentation fixture '\(name).\(ext)' (not in test bundle nor at \(sourceURL.path))", file: file, line: line)
        throw CocoaError(.fileNoSuchFile)
    }

    private var regenerationHint: String {
        "Regenerate via PodWashSlowTests/SegmentationBenchmarkTests (VERIFY_ALLOW_SKIPS=1 scripts/verify.sh -only-testing:PodWashSlowTests/SegmentationBenchmarkTests)."
    }

    private func loadBenchmark(file: StaticString = #filePath, line: UInt = #line) throws -> SegmentationBenchmark {
        let url = try segmentationFixtureURL(benchmarkArtifactName, "json", file: file, line: line)
        let data = try Data(contentsOf: url)
        return try JSONDecoder().decode(SegmentationBenchmark.self, from: data)
    }

    private func loadGolden() throws -> [GoldenSegment] {
        let url = try segmentationFixtureURL("golden_segments", "json")
        return try JSONDecoder().decode([GoldenSegment].self, from: try Data(contentsOf: url))
    }

    private func loadTranscript(named name: String) throws -> [TimedWord] {
        let url = try segmentationFixtureURL(name, "json")
        return try JSONDecoder().decode([TimedWord].self, from: Data(contentsOf: url))
    }

    private func loadThreeSponsorGolden() throws -> [GoldenSegment] {
        let url = try segmentationFixtureURL("three_sponsor_golden", "json")
        return try JSONDecoder().decode([GoldenSegment].self, from: Data(contentsOf: url))
    }

    private func overlapsOpening(_ segment: ContentSegment, openingEnd: Double = 180.0) -> Bool {
        max(0, min(segment.end, openingEnd) - max(segment.start, 0)) > 0
    }

    // MARK: - AC2: execution evidence (fails, never skips)

    func testBenchmarkArtifactExistsAndNonEmpty() throws {
        let hint = regenerationHint

        let url: URL
        do {
            url = try segmentationFixtureURL(benchmarkArtifactName, "json")
        } catch {
            XCTFail("\(benchmarkArtifactName).json is missing — execution evidence absent. \(hint)")
            return
        }

        guard let data = try? Data(contentsOf: url) else {
            XCTFail("\(benchmarkArtifactName).json is unreadable at \(url.path). \(hint)")
            return
        }
        guard let benchmark = try? JSONDecoder().decode(SegmentationBenchmark.self, from: data) else {
            XCTFail("\(benchmarkArtifactName).json is unparsable as SegmentationBenchmark. \(hint)")
            return
        }
        XCTAssertGreaterThan(benchmark.segmentCount, 0, "benchmark segmentCount == 0 — spike produced no segments. \(hint)")
        XCTAssertEqual(benchmark.segmentCount, benchmark.segments.count, "segmentCount disagrees with segments.count")
        XCTAssertFalse(benchmark.segments.isEmpty, "benchmark.segments empty — no execution evidence. \(hint)")
    }

    // MARK: - AC1: recomputed IoU precision/recall vs independent golden

    func testPrecisionRecallAgainstGolden() throws {
        let benchmark = try loadBenchmark()
        let golden = try loadGolden()

        XCTAssertFalse(benchmark.approach.isEmpty, "benchmark.approach must be non-empty")
        XCTAssertGreaterThanOrEqual(benchmark.segments.count, 1, "benchmark.segments must have ≥ 1 entry")

        let predictions = benchmark.segments.map { ($0.start, $0.end) }
        let goldens = golden.map { ($0.start, $0.end) }
        let score = SegmentationMetrics.score(
            predictions: predictions,
            goldens: goldens,
            iouThreshold: iouThreshold
        )

        XCTAssertGreaterThanOrEqual(
            score.precision, precisionFloor,
            "recomputed precision \(score.precision) < \(precisionFloor) (TP=\(score.truePositives) FP=\(score.falsePositives))"
        )
        XCTAssertGreaterThanOrEqual(
            score.recall, recallFloor,
            "recomputed recall \(score.recall) < \(recallFloor) (TP=\(score.truePositives) FN=\(score.falseNegatives))"
        )
    }

    // MARK: - AC3: golden fixture integrity

    func testGoldenFixtureIntegrity() throws {
        let golden = try loadGolden()

        XCTAssertGreaterThanOrEqual(golden.count, 2, "golden must contain ≥ 2 positive segments")

        var totalPositiveDuration = 0.0
        for (index, segment) in golden.enumerated() {
            XCTAssertGreaterThan(segment.end, segment.start, "golden[\(index)] must have end > start")
            let duration = segment.duration
            XCTAssertGreaterThanOrEqual(duration, 5.0, "golden[\(index)] duration \(duration)s < 5.0 s")
            totalPositiveDuration += duration
        }

        XCTAssertGreaterThanOrEqual(
            totalPositiveDuration, 15.0,
            "total labeled positive duration \(totalPositiveDuration)s < 15.0 s"
        )
    }

    // MARK: - AC4: decision artifact cites committed benchmark numbers

    func testDecisionArtifactRecorded() throws {
        let benchmark = try loadBenchmark()

        let adrURL = repoRoot.appendingPathComponent("docs/adr/012-content-segmentation-approach.md")
        XCTAssertTrue(FileManager.default.fileExists(atPath: adrURL.path), "ADR-012 missing")
        let adr = try String(contentsOf: adrURL, encoding: .utf8)

        XCTAssertTrue(
            adr.contains(benchmark.approach),
            "ADR-012 must name the committed approach '\(benchmark.approach)'"
        )

        let score = SegmentationMetrics.score(
            predictions: benchmark.segments.map { ($0.start, $0.end) },
            goldens: try loadGolden().map { ($0.start, $0.end) },
            iouThreshold: iouThreshold
        )

        XCTAssertTrue(
            adrContainsNumber(adr, score.precision, label: "precision"),
            "ADR-012 must cite committed precision \(score.precision) within ±\(adrNumericTolerance)"
        )
        XCTAssertTrue(
            adrContainsNumber(adr, score.recall, label: "recall"),
            "ADR-012 must cite committed recall \(score.recall) within ±\(adrNumericTolerance)"
        )
    }

    // MARK: - Task 025: opening density false positive (AC1)

    func testOpeningWithoutSponsorAnchorProducesNoEarlySegment() throws {
        let transcript = try loadTranscript(named: "opening_no_sponsor_anchor_transcript")
        let segments = HeuristicContentSegmenter().segments(in: transcript)

        let earlySegments = segments.filter { overlapsOpening($0) }
        XCTAssertTrue(
            earlySegments.isEmpty,
            "Expected 0 segments overlapping [0, 180)s; got \(earlySegments.map { "[\($0.start), \($0.end)]" }.joined(separator: ", "))"
        )
    }

    // MARK: - Task 025: three sponsor clusters (AC2)

    func testThreeSponsorClustersMatchGoldenIoU() throws {
        let transcript = try loadTranscript(named: "three_sponsor_transcript")
        let golden = try loadThreeSponsorGolden()

        XCTAssertEqual(golden.count, 3, "Fixture must define exactly 3 hand-labeled sponsor clusters")

        let segments = HeuristicContentSegmenter().segments(in: transcript)
        XCTAssertEqual(
            segments.count,
            3,
            "Expected exactly 3 segments; got \(segments.count): \(segments.map { "[\($0.start), \($0.end)]" }.joined(separator: ", "))"
        )

        let predictions = segments.map { ($0.start, $0.end) }
        let goldens = golden.map { ($0.start, $0.end) }
        let score = SegmentationMetrics.score(
            predictions: predictions,
            goldens: goldens,
            iouThreshold: iouThreshold
        )

        XCTAssertEqual(score.falsePositives, 0, "Unmatched predicted segments at IoU ≥ \(iouThreshold)")
        XCTAssertEqual(score.falseNegatives, 0, "Unmatched golden clusters at IoU ≥ \(iouThreshold)")
        XCTAssertEqual(score.truePositives, 3)

        for (index, expected) in golden.enumerated() {
            let bestIoU = predictions.map {
                SegmentationMetrics.iou($0, (expected.start, expected.end))
            }.max() ?? 0
            XCTAssertGreaterThanOrEqual(
                bestIoU,
                iouThreshold,
                "Golden[\(index)] [\(expected.start), \(expected.end)] best IoU \(bestIoU) < \(iouThreshold)"
            )
        }
    }

    // MARK: - AC5: PodWashSlowTests scheme membership when present

    func testSlowTestTargetInSchemeIfPresent() throws {
        let schemeURL = innerProjectDir
            .appendingPathComponent("PodWash.xcodeproj/xcshareddata/xcschemes/PodWash.xcscheme")
        XCTAssertTrue(FileManager.default.fileExists(atPath: schemeURL.path), "PodWash.xcscheme missing")
        let scheme = try String(contentsOf: schemeURL, encoding: .utf8)

        guard scheme.contains("PodWashSlowTests") else {
            // No slow target in scheme — no-op pass per AC5.
            return
        }

        let chunks = scheme.components(separatedBy: "<TestableReference")
        let slowChunk = chunks.first { $0.contains("PodWashSlowTests") }
        XCTAssertNotNil(slowChunk, "PodWashSlowTests is not a member of the PodWash scheme test action")
        if let slowChunk {
            XCTAssertTrue(
                slowChunk.contains("skipped = \"YES\""),
                "PodWashSlowTests must be skipped=\"YES\" in the scheme (present for AC5 but excluded from the fast run for AC6)"
            )
        }
    }

    // MARK: - Helpers

    private func adrContainsNumber(_ adr: String, _ value: Double, label: String) -> Bool {
        let formatted = String(format: "%.3f", value)
        let variants = [
            formatted,
            String(format: "%.2f", value),
            String(format: "%.1f", value),
            String(value),
        ]
        return variants.contains { adr.contains($0) }
            || abs(extractFirstDouble(near: label, in: adr) - value) <= adrNumericTolerance
    }

    private func extractFirstDouble(near label: String, in text: String) -> Double {
        guard let range = text.range(of: label, options: .caseInsensitive) else { return -.infinity }
        let tail = String(text[range.upperBound...])
        guard let regex = try? NSRegularExpression(pattern: #"([0-9]+\.[0-9]+)"#) else { return -.infinity }
        let nsTail = tail as NSString
        guard let match = regex.firstMatch(in: tail, range: NSRange(location: 0, length: nsTail.length)),
              match.numberOfRanges > 1 else { return -.infinity }
        let number = nsTail.substring(with: match.range(at: 1))
        return Double(number) ?? -.infinity
    }
}
