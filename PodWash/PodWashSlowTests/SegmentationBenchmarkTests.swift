//
//  SegmentationBenchmarkTests.swift
//  PodWashSlowTests
//
//  Slice 18 — Content segmentation spike (SLOW / nightly only — NOT a Done gate).
//  Runs production HeuristicContentSegmenter on spike_transcript.json, regenerates
//  segmentation-benchmark-results.json (the AC2 execution evidence), and asserts live P/R still
//  meet thresholds. Excluded from the default fast verify.sh run (scheme skipped="YES").
//  See docs/adr/012-content-segmentation-approach.md §3.5.
//

import XCTest
@testable import PodWash

final class SegmentationBenchmarkTests: XCTestCase {

    private let precisionFloor = 0.700
    private let recallFloor = 0.500
    private let iouThreshold = 0.5
    private let benchmarkArtifactName = "segmentation-benchmark-results"

    private var innerProjectDir: URL {
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
    }

    private var segmentationFixturesDir: URL {
        innerProjectDir.appendingPathComponent("PodWashTests/Fixtures/segmentation")
    }

    func testSegmentationBenchmarkAndRegenerateArtifact() throws {
        let transcript = try loadTranscript()
        let golden = try loadGolden()

        let segmenter = HeuristicContentSegmenter()
        let start = Date()
        let segments = segmenter.segments(in: transcript)
        let durationSeconds = Date().timeIntervalSince(start)

        XCTAssertGreaterThan(segments.count, 0, "HeuristicContentSegmenter produced no segments on the fixture")

        let predictions = segments.map { ($0.start, $0.end) }
        let goldens = golden.map { ($0.start, $0.end) }
        let score = SegmentationMetrics.score(
            predictions: predictions,
            goldens: goldens,
            iouThreshold: iouThreshold
        )

        let benchmark = SegmentationBenchmark(
            approach: segmenter.approachIdentifier,
            precision: (score.precision * 1000).rounded() / 1000,
            recall: (score.recall * 1000).rounded() / 1000,
            segmentCount: segments.count,
            segments: segments,
            durationSeconds: (durationSeconds * 1000).rounded() / 1000,
            inferenceSeconds: (durationSeconds * 1000).rounded() / 1000
        )

        try writeBenchmark(benchmark)

        XCTAssertGreaterThanOrEqual(score.precision, precisionFloor, "live precision \(score.precision) < \(precisionFloor)")
        XCTAssertGreaterThanOrEqual(score.recall, recallFloor, "live recall \(score.recall) < \(recallFloor)")
    }

    // MARK: - Helpers

    private func loadTranscript() throws -> [TimedWord] {
        let url = segmentationFixturesDir.appendingPathComponent("spike_transcript.json")
        return try JSONDecoder().decode([TimedWord].self, from: try Data(contentsOf: url))
    }

    private func loadGolden() throws -> [GoldenSegment] {
        let url = segmentationFixturesDir.appendingPathComponent("golden_segments.json")
        return try JSONDecoder().decode([GoldenSegment].self, from: try Data(contentsOf: url))
    }

    private func writeBenchmark(_ benchmark: SegmentationBenchmark) throws {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        let data = try encoder.encode(benchmark)
        let url = segmentationFixturesDir.appendingPathComponent("\(benchmarkArtifactName).json")
        try data.write(to: url, options: .atomic)
    }
}

// MARK: - Fixture helpers (duplicated from PodWashTests/SegmentationMetrics.swift — separate target)

private struct GoldenSegment: Codable, Equatable {
    let start: Double
    let end: Double
}

private struct SegmentationScore: Equatable {
    let truePositives: Int
    let falsePositives: Int
    let falseNegatives: Int

    var precision: Double {
        let denom = truePositives + falsePositives
        return denom > 0 ? Double(truePositives) / Double(denom) : 0
    }

    var recall: Double {
        let denom = truePositives + falseNegatives
        return denom > 0 ? Double(truePositives) / Double(denom) : 0
    }
}

private enum SegmentationMetrics {
    static func iou(_ a: (start: Double, end: Double), _ b: (start: Double, end: Double)) -> Double {
        let intersectionStart = max(a.start, b.start)
        let intersectionEnd = min(a.end, b.end)
        let intersection = max(0, intersectionEnd - intersectionStart)
        let union = (a.end - a.start) + (b.end - b.start) - intersection
        guard union > 0 else { return 0 }
        return intersection / union
    }

    static func score(
        predictions: [(start: Double, end: Double)],
        goldens: [(start: Double, end: Double)],
        iouThreshold: Double = 0.5
    ) -> SegmentationScore {
        let sortedPairs: [(pred: Int, golden: Int, iou: Double)] = predictions.indices.flatMap { p in
            goldens.indices.map { g in
                (pred: p, golden: g, iou: iou(predictions[p], goldens[g]))
            }
        }
        .filter { $0.iou >= iouThreshold }
        .sorted { $0.iou > $1.iou }

        var matchedPredictions = Set<Int>()
        var matchedGoldens = Set<Int>()
        var truePositives = 0

        for pair in sortedPairs {
            guard !matchedPredictions.contains(pair.pred), !matchedGoldens.contains(pair.golden) else { continue }
            matchedPredictions.insert(pair.pred)
            matchedGoldens.insert(pair.golden)
            truePositives += 1
        }

        return SegmentationScore(
            truePositives: truePositives,
            falsePositives: predictions.count - truePositives,
            falseNegatives: goldens.count - truePositives
        )
    }
}
