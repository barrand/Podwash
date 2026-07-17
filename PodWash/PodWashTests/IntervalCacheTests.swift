//
//  IntervalCacheTests.swift
//  PodWashTests
//
//  Slice 28 — ASR model pin fingerprint invalidation (ADR-024 §3.4). AC3: after
//  fingerprint gains `asr-model:<pin>`, loads against a file written under the
//  previous fingerprint material return nil. Legacy hash material is hand-computed
//  from ADR-005 / ADR-013 tokens documented in IntervalCache (independent of impl).
//
//  Until IntervalCache(asrModelPin:) exists (Engineer), this file fails to compile.
//

import CryptoKit
import XCTest
@testable import PodWash

final class IntervalCacheTests: XCTestCase {

    private let episodeID = "fixture-spec-section8"
    private let targetWords: Set<String> = ["shit", "damn"]
    private let tinyPin = "openai_whisper-tiny.en"
    private let basePin = "openai_whisper-base.en"

    private var cacheDir: URL!

    override func setUp() {
        super.setUp()
        cacheDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("IntervalCacheTests-\(UUID().uuidString)", isDirectory: true)
    }

    override func tearDown() {
        try? IntervalCache(baseDirectory: cacheDir, asrModelPin: tinyPin).clear()
        cacheDir = nil
        super.tearDown()
    }

    // MARK: - Fingerprint helpers (spec-derived, not from production code)

    private func legacyFingerprintMaterial(for targetWords: Set<String>) -> String {
        IntervalCache.fingerprint(for: targetWords)
            + "\n"
            + "interval-format:v2"
            + "\n"
            + "segmenter:heuristic-cue-v6.1"
    }

    private func fingerprintMaterial(for targetWords: Set<String>, asrModelPin: String) -> String {
        legacyFingerprintMaterial(for: targetWords)
            + "\n"
            + "asr-model:\(asrModelPin)"
    }

    private func cacheFileURL(
        episodeID: String,
        targetWords: Set<String>,
        asrModelPin: String
    ) -> URL {
        let fp = fingerprintMaterial(for: targetWords, asrModelPin: asrModelPin)
        let digest = SHA256.hash(data: Data(fp.utf8))
        let hash = digest.map { String(format: "%02x", $0) }.joined()
        let safeStem = DownloadPaths.fileNameStem(for: episodeID)
        return cacheDir.appendingPathComponent("\(safeStem)__\(hash).json", isDirectory: false)
    }

    private func legacyCacheFileURL(episodeID: String, targetWords: Set<String>) -> URL {
        let fp = legacyFingerprintMaterial(for: targetWords)
        let digest = SHA256.hash(data: Data(fp.utf8))
        let hash = digest.map { String(format: "%02x", $0) }.joined()
        let safeStem = DownloadPaths.fileNameStem(for: episodeID)
        return cacheDir.appendingPathComponent("\(safeStem)__\(hash).json", isDirectory: false)
    }

    private func sampleIntervals() -> [CensorInterval] {
        [
            CensorInterval(
                start: 1.0,
                end: 1.5,
                action: .mute,
                source: .profanity
            ),
        ]
    }

    // MARK: - AC3: ASR model fingerprint miss

    func testAsrModelFingerprintMiss() throws {
        let cacheTiny = IntervalCache(baseDirectory: cacheDir, asrModelPin: tinyPin)
        try cacheTiny.store(sampleIntervals(), episodeID: episodeID, targetWords: targetWords)
        XCTAssertNotNil(
            cacheTiny.load(episodeID: episodeID, targetWords: targetWords),
            "Precondition: store under tiny pin must hit"
        )

        let cacheBase = IntervalCache(baseDirectory: cacheDir, asrModelPin: basePin)
        XCTAssertNil(
            cacheBase.load(episodeID: episodeID, targetWords: targetWords),
            "Load under a different asr-model pin must miss even with same episode + targets"
        )
    }

    func testLegacyFingerprintWithoutAsrModelTokenMisses() throws {
        try FileManager.default.createDirectory(at: cacheDir, withIntermediateDirectories: true)
        let legacyURL = legacyCacheFileURL(episodeID: episodeID, targetWords: targetWords)
        let data = try JSONEncoder().encode(sampleIntervals())
        try data.write(to: legacyURL, options: .atomic)

        let cache = IntervalCache(baseDirectory: cacheDir, asrModelPin: tinyPin)
        XCTAssertNil(
            cache.load(episodeID: episodeID, targetWords: targetWords),
            "Pre-slice fingerprint files without asr-model token must not load after pin token is required"
        )
    }

    func testSamePinStillHitsAfterStore() throws {
        let cache = IntervalCache(baseDirectory: cacheDir, asrModelPin: tinyPin)
        try cache.store(sampleIntervals(), episodeID: episodeID, targetWords: targetWords)
        let loaded = try XCTUnwrap(cache.load(episodeID: episodeID, targetWords: targetWords))
        XCTAssertEqual(loaded.count, 1)
        XCTAssertEqual(loaded[0].start, 1.0, accuracy: 0.0001)
    }

    // MARK: - Slice 34 AC8: segmenter fingerprint invalidation

    func testSegmenterFingerprintIncludesHeuristicCueV6() throws {
        try FileManager.default.createDirectory(at: cacheDir, withIntermediateDirectories: true)
        let preV6Material = IntervalCache.fingerprint(for: targetWords)
            + "\n"
            + "interval-format:v2"
            + "\n"
            + "segmenter:heuristic-cue-v5"
            + "\n"
            + "asr-model:\(tinyPin)"
        let digest = SHA256.hash(data: Data(preV6Material.utf8))
        let hash = digest.map { String(format: "%02x", $0) }.joined()
        let safeStem = DownloadPaths.fileNameStem(for: episodeID)
        let legacyURL = cacheDir.appendingPathComponent("\(safeStem)__\(hash).json", isDirectory: false)
        try JSONEncoder().encode(sampleIntervals()).write(to: legacyURL, options: .atomic)

        let cache = IntervalCache(baseDirectory: cacheDir, asrModelPin: tinyPin)
        XCTAssertNil(
            cache.load(episodeID: episodeID, targetWords: targetWords),
            "Cache written under segmenter:heuristic-cue-v5 must miss after v6 fingerprint bump"
        )
    }
}
