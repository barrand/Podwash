//
//  ASRModelPinWipeTests.swift
//  PodWashTests
//
//  Slice 28 — Pin-mismatch cache wipe (ADR-024 §3.5). AC4: reconcile clears interval +
//  transcript Application Support dirs on pin change; matching pin is a no-op.
//  Pin strings pinned in slice-28 / ADR-024 §1 (independent provenance).
//
//  Until ASRModelPinStore.reconcile exists (Engineer), this file fails to compile.
//

import XCTest
@testable import PodWash

final class ASRModelPinWipeTests: XCTestCase {

    private let tinyPin = "openai_whisper-tiny.en"
    private let basePin = "openai_whisper-base.en"
    private let episodeID = "fixture-wipe"

    private var supportRoot: URL!
    private var storedPinURL: URL!
    private var intervalCacheDir: URL!
    private var transcriptCacheDir: URL!

    override func setUp() {
        super.setUp()
        supportRoot = FileManager.default.temporaryDirectory
            .appendingPathComponent("ASRModelPinWipe-\(UUID().uuidString)", isDirectory: true)
        storedPinURL = ASRModelPinStore.storedPinURL(applicationSupport: supportRoot)
        intervalCacheDir = supportRoot.appendingPathComponent("IntervalCache", isDirectory: true)
        transcriptCacheDir = supportRoot.appendingPathComponent("TranscriptCache", isDirectory: true)
    }

    override func tearDown() {
        try? FileManager.default.removeItem(at: supportRoot)
        supportRoot = nil
        storedPinURL = nil
        intervalCacheDir = nil
        transcriptCacheDir = nil
        super.tearDown()
    }

    // MARK: - Seed helpers

    private func seedCacheDirectories() throws {
        try FileManager.default.createDirectory(at: intervalCacheDir, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: transcriptCacheDir, withIntermediateDirectories: true)
        let intervalFile = intervalCacheDir.appendingPathComponent("episode.json")
        let transcriptFile = transcriptCacheDir.appendingPathComponent("episode.json")
        try Data("{}".utf8).write(to: intervalFile, options: .atomic)
        try Data("[]".utf8).write(to: transcriptFile, options: .atomic)
        XCTAssertTrue(FileManager.default.fileExists(atPath: intervalFile.path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: transcriptFile.path))
    }

    private func writeStoredPin(_ pin: String) throws {
        try FileManager.default.createDirectory(
            at: storedPinURL.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        try Data("\(pin)\n".utf8).write(to: storedPinURL, options: .atomic)
    }

    private func reconcile(bundledPin: String) throws {
        try ASRModelPinStore.reconcile(
            bundledPin: bundledPin,
            storedPinURL: storedPinURL,
            intervalCacheDirectory: intervalCacheDir,
            transcriptCacheDirectory: transcriptCacheDir
        )
    }

    // MARK: - AC4: pin-mismatch wipe

    func testPinMismatchWipesCaches() throws {
        try seedCacheDirectories()
        try writeStoredPin(tinyPin)

        try reconcile(bundledPin: basePin)

        XCTAssertFalse(
            FileManager.default.fileExists(atPath: intervalCacheDir.path),
            "Pin mismatch must remove the interval cache directory"
        )
        XCTAssertFalse(
            FileManager.default.fileExists(atPath: transcriptCacheDir.path),
            "Pin mismatch must remove the transcript cache directory"
        )
        let stored = try String(contentsOf: storedPinURL, encoding: .utf8).trimmingCharacters(in: .whitespacesAndNewlines)
        XCTAssertEqual(stored, basePin, "Reconcile must persist the new bundled pin after wipe")
    }

    func testMatchingPinDoesNotWipeCaches() throws {
        try seedCacheDirectories()
        try writeStoredPin(tinyPin)

        try reconcile(bundledPin: tinyPin)

        XCTAssertTrue(
            FileManager.default.fileExists(atPath: intervalCacheDir.path),
            "Matching pin must not delete interval cache"
        )
        XCTAssertTrue(
            FileManager.default.fileExists(atPath: transcriptCacheDir.path),
            "Matching pin must not delete transcript cache"
        )
        let intervalFiles = try FileManager.default.contentsOfDirectory(at: intervalCacheDir, includingPropertiesForKeys: nil)
        let transcriptFiles = try FileManager.default.contentsOfDirectory(at: transcriptCacheDir, includingPropertiesForKeys: nil)
        XCTAssertEqual(intervalFiles.count, 1, "Interval cache file must survive matching-pin reconcile")
        XCTAssertEqual(transcriptFiles.count, 1, "Transcript cache file must survive matching-pin reconcile")
    }

    func testMissingStoredPinWipesCaches() throws {
        try seedCacheDirectories()
        XCTAssertFalse(FileManager.default.fileExists(atPath: storedPinURL.path))

        try reconcile(bundledPin: basePin)

        XCTAssertFalse(FileManager.default.fileExists(atPath: intervalCacheDir.path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: transcriptCacheDir.path))
        let stored = try String(contentsOf: storedPinURL, encoding: .utf8).trimmingCharacters(in: .whitespacesAndNewlines)
        XCTAssertEqual(stored, basePin)
    }
}
