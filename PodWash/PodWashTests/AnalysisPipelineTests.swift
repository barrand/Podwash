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

/// Test double conforming to CloudAdSpanDetecting — records detectAdSpans invocation count.
final class CloudAdSpyDetector: CloudAdSpanDetecting, @unchecked Sendable {
    private(set) var detectCallCount = 0
    var segmentsToReturn: [ContentSegment] = []

    func detectAdSpans(in transcript: [TimedWord], episodeID: String) async throws -> [ContentSegment] {
        detectCallCount += 1
        return segmentsToReturn
    }
}

final class AnalysisPipelineTests: XCTestCase {

    private let tolerance = 0.0005
    private let episodeID = "fixture-spec-section8"
    private let retainEpisodeID = "fixture-task-030-retain"
    private let deleteEpisodeID = "fixture-task-030-delete"
    private let emptyCloudEpisodeID = "fixture-task-030-empty-cloud"
    private let fullTargetSet: Set<String> = ["shit", "damn"]
    private let subsetTargetSet: Set<String> = ["shit"]
    private let emptyTargetSet: Set<String> = []

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

    private func cleanTranscriptFixture() -> [TimedWord] {
        [
            TimedWord(word: "Hello", start: 0.50, end: 0.90),
            TimedWord(word: "world", start: 1.00, end: 1.30),
        ]
    }

    private func makeSharedCaches() -> (intervalCache: IntervalCache, transcriptCache: TranscriptCache, transcriptDir: URL) {
        let transcriptDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("TranscriptCache-030-\(UUID().uuidString)", isDirectory: true)
        return (
            IntervalCache(baseDirectory: cacheDir),
            TranscriptCache(baseDirectory: transcriptDir),
            transcriptDir
        )
    }

    private func makePipeline(
        asrSpy: ASRSpyTranscriber,
        cloudSpy: CloudAdSpyDetector,
        intervalCache: IntervalCache,
        transcriptCache: TranscriptCache
    ) -> AnalysisPipeline {
        AnalysisPipeline(
            transcriber: asrSpy,
            cache: intervalCache,
            transcriptCache: transcriptCache,
            cloudAdDetector: cloudSpy
        )
    }

    /// Mirrors episode delete / download cleanup — transcript plus interval artifacts.
    private func removePersistedEpisodeAnalysis(
        episodeID: String,
        intervalCache: IntervalCache,
        transcriptCache: TranscriptCache
    ) throws {
        try transcriptCache.remove(episodeID: episodeID)
        let stem = DownloadPaths.fileNameStem(for: episodeID)
        let fm = FileManager.default
        guard fm.fileExists(atPath: intervalCache.baseDirectory.path) else { return }
        let contents = try fm.contentsOfDirectory(
            at: intervalCache.baseDirectory,
            includingPropertiesForKeys: nil
        )
        for url in contents where url.lastPathComponent.hasPrefix("\(stem)__") {
            try fm.removeItem(at: url)
        }
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

    // MARK: - Task 020: interval cache hit + missing transcript backfill

    private let backfillEpisodeID = "fixture-transcript-backfill"

    private func seedIntervalCacheOnly(
        episodeID: String,
        intervalCache: IntervalCache,
        transcriptCache: TranscriptCache,
        targetWords: Set<String>,
        file: StaticString = #filePath,
        line: UInt = #line
    ) throws {
        let seeded = CensorInterval(start: 1.0, end: 2.0, action: .mute, source: .profanity)
        try intervalCache.store([seeded], episodeID: episodeID, targetWords: targetWords)
        XCTAssertNotNil(
            intervalCache.load(episodeID: episodeID, targetWords: targetWords),
            file: file,
            line: line
        )
        XCTAssertNil(transcriptCache.load(episodeID: episodeID), file: file, line: line)
    }

    func testIntervalCacheHitWithMissingTranscriptPersistsTranscript() async throws {
        let transcriptCacheDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("TranscriptCacheBackfill-\(UUID().uuidString)", isDirectory: true)
        defer { try? TranscriptCache(baseDirectory: transcriptCacheDir).clear() }

        let transcriptCache = TranscriptCache(baseDirectory: transcriptCacheDir)
        let intervalCache = IntervalCache(baseDirectory: cacheDir)
        try seedIntervalCacheOnly(
            episodeID: backfillEpisodeID,
            intervalCache: intervalCache,
            transcriptCache: transcriptCache,
            targetWords: fullTargetSet
        )

        let injectedTranscript = try loadTranscript()
        XCTAssertEqual(injectedTranscript.count, 5)

        let localSpy = ASRSpyTranscriber()
        let localPipeline = AnalysisPipeline(
            transcriber: localSpy,
            cache: intervalCache,
            transcriptCache: transcriptCache
        )

        _ = try await localPipeline.analyze(
            episode: EpisodeIdentity(id: backfillEpisodeID),
            audioURL: dummyAudioURL(),
            targetWords: fullTargetSet,
            injectedTranscript: injectedTranscript
        )

        let loaded = transcriptCache.load(episodeID: backfillEpisodeID)
        XCTAssertNotNil(
            loaded,
            "interval cache hit with missing transcript must persist TranscriptCache"
        )
        XCTAssertEqual(loaded?.count, 5)
        XCTAssertEqual(localSpy.transcribeCallCount, 0, "injected transcript must bypass ASR on backfill")
    }

    func testIntervalCacheHitWithMissingTranscriptInvokesASRForBackfill() async throws {
        let transcriptCacheDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("TranscriptCacheBackfill-\(UUID().uuidString)", isDirectory: true)
        defer { try? TranscriptCache(baseDirectory: transcriptCacheDir).clear() }

        let transcriptCache = TranscriptCache(baseDirectory: transcriptCacheDir)
        let intervalCache = IntervalCache(baseDirectory: cacheDir)
        try seedIntervalCacheOnly(
            episodeID: backfillEpisodeID,
            intervalCache: intervalCache,
            transcriptCache: transcriptCache,
            targetWords: fullTargetSet
        )

        let localSpy = ASRSpyTranscriber()
        localSpy.wordsToReturn = try loadTranscript()

        let localPipeline = AnalysisPipeline(
            transcriber: localSpy,
            cache: intervalCache,
            transcriptCache: transcriptCache
        )

        _ = try await localPipeline.analyze(
            episode: EpisodeIdentity(id: backfillEpisodeID),
            audioURL: dummyAudioURL(),
            targetWords: fullTargetSet
        )

        XCTAssertGreaterThanOrEqual(
            localSpy.transcribeCallCount,
            1,
            "interval cache hit with missing transcript must invoke ASR for backfill"
        )
        XCTAssertNotNil(transcriptCache.load(episodeID: backfillEpisodeID))
    }

    // MARK: - Task 030: retain completed analysis across navigation

    func testCompletedAnalysisSurvivesNewPipelineForUndeletedEpisode() async throws {
        let (intervalCache, transcriptCache, transcriptDir) = makeSharedCaches()
        defer { try? TranscriptCache(baseDirectory: transcriptDir).clear() }

        let transcript = try loadTranscript()
        let asrSpy1 = ASRSpyTranscriber()
        asrSpy1.wordsToReturn = transcript
        let cloudSpy1 = CloudAdSpyDetector()
        cloudSpy1.segmentsToReturn = [ContentSegment(start: 10.0, end: 20.0)]
        let pipeline1 = makePipeline(
            asrSpy: asrSpy1,
            cloudSpy: cloudSpy1,
            intervalCache: intervalCache,
            transcriptCache: transcriptCache
        )

        let episode = EpisodeIdentity(id: retainEpisodeID)
        let first = try await pipeline1.analyze(
            episode: episode,
            audioURL: dummyAudioURL(),
            targetWords: fullTargetSet
        )

        XCTAssertEqual(asrSpy1.transcribeCallCount, 1, "first path must transcribe once")
        XCTAssertEqual(cloudSpy1.detectCallCount, 1, "first path must invoke cloud ad detection once")
        XCTAssertNotNil(transcriptCache.load(episodeID: retainEpisodeID))
        XCTAssertNotNil(intervalCache.load(episodeID: retainEpisodeID, targetWords: fullTargetSet))

        let asrSpy2 = ASRSpyTranscriber()
        let cloudSpy2 = CloudAdSpyDetector()
        let pipeline2 = makePipeline(
            asrSpy: asrSpy2,
            cloudSpy: cloudSpy2,
            intervalCache: intervalCache,
            transcriptCache: transcriptCache
        )

        let second = try await pipeline2.analyze(
            episode: episode,
            audioURL: dummyAudioURL(),
            targetWords: fullTargetSet
        )

        XCTAssertEqual(second, first, "undeleted episode must reuse persisted intervals")
        XCTAssertEqual(asrSpy2.transcribeCallCount, 0, "fresh pipeline must not re-transcribe")
        XCTAssertEqual(cloudSpy2.detectCallCount, 0, "fresh pipeline must not re-run cloud ad detection")
        XCTAssertEqual(transcriptCache.load(episodeID: retainEpisodeID), transcript)
    }

    func testDeletedEpisodeDoesNotReuseCompletedAnalysis() async throws {
        let (intervalCache, transcriptCache, transcriptDir) = makeSharedCaches()
        defer { try? TranscriptCache(baseDirectory: transcriptDir).clear() }

        let transcript = try loadTranscript()
        let asrSpy1 = ASRSpyTranscriber()
        asrSpy1.wordsToReturn = transcript
        let cloudSpy1 = CloudAdSpyDetector()
        cloudSpy1.segmentsToReturn = [ContentSegment(start: 10.0, end: 20.0)]
        let pipeline1 = makePipeline(
            asrSpy: asrSpy1,
            cloudSpy: cloudSpy1,
            intervalCache: intervalCache,
            transcriptCache: transcriptCache
        )

        let episode = EpisodeIdentity(id: deleteEpisodeID)
        _ = try await pipeline1.analyze(
            episode: episode,
            audioURL: dummyAudioURL(),
            targetWords: fullTargetSet
        )
        XCTAssertEqual(asrSpy1.transcribeCallCount, 1)
        XCTAssertEqual(cloudSpy1.detectCallCount, 1)

        try removePersistedEpisodeAnalysis(
            episodeID: deleteEpisodeID,
            intervalCache: intervalCache,
            transcriptCache: transcriptCache
        )
        XCTAssertNil(transcriptCache.load(episodeID: deleteEpisodeID))
        XCTAssertNil(intervalCache.load(episodeID: deleteEpisodeID, targetWords: fullTargetSet))

        let asrSpy2 = ASRSpyTranscriber()
        asrSpy2.wordsToReturn = transcript
        let cloudSpy2 = CloudAdSpyDetector()
        cloudSpy2.segmentsToReturn = [ContentSegment(start: 10.0, end: 20.0)]
        let pipeline2 = makePipeline(
            asrSpy: asrSpy2,
            cloudSpy: cloudSpy2,
            intervalCache: intervalCache,
            transcriptCache: transcriptCache
        )

        _ = try await pipeline2.analyze(
            episode: episode,
            audioURL: dummyAudioURL(),
            targetWords: fullTargetSet
        )

        XCTAssertEqual(
            asrSpy2.transcribeCallCount,
            1,
            "after delete cleanup, fresh analysis must transcribe again"
        )
        XCTAssertEqual(
            cloudSpy2.detectCallCount,
            1,
            "after delete cleanup, fresh analysis must invoke cloud ad detection again"
        )
    }

    func testCompletedEmptyCloudAnalysisIsReused() async throws {
        let (intervalCache, transcriptCache, transcriptDir) = makeSharedCaches()
        defer { try? TranscriptCache(baseDirectory: transcriptDir).clear() }

        let transcript = cleanTranscriptFixture()
        let asrSpy1 = ASRSpyTranscriber()
        asrSpy1.wordsToReturn = transcript
        let cloudSpy1 = CloudAdSpyDetector()
        cloudSpy1.segmentsToReturn = []
        let pipeline1 = makePipeline(
            asrSpy: asrSpy1,
            cloudSpy: cloudSpy1,
            intervalCache: intervalCache,
            transcriptCache: transcriptCache
        )

        let episode = EpisodeIdentity(id: emptyCloudEpisodeID)
        let first = try await pipeline1.analyze(
            episode: episode,
            audioURL: dummyAudioURL(),
            targetWords: emptyTargetSet
        )

        XCTAssertTrue(first.isEmpty, "fixture has no profanity or ad spans")
        XCTAssertEqual(cloudSpy1.detectCallCount, 1, "first path must complete cloud ad detection")
        XCTAssertNotNil(
            intervalCache.load(episodeID: emptyCloudEpisodeID, targetWords: emptyTargetSet),
            "zero-span cloud result must persist an explicit completion record"
        )

        let asrSpy2 = ASRSpyTranscriber()
        let cloudSpy2 = CloudAdSpyDetector()
        let pipeline2 = makePipeline(
            asrSpy: asrSpy2,
            cloudSpy: cloudSpy2,
            intervalCache: intervalCache,
            transcriptCache: transcriptCache
        )

        let second = try await pipeline2.analyze(
            episode: episode,
            audioURL: dummyAudioURL(),
            targetWords: emptyTargetSet
        )

        XCTAssertEqual(second, first)
        XCTAssertEqual(asrSpy2.transcribeCallCount, 0, "cache hit must not re-transcribe")
        XCTAssertEqual(cloudSpy2.detectCallCount, 0, "cache hit must not re-run cloud ad detection")
    }
}
