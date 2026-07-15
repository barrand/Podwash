//
//  TranscriptCacheTests.swift
//  PodWashTests
//
//  Slice 26 — Episode transcript viewer. AC1 (store/load round-trip) and AC10
//  (remove invalidation). Golden: spec-section8.input.json — hand-authored from
//  matching-spec.md §8 worked example (Slice 07 provenance; ±0.0005 s).
//  Until TranscriptCache exists (Engineer), this file fails to compile — TDD red.
//

import XCTest
@testable import PodWash

final class TranscriptCacheTests: XCTestCase {

    private let tolerance = 0.0005
    private let section8EpisodeID = "fixture-spec-section8"
    private let deleteEpisodeID = "fixture-delete"

    private var cacheDir: URL!
    private var cache: TranscriptCache!

    private var innerProjectDir: URL {
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
    }

    override func setUp() {
        super.setUp()
        cacheDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("TranscriptCacheTests-\(UUID().uuidString)", isDirectory: true)
        cache = TranscriptCache(baseDirectory: cacheDir)
    }

    override func tearDown() {
        try? cache.clear()
        cacheDir = nil
        cache = nil
        super.tearDown()
    }

    // MARK: - Fixture loading

    private func fixtureData(
        _ name: String,
        subdirectory: String,
        file: StaticString = #filePath,
        line: UInt = #line
    ) throws -> Data {
        let bundle = Bundle(for: type(of: self))
        if let url = bundle.url(forResource: name, withExtension: "json", subdirectory: subdirectory)
            ?? bundle.url(forResource: name, withExtension: "json") {
            return try Data(contentsOf: url)
        }
        let sourceURL = innerProjectDir
            .appendingPathComponent("PodWashTests/Fixtures/\(subdirectory)/\(name).json")
        if FileManager.default.fileExists(atPath: sourceURL.path) {
            return try Data(contentsOf: sourceURL)
        }
        XCTFail("Missing fixture '\(name).json' in \(subdirectory)", file: file, line: line)
        throw CocoaError(.fileNoSuchFile)
    }

    private func loadSection8Transcript() throws -> [TimedWord] {
        try JSONDecoder().decode(
            [TimedWord].self,
            from: try fixtureData("spec-section8.input", subdirectory: "transcripts")
        )
    }

    private func assertWords(
        _ actual: [TimedWord],
        match expected: [TimedWord],
        file: StaticString = #filePath,
        line: UInt = #line
    ) {
        XCTAssertEqual(actual.count, expected.count, "word count mismatch", file: file, line: line)
        guard actual.count == expected.count else { return }
        for (index, pair) in zip(actual, expected).enumerated() {
            XCTAssertEqual(pair.0.word, pair.1.word, "word text mismatch at \(index)", file: file, line: line)
            XCTAssertEqual(pair.0.start, pair.1.start, accuracy: tolerance, "start mismatch at \(index)", file: file, line: line)
            XCTAssertEqual(pair.0.end, pair.1.end, accuracy: tolerance, "end mismatch at \(index)", file: file, line: line)
        }
    }

    // MARK: - AC1

    func testStoreLoadRoundTrip() throws {
        let words = try loadSection8Transcript()
        XCTAssertEqual(words.count, 5, "spec-section8 fixture must contain 5 words")

        try cache.store(words, episodeID: section8EpisodeID)

        let loaded = cache.load(episodeID: section8EpisodeID)
        XCTAssertNotNil(loaded, "load must return transcript after store")
        assertWords(try XCTUnwrap(loaded), match: words)
    }

    // MARK: - AC10

    func testRemoveClearsTranscript() throws {
        let words = try loadSection8Transcript()
        try cache.store(words, episodeID: deleteEpisodeID)

        try cache.remove(episodeID: deleteEpisodeID)

        XCTAssertNil(cache.load(episodeID: deleteEpisodeID), "load must return nil after remove")
    }
}
