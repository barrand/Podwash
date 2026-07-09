//
//  IntervalBuilderTests.swift
//  PodWashTests
//
//  Slice 02 — Matching engine. Verifies IntervalBuilder against
//  docs/specs/matching-spec.md §5 (padding + midpoint expansion), §6
//  (sort-and-merge), and the §8 hand-computed golden (loaded from fixture JSON
//  with independent provenance — see Fixtures/transcripts/README.md).
//

import XCTest
@testable import PodWash

final class IntervalBuilderTests: XCTestCase {

    /// Tolerance for all Double comparisons (±0.0005 s per the slice AC).
    private let tolerance = 0.0005

    /// Minimal decode shape for golden expected-interval JSON (no action field).
    private struct GoldenInterval: Decodable {
        let start: Double
        let end: Double
    }

    // MARK: - Fixture loading

    /// Load fixture JSON by stem + extension. Tries the test bundle first
    /// (synchronized-group resource), then falls back to a `#file`-relative
    /// path so the fixtures resolve regardless of how the group adds resources.
    /// Fails (never skips) if the fixture cannot be located.
    private func fixtureData(_ name: String, file: StaticString = #filePath, line: UInt = #line) throws -> Data {
        let bundle = Bundle(for: type(of: self))
        if let url = bundle.url(forResource: name, withExtension: "json", subdirectory: "Fixtures/transcripts")
            ?? bundle.url(forResource: name, withExtension: "json") {
            return try Data(contentsOf: url)
        }
        let sourceURL = URL(fileURLWithPath: "\(#filePath)")
            .deletingLastPathComponent()
            .appendingPathComponent("Fixtures/transcripts/\(name).json")
        if FileManager.default.fileExists(atPath: sourceURL.path) {
            return try Data(contentsOf: sourceURL)
        }
        XCTFail("Missing fixture '\(name).json' (not in test bundle nor at \(sourceURL.path))", file: file, line: line)
        throw CocoaError(.fileNoSuchFile)
    }

    private func loadTranscript(_ name: String) throws -> [TimedWord] {
        try JSONDecoder().decode([TimedWord].self, from: try fixtureData(name))
    }

    private func loadGolden(_ name: String) throws -> [GoldenInterval] {
        try JSONDecoder().decode([GoldenInterval].self, from: try fixtureData(name))
    }

    private func assertIntervals(
        _ actual: [CensorInterval],
        matchGolden golden: [GoldenInterval],
        file: StaticString = #filePath,
        line: UInt = #line
    ) {
        XCTAssertEqual(actual.count, golden.count, "interval count mismatch", file: file, line: line)
        guard actual.count == golden.count else { return }
        for (index, pair) in zip(actual, golden).enumerated() {
            XCTAssertEqual(pair.0.start, pair.1.start, accuracy: tolerance, "start mismatch at \(index)", file: file, line: line)
            XCTAssertEqual(pair.0.end, pair.1.end, accuracy: tolerance, "end mismatch at \(index)", file: file, line: line)
        }
    }

    // MARK: - AC3: padding constants + midpoint expansion

    func testPaddingConstantsAndMidpointExpansion() throws {
        // Constants are exactly the spec §1 values.
        XCTAssertEqual(IntervalBuilder.startPaddingSeconds, 0.080, accuracy: 1e-12)
        XCTAssertEqual(IntervalBuilder.endPaddingSeconds, 0.120, accuracy: 1e-12)
        XCTAssertEqual(IntervalBuilder.minCensorSeconds, 0.180, accuracy: 1e-12)

        // A normal word: padding of 0.200 s already exceeds MIN_CENSOR (no
        // expansion). shit, [1.00, 1.30] → [0.92, 1.42].
        let normal = IntervalBuilder.paddedInterval(wordStart: 1.00, wordEnd: 1.30)
        XCTAssertEqual(normal.start, 0.92, accuracy: tolerance)
        XCTAssertEqual(normal.end, 1.42, accuracy: tolerance)

        // t=0 clamp + midpoint-expansion quirk: [0.00, 0.05] → [0.000, 0.175].
        let clamped = IntervalBuilder.paddedInterval(wordStart: 0.00, wordEnd: 0.05)
        XCTAssertEqual(clamped.start, 0.000, accuracy: tolerance)
        XCTAssertEqual(clamped.end, 0.175, accuracy: tolerance)

        // Cross-check against the fixture golden with independent provenance.
        let transcript = try loadTranscript("clamp-expansion.input")
        let golden = try loadGolden("clamp-expansion.expected")
        let intervals = IntervalBuilder.buildIntervals(from: transcript, targetSet: ["shit", "damn"])
        assertIntervals(intervals, matchGolden: golden)
    }

    // MARK: - AC4: sort-and-merge semantics (spec §6)

    func testSortAndMergeSemantics() {
        // Touching intervals merge (start == previous.end, condition is `<=`).
        let touching = IntervalBuilder.merge([
            CensorInterval(start: 0.0, end: 1.0),
            CensorInterval(start: 1.0, end: 2.0),
        ])
        XCTAssertEqual(touching.count, 1)
        XCTAssertEqual(touching[0].start, 0.0, accuracy: tolerance)
        XCTAssertEqual(touching[0].end, 2.0, accuracy: tolerance)

        // A fully-contained interval does not shorten its container.
        let contained = IntervalBuilder.merge([
            CensorInterval(start: 0.0, end: 5.0),
            CensorInterval(start: 1.0, end: 2.0),
        ])
        XCTAssertEqual(contained.count, 1)
        XCTAssertEqual(contained[0].start, 0.0, accuracy: tolerance)
        XCTAssertEqual(contained[0].end, 5.0, accuracy: tolerance)

        // Unsorted, disjoint (gap) input is sorted and kept as two intervals.
        let disjoint = IntervalBuilder.merge([
            CensorInterval(start: 2.0, end: 3.0),
            CensorInterval(start: 0.0, end: 1.0),
        ])
        XCTAssertEqual(disjoint.count, 2)
        XCTAssertEqual(disjoint[0].start, 0.0, accuracy: tolerance)
        XCTAssertEqual(disjoint[0].end, 1.0, accuracy: tolerance)
        XCTAssertEqual(disjoint[1].start, 2.0, accuracy: tolerance)
        XCTAssertEqual(disjoint[1].end, 3.0, accuracy: tolerance)

        // Partial overlap merges and extends to the later end.
        let overlap = IntervalBuilder.merge([
            CensorInterval(start: 0.0, end: 1.0),
            CensorInterval(start: 0.5, end: 2.0),
        ])
        XCTAssertEqual(overlap.count, 1)
        XCTAssertEqual(overlap[0].end, 2.0, accuracy: tolerance)
    }

    // MARK: - AC5: spec §8 golden example

    func testSpecGoldenExample() throws {
        let transcript = try loadTranscript("spec-section8.input")
        let golden = try loadGolden("spec-section8.expected")

        let intervals = IntervalBuilder.buildIntervals(from: transcript, targetSet: ["shit", "damn"])

        assertIntervals(intervals, matchGolden: golden)
    }
}
