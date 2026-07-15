//
//  AnalysisPipelineTests.swift
//  PodWashTests
//
//  Slice 07 — Analyze-episode pipeline (FAST / Done gate). Injected-transcript
//  integration (AC1) and ASR-spy cache tests (AC2/AC3). See docs/adr/005-analysis-pipeline.md.
//

import XCTest
@testable import PodWash

/// Test double conforming to ASRTranscribing — records transcribe invocation count.
final class ASRSpyTranscriber: ASRTranscribing, @unchecked Sendable {
    private(set) var transcribeCallCount = 0
    var wordsToReturn: [TimedWord] = []
    var transcribeDelayMilliseconds: UInt64 = 0

    func transcribe(fileURL: URL) async throws -> [TimedWord] {
        transcribeCallCount += 1
        if transcribeDelayMilliseconds > 0 {
            try await Task.sleep(nanoseconds: transcribeDelayMilliseconds * 1_000_000)
        }
        return wordsToReturn
    }
}

final class AnalysisPipelineTests: XCTestCase {

    private let tolerance = 0.0005
    private let episodeID = "fixture-spec-section8"
    private let fullTargetSet: Set<String> = ["shit", "damn"]
    private let subsetTargetSet: Set<String> = ["shit"]

    private var cacheDir: URL!
    private var spy: ASRSpyTranscriber!
    private var pipeline: AnalysisPipeline!

    private var innerProjectDir: URL {
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
    }

    override func setUp() async throws {
        cacheDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("IntervalCacheTests-\(UUID().uuidString)", isDirectory: true)
        spy = ASRSpyTranscriber()
        pipeline = AnalysisPipeline(
            transcriber: spy,
            cache: IntervalCache(baseDirectory: cacheDir)
        )
    }

    override func tearDown() async throws {
        try? IntervalCache(baseDirectory: cacheDir).clear()
    }

    // MARK: - Fixture loading

    private struct GoldenInterval: Decodable {
        let start: Double
        let end: Double
    }

    private func fixtureData(_ name: String, subdirectory: String, file: StaticString = #filePath, line: UInt = #line) throws -> Data {
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

    private func loadTranscript() throws -> [TimedWord] {
        try JSONDecoder().decode([TimedWord].self, from: try fixtureData("spec-section8.input", subdirectory: "transcripts"))
    }

    private func loadGoldenE2E() throws -> [GoldenInterval] {
        try JSONDecoder().decode([GoldenInterval].self, from: try fixtureData("e2e_intervals", subdirectory: "analysis"))
    }

    private func dummyAudioURL() -> URL {
        innerProjectDir.appendingPathComponent("PodWashTests/Fixtures/asr/speech-pangram.wav")
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

    // MARK: - AC1: injected transcript → golden intervals

    func testPipelineProducesGoldenIntervals() async throws {
        let transcript = try loadTranscript()
        let golden = try loadGoldenE2E()
        let episode = EpisodeIdentity(id: episodeID)

        let intervals = try await pipeline.analyze(
            episode: episode,
            audioURL: dummyAudioURL(),
            targetWords: fullTargetSet,
            injectedTranscript: transcript
        )

        assertIntervals(intervals, matchGolden: golden)
        XCTAssertEqual(intervals.count, 2)
        XCTAssertEqual(spy.transcribeCallCount, 0, "injected transcript must bypass ASR")
    }

    // MARK: - AC2: second run uses cache

    func testSecondRunUsesCache() async throws {
        let transcript = try loadTranscript()
        spy.wordsToReturn = transcript
        let episode = EpisodeIdentity(id: episodeID)

        let first = try await pipeline.analyze(
            episode: episode,
            audioURL: dummyAudioURL(),
            targetWords: fullTargetSet
        )
        XCTAssertEqual(spy.transcribeCallCount, 1)

        let second = try await pipeline.analyze(
            episode: episode,
            audioURL: dummyAudioURL(),
            targetWords: fullTargetSet
        )

        XCTAssertEqual(first, second)
        XCTAssertEqual(spy.transcribeCallCount, 1, "cache hit must not call ASR again")
    }

    // MARK: - AC3: word-list change invalidates cache

    func testWordListChangeInvalidatesCache() async throws {
        let transcript = try loadTranscript()
        spy.wordsToReturn = transcript
        let episode = EpisodeIdentity(id: episodeID)

        let fullRun = try await pipeline.analyze(
            episode: episode,
            audioURL: dummyAudioURL(),
            targetWords: fullTargetSet
        )
        XCTAssertEqual(spy.transcribeCallCount, 1)

        let subsetRun = try await pipeline.analyze(
            episode: episode,
            audioURL: dummyAudioURL(),
            targetWords: subsetTargetSet
        )

        XCTAssertNotEqual(fullRun, subsetRun)
        XCTAssertEqual(spy.transcribeCallCount, 2, "word-list change must trigger re-transcription")
    }

    func testLiveProgressEmitsSteppedSnapshotsDuringTranscription() async throws {
        spy.wordsToReturn = try loadTranscript()
        spy.transcribeDelayMilliseconds = 1_200
        var snapshots: [AnalysisProgressSnapshot] = []
        await MainActor.run {
            pipeline.onMainActorProgress = { snapshots.append($0) }
        }

        _ = try await pipeline.analyze(
            episode: EpisodeIdentity(id: episodeID),
            audioURL: dummyAudioURL(),
            targetWords: fullTargetSet
        )

        XCTAssertGreaterThanOrEqual(snapshots.count, 3, "ASR path should emit start, stepped, and complete snapshots")
        XCTAssertTrue(snapshots.allSatisfy { $0.adRanges.isEmpty }, "Yellow ad buckets appear only on complete snapshots")
        let firstProcessed = snapshots.first?.processedEnd ?? 0
        let lastProcessed = snapshots.last?.processedEnd ?? 0
        XCTAssertLessThan(firstProcessed, lastProcessed)
        XCTAssertEqual(snapshots.last?.processedEnd, snapshots.last?.episodeDuration)
    }

    func testCacheStoresIntervalsForEpisodeIDContainingURLCharacters() async throws {
        let unsafeID = "46177 at https://www.thisamericanlife.org"
        spy.wordsToReturn = try loadTranscript()

        let intervals = try await pipeline.analyze(
            episode: EpisodeIdentity(id: unsafeID),
            audioURL: dummyAudioURL(),
            targetWords: fullTargetSet
        )

        XCTAssertFalse(intervals.isEmpty)
        let cache = IntervalCache(baseDirectory: cacheDir)
        let cached = cache.load(episodeID: unsafeID, targetWords: fullTargetSet)
        XCTAssertEqual(cached, intervals)

        let cacheDirContents = try FileManager.default.contentsOfDirectory(
            at: cacheDir,
            includingPropertiesForKeys: nil
        )
        XCTAssertEqual(cacheDirContents.count, 1)
        let cacheFile = try XCTUnwrap(cacheDirContents.first)
        XCTAssertFalse(cacheFile.path.contains("://"))
        XCTAssertTrue(cacheFile.lastPathComponent.hasPrefix("ep-"))
        XCTAssertTrue(cacheFile.lastPathComponent.hasSuffix(".json"))
    }

    // MARK: - Slice 26 AC2: terminal transcript persist + interval cache hit reuse

    func testAnalyzePersistsTranscriptAndReusesCache() async throws {
        let transcript = try loadTranscript()
        XCTAssertEqual(transcript.count, 5, "injected transcript fixture must contain 5 words")

        let transcriptCacheDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("TranscriptCacheTests-\(UUID().uuidString)", isDirectory: true)
        defer { try? TranscriptCache(baseDirectory: transcriptCacheDir).clear() }

        let transcriptCache = TranscriptCache(baseDirectory: transcriptCacheDir)
        let localSpy = ASRSpyTranscriber()
        localSpy.wordsToReturn = transcript

        let localPipeline = AnalysisPipeline(
            transcriber: localSpy,
            cache: IntervalCache(baseDirectory: cacheDir),
            transcriptCache: transcriptCache
        )

        let episode = EpisodeIdentity(id: episodeID)

        _ = try await localPipeline.analyze(
            episode: episode,
            audioURL: dummyAudioURL(),
            targetWords: fullTargetSet
        )

        let firstLoaded = transcriptCache.load(episodeID: episodeID)
        XCTAssertNotNil(firstLoaded, "first analyze must persist transcript to TranscriptCache")
        XCTAssertEqual(firstLoaded?.count, 5)

        let second = try await localPipeline.analyze(
            episode: episode,
            audioURL: dummyAudioURL(),
            targetWords: fullTargetSet
        )

        XCTAssertEqual(localSpy.transcribeCallCount, 1, "second analyze must hit interval cache without ASR")
        XCTAssertFalse(second.isEmpty)

        let secondLoaded = transcriptCache.load(episodeID: episodeID)
        XCTAssertEqual(secondLoaded, firstLoaded, "cached transcript must remain stable on interval cache hit")
    }
}
