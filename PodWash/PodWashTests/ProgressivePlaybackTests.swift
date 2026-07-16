//
//  ProgressivePlaybackTests.swift
//  PodWashTests
//
//  Slice 25 — Progressive playback + partial schedule (ADR-021). AC1, AC2, AC8.
//
//  Fixture provenance:
//  - transcripts/spec-section8.input.json + analysis/e2e_intervals.json — hand-computed
//    per matching-spec §8 (Slice 07; independent of pipeline output).
//  - analysis/progressive-first-chunk-intervals.json — first-chunk subset (end ≤ 30.0 s)
//    of e2e_intervals.json; same §8 derivation.
//  - audio/sine-300hz-5s.wav — synthetic sine for offline RMS (Slice 08 pattern).
//  - Snapshot counts — pinned in slice-25 / FixtureProgressivePlayback (120 s, 12 buckets).
//
//  Until AnalysisChunking, preparePlaybackProgressive, onPartialIntervals, and
//  AppShellModel progressive play wiring exist (Engineer), this file fails to
//  compile — intended TDD red state.
//

import AVFoundation
import XCTest
@testable import PodWash

// MARK: - Progressive stepped double (ADR-021 §5 test seam)

/// Emits chunk snapshots + partial interval batches before `analyze` returns.
final class ProgressiveSteppedTestAnalyzer: EpisodeAnalyzing, @unchecked Sendable {
    var onPartialIntervals: AnalysisPartialIntervalsHandler?

    private let snapshots: [AnalysisProgressSnapshot]
    private let partialIntervalsBySnapshot: [[CensorInterval]]
    private let betweenSnapshotDelay: Duration
    private let terminalHold: Duration

    private(set) var analyzeReturned = false

    init(
        snapshots: [AnalysisProgressSnapshot],
        partialIntervalsBySnapshot: [[CensorInterval]],
        betweenSnapshotDelay: Duration = .milliseconds(50),
        terminalHold: Duration = .seconds(3)
    ) {
        self.snapshots = snapshots
        self.partialIntervalsBySnapshot = partialIntervalsBySnapshot
        self.betweenSnapshotDelay = betweenSnapshotDelay
        self.terminalHold = terminalHold
    }

    func analyze(
        episode: EpisodeIdentity,
        audioURL: URL,
        targetWords: Set<String>,
        injectedTranscript: [TimedWord]?
    ) async throws -> [CensorInterval] {
        try await analyze(
            episode: episode,
            audioURL: audioURL,
            targetWords: targetWords,
            injectedTranscript: injectedTranscript,
            profanityAction: .mute,
            unrelatedContent: UnrelatedContentOptions()
        )
    }

    func analyze(
        episode: EpisodeIdentity,
        audioURL: URL,
        targetWords: Set<String>,
        injectedTranscript: [TimedWord]?,
        profanityAction: CensorAction,
        unrelatedContent: UnrelatedContentOptions
    ) async throws -> [CensorInterval] {
        _ = episode
        _ = audioURL
        _ = targetWords
        _ = injectedTranscript
        _ = profanityAction
        _ = unrelatedContent

        var union: [CensorInterval] = []
        for (index, snapshot) in snapshots.enumerated() {
            let partial = index < partialIntervalsBySnapshot.count
                ? partialIntervalsBySnapshot[index]
                : []
            union.append(contentsOf: partial)
            // Pass cumulative union (matches SteppedEpisodeAnalyzer / AnalysisPipeline).
            await MainActor.run {
                onPartialIntervals?(union, snapshot)
            }
            // Yield so progressive schedule apply / catch-up land before the next delay.
            await Task.yield()
            if index < snapshots.count - 1 {
                try await Task.sleep(for: betweenSnapshotDelay)
            }
        }
        try await Task.sleep(for: terminalHold)
        analyzeReturned = true
        return union
    }
}

@MainActor
final class ProgressivePlaybackTests: XCTestCase {

    private let episodeID = "slice-25-progressive"
    private let episodeDuration = 120.0
    private let chunkSize = AnalysisChunking.chunkSize
    private let chunkReadyTolerance: TimeInterval = 0.5
    private let pipelineTolerance = 0.0005
    /// Task-022 intro unrelated skip fixture (ADR-002 skip-seek contract).
    private let introSkipStart = 0.0
    private let introSkipEnd = 8.0
    private let skipSeekTolerance = 0.1
    private let sineFixtureName = "sine-300hz-5s"
    private let sineFixtureExt = "wav"
    private let fullTargetSet: Set<String> = ["shit", "damn"]
    private let podcastTitle = "PodWash Fixture Feed"
    private let feedURL = FixtureFeed.fixtureFeedURL

    private var cacheDir: URL!
    private var downloadsDirectory: URL!
    private var settingsDefaultsSuite: String!
    private var harness: PersistenceReloadHarness!

    private var innerProjectDir: URL {
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
    }

    override func setUp() async throws {
        cacheDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("ProgressivePlayback-Cache-\(UUID().uuidString)", isDirectory: true)
        downloadsDirectory = FileManager.default.temporaryDirectory
            .appendingPathComponent("ProgressivePlayback-Downloads-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: downloadsDirectory, withIntermediateDirectories: true)
        settingsDefaultsSuite = "podwash.progressive.\(UUID().uuidString)"
        harness = PersistenceReloadHarness()
    }

    override func tearDown() async throws {
        try? IntervalCache(baseDirectory: cacheDir).clear()
        try? FileManager.default.removeItem(at: downloadsDirectory)
        if let settingsDefaultsSuite {
            UserDefaults(suiteName: settingsDefaultsSuite)?.removePersistentDomain(forName: settingsDefaultsSuite)
        }
        harness = nil
        cacheDir = nil
        downloadsDirectory = nil
        settingsDefaultsSuite = nil
    }

    // MARK: - Fixture helpers

    private struct GoldenInterval: Decodable {
        let start: Double
        let end: Double
    }

    private func fixtureData(_ name: String, subdirectory: String) throws -> Data {
        let bundle = Bundle(for: type(of: self))
        if let url = bundle.url(forResource: name, withExtension: "json", subdirectory: subdirectory)
            ?? bundle.url(forResource: name, withExtension: "json") {
            return try Data(contentsOf: url)
        }
        let sourceURL = innerProjectDir
            .appendingPathComponent("PodWashTests/Fixtures/\(subdirectory)/\(name).json")
        return try Data(contentsOf: sourceURL)
    }

    private func loadTranscript() throws -> [TimedWord] {
        try JSONDecoder().decode(
            [TimedWord].self,
            from: try fixtureData("spec-section8.input", subdirectory: "transcripts")
        )
    }

    private func loadFirstChunkGolden() throws -> [GoldenInterval] {
        try JSONDecoder().decode(
            [GoldenInterval].self,
            from: try fixtureData("progressive-first-chunk-intervals", subdirectory: "analysis")
        )
    }

    private func sineFixtureURL(file: StaticString = #filePath, line: UInt = #line) -> URL {
        let bundle = Bundle(for: type(of: self))
        guard let bundledURL = bundle.url(
            forResource: sineFixtureName,
            withExtension: sineFixtureExt,
            subdirectory: "Fixtures/audio"
        ) ?? bundle.url(forResource: sineFixtureName, withExtension: sineFixtureExt) else {
            XCTFail("Missing \(sineFixtureName).\(sineFixtureExt)", file: file, line: line)
            return URL(fileURLWithPath: "/dev/null")
        }
        let tempURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("podwash-progressive-\(UUID().uuidString)-\(sineFixtureName).\(sineFixtureExt)")
        do {
            try FileManager.default.copyItem(at: bundledURL, to: tempURL)
        } catch {
            XCTFail("Could not copy sine fixture: \(error)", file: file, line: line)
            return bundledURL
        }
        addTeardownBlock {
            try? FileManager.default.removeItem(at: tempURL)
        }
        return tempURL
    }

    private func pinnedSnapshots() -> [AnalysisProgressSnapshot] {
        FixtureProgressivePlayback.pinnedSnapshots
    }

    private func firstChunkPartialIntervals() throws -> [CensorInterval] {
        try loadFirstChunkGolden().map {
            CensorInterval(start: $0.start, end: $0.end, action: .mute, source: .profanity)
        }
    }

    private func makeIntroRaceProgressiveAnalyzer(
        betweenSnapshotDelay: Duration = .milliseconds(100),
        terminalHold: Duration = .seconds(2)
    ) -> ProgressiveSteppedTestAnalyzer {
        let introSkip = CensorInterval(
            start: introSkipStart,
            end: introSkipEnd,
            action: .skip,
            source: .unrelatedContent
        )
        return ProgressiveSteppedTestAnalyzer(
            snapshots: pinnedSnapshots(),
            partialIntervalsBySnapshot: [
                [],
                [introSkip],
                [], // union already holds intro skip from snapshot 1
            ],
            betweenSnapshotDelay: betweenSnapshotDelay,
            terminalHold: terminalHold
        )
    }

    private func writeSilentWAV(to url: URL, duration: TimeInterval, sampleRate: UInt32 = 8_000) throws {
        let numSamples = UInt32((duration * Double(sampleRate)).rounded(.down))
        let byteRate = sampleRate * 2
        let dataSize = numSamples * 2
        let riffSize = 36 + dataSize

        var header = Data()
        header.append(contentsOf: "RIFF".utf8)
        header.append(contentsOf: withUnsafeBytes(of: riffSize.littleEndian) { Data($0) })
        header.append(contentsOf: "WAVE".utf8)
        header.append(contentsOf: "fmt ".utf8)
        header.append(contentsOf: withUnsafeBytes(of: UInt32(16).littleEndian) { Data($0) })
        header.append(contentsOf: withUnsafeBytes(of: UInt16(1).littleEndian) { Data($0) })
        header.append(contentsOf: withUnsafeBytes(of: UInt16(1).littleEndian) { Data($0) })
        header.append(contentsOf: withUnsafeBytes(of: sampleRate.littleEndian) { Data($0) })
        header.append(contentsOf: withUnsafeBytes(of: byteRate.littleEndian) { Data($0) })
        header.append(contentsOf: withUnsafeBytes(of: UInt16(2).littleEndian) { Data($0) })
        header.append(contentsOf: withUnsafeBytes(of: UInt16(16).littleEndian) { Data($0) })
        header.append(contentsOf: "data".utf8)
        header.append(contentsOf: withUnsafeBytes(of: dataSize.littleEndian) { Data($0) })

        try FileManager.default.createDirectory(
            at: url.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        FileManager.default.createFile(atPath: url.path, contents: nil)
        let handle = try FileHandle(forWritingTo: url)
        defer { try? handle.close() }
        try handle.write(contentsOf: header)

        let chunk = Data(repeating: 0, count: Int(byteRate))
        var remaining = Int(dataSize)
        while remaining > 0 {
            let writeSize = min(remaining, chunk.count)
            try handle.write(contentsOf: chunk.prefix(writeSize))
            remaining -= writeSize
        }
    }

    private func longFixtureURL(
        duration: TimeInterval = 120.0,
        file: StaticString = #filePath,
        line: UInt = #line
    ) -> URL {
        let tempURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("podwash-progressive-intro-\(UUID().uuidString).wav")
        do {
            try writeSilentWAV(to: tempURL, duration: duration)
        } catch {
            XCTFail("Could not write silent fixture: \(error)", file: file, line: line)
            return URL(fileURLWithPath: "/dev/null")
        }
        addTeardownBlock {
            try? FileManager.default.removeItem(at: tempURL)
        }
        return tempURL
    }

    private func waitForEngineReady(_ engine: PlaybackEngine, timeout: TimeInterval = 10) async {
        let ready = expectation(description: "engine duration loaded")
        ready.assertForOverFulfill = false
        let deadline = Date().addingTimeInterval(timeout)
        func poll() {
            engine.refreshCurrentTime()
            if engine.duration > 0 {
                ready.fulfill()
            } else if Date() < deadline {
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.05, execute: poll)
            }
        }
        poll()
        await fulfillment(of: [ready], timeout: timeout)
    }

    private func makeProgressiveAnalyzer(
        terminalHold: Duration = .seconds(3),
        /// Hold between chunk snapshots so shell tests can observe mid-flight
        /// `processedEnd` (ADR-030 AC5) before the terminal 120.0 s snapshot.
        betweenSnapshotDelay: Duration = .milliseconds(50)
    ) throws -> ProgressiveSteppedTestAnalyzer {
        let partials = try [
            firstChunkPartialIntervals(),
            [],
            [],
        ]
        return ProgressiveSteppedTestAnalyzer(
            snapshots: pinnedSnapshots(),
            partialIntervalsBySnapshot: partials,
            betweenSnapshotDelay: betweenSnapshotDelay,
            terminalHold: terminalHold
        )
    }

    private func makePinnedSettingsStore() -> SettingsStore {
        guard let defaults = UserDefaults(suiteName: settingsDefaultsSuite!) else {
            XCTFail("Could not create isolated UserDefaults suite")
            return SettingsStore()
        }
        defaults.removePersistentDomain(forName: settingsDefaultsSuite!)
        let store = SettingsStore(userDefaults: defaults)
        for categoryID in WordCategories.allIDs {
            store.setCategoryEnabled(categoryID, false)
        }
        store.addCustomWord("shit")
        store.addCustomWord("damn")
        return store
    }

    private func fixtureEpisode() -> Episode {
        Episode(
            id: episodeID,
            title: "Progressive Fixture Episode",
            pubDate: ISO8601DateFormatter().date(from: "2026-01-15T08:00:00Z")!,
            artworkURL: URL(string: "file:///fixtures/feeds/episode-0-art.png"),
            showNotes: "<p>Progressive playback fixture.</p>",
            audioURL: URL(string: "https://fixture.podwash.tests/audio/progressive.m4a")
        )
    }

    private func installLocalDownload(for episodeID: String) throws {
        let source = sineFixtureURL()
        let destination = DownloadPaths.localFileURL(
            episodeID: episodeID,
            downloadsDirectory: downloadsDirectory
        )
        try? FileManager.default.removeItem(at: destination)
        try FileManager.default.copyItem(at: source, to: destination)
    }

    private func makeShell(
        analyzer: any EpisodeAnalyzing,
        injectedTranscript: [TimedWord]? = nil
    ) -> AppShellModel {
        let persistence = harness.makeController()
        let commands = RemoteCommandCoordinator(commands: MPRemoteCommandCenterAdapter())
        let context = persistence.viewContext
        let downloadConfig = URLSessionConfiguration.ephemeral
        downloadConfig.protocolClasses = [StubDownloadURLProtocol.self]
        let testDownloadManager = DownloadManager(
            sessionConfiguration: downloadConfig,
            downloadsDirectory: downloadsDirectory,
            stateStore: InMemoryDownloadStateStore(
                backing: DownloadStateStore(context: context)
            )
        )
        let model = AppShellModel(
            persistence: persistence,
            remoteCommands: commands,
            episodeAnalyzer: analyzer,
            settingsStore: makePinnedSettingsStore(),
            fixtureLibraryModeForTesting: false,
            downloadManager: testDownloadManager
        )
        model.downloadsDirectoryForTesting = downloadsDirectory
        model.injectedTranscriptForTesting = injectedTranscript
        return model
    }

    private func waitUntil(
        timeout: TimeInterval,
        pollInterval: TimeInterval = 0.02,
        _ condition: @escaping () -> Bool,
        file: StaticString = #filePath,
        line: UInt = #line
    ) async {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if condition() { return }
            try? await Task.sleep(for: .milliseconds(Int(pollInterval * 1000)))
        }
        XCTFail("Condition not met within \(timeout)s", file: file, line: line)
    }

    // MARK: - AC1: first-chunk intervals + canStartPlayback before terminal analyze

    func testPlaybackStartsAfterFirstChunkIntervalsApplied() async throws {
        let analyzer = try makeProgressiveAnalyzer()
        let audioURL = sineFixtureURL()
        let engine = PlaybackEngine(url: audioURL, title: "Progressive", artist: "PodWash QA")
        let coordinator = PlaybackCoordinator(pipeline: analyzer, engine: engine)

        let chunkReady = expectation(description: "first chunk ready")
        let prepareStart = Date()

        let prepareTask = Task {
            try await coordinator.preparePlaybackProgressive(
                episode: EpisodeIdentity(id: episodeID),
                audioURL: audioURL,
                targetWords: fullTargetSet,
                action: .mute,
                injectedTranscript: try loadTranscript(),
                onChunkReady: {
                    chunkReady.fulfill()
                }
            )
        }

        await fulfillment(of: [chunkReady], timeout: chunkReadyTolerance)
        let chunkReadyLatency = Date().timeIntervalSince(prepareStart)
        XCTAssertLessThanOrEqual(
            chunkReadyLatency,
            chunkReadyTolerance,
            "First chunk must be ready within \(chunkReadyTolerance)s"
        )

        XCTAssertTrue(coordinator.canStartPlayback, "canStartPlayback must be true after first chunk")
        XCTAssertGreaterThanOrEqual(
            coordinator.processedEnd,
            chunkSize,
            "processedEnd must reach first chunk frontier (\(chunkSize) s)"
        )
        XCTAssertGreaterThanOrEqual(coordinator.cachedIntervals.count, 1)

        let golden = try loadFirstChunkGolden()
        for interval in coordinator.cachedIntervals {
            XCTAssertLessThanOrEqual(
                interval.end,
                chunkSize,
                "Partial schedule intervals must end within first chunk (≤ \(chunkSize) s)"
            )
        }
        XCTAssertEqual(coordinator.cachedIntervals.count, golden.count)
        for (index, pair) in zip(coordinator.cachedIntervals, golden).enumerated() {
            XCTAssertEqual(pair.0.start, pair.1.start, accuracy: pipelineTolerance, "start \(index)")
            XCTAssertEqual(pair.0.end, pair.1.end, accuracy: pipelineTolerance, "end \(index)")
        }

        XCTAssertFalse(
            analyzer.analyzeReturned,
            "Full analyze must still be in flight when first chunk is playable"
        )
        XCTAssertLessThan(
            coordinator.processedEnd,
            episodeDuration,
            "Terminal processedEnd 120.0 s must not be required for first-chunk start"
        )

        _ = try await prepareTask.value
    }

    // MARK: - Slice 33 AC5: progressive start without in-flight segment-color gate

    func testPlaybackStartsAfterFirstChunkWithoutSegmentColorGate() async throws {
        // Hold first-chunk frontier long enough that play + snapshot asserts land
        // while processedEnd is still 30 (not yet 60/120).
        let analyzer = try makeProgressiveAnalyzer(
            terminalHold: .seconds(5),
            betweenSnapshotDelay: .seconds(2)
        )
        let model = makeShell(analyzer: analyzer, injectedTranscript: try loadTranscript())
        let episode = fixtureEpisode()
        try installLocalDownload(for: episode.id)
        try model.cleaningStore.setChannelCleaning(forFeedURL: feedURL, enabled: true)

        model.playEpisode(episode, podcastTitle: podcastTitle, feedURL: feedURL)
        model.toggleMiniPlayerPlayPause()

        let playDeadline = Date().addingTimeInterval(chunkReadyTolerance)
        var startedPlaying = false
        while Date() < playDeadline {
            if model.playbackCoordinator?.canStartPlayback == true,
               model.engine?.isPlaying == true {
                startedPlaying = true
                break
            }
            try await Task.sleep(for: .milliseconds(20))
        }

        XCTAssertTrue(
            startedPlaying,
            "engine.isPlaying must become true within \(chunkReadyTolerance)s of first-chunk readiness"
        )
        XCTAssertFalse(
            analyzer.analyzeReturned,
            "Playback must start before analyze() returns — segment-color AX is not a gate"
        )
        XCTAssertNil(
            model.fullPlayerTimelineColors,
            "In-flight player chrome must not require segment colors for progressive start"
        )

        guard let snapshot = model.playbackAnalysisSnapshot else {
            XCTFail("playbackAnalysisSnapshot must exist while analysis is in flight")
            return
        }
        XCTAssertGreaterThanOrEqual(snapshot.processedEnd, chunkSize)
        XCTAssertLessThan(snapshot.processedEnd, episodeDuration)
    }

    // MARK: - AC2: shell starts play before analyze returns

    func testAppShellStartsPlayBeforeFullAnalysisCompletes() async throws {
        let analyzer = try makeProgressiveAnalyzer(terminalHold: .seconds(5))
        let model = makeShell(analyzer: analyzer, injectedTranscript: try loadTranscript())
        let episode = fixtureEpisode()
        try installLocalDownload(for: episode.id)
        try model.cleaningStore.setChannelCleaning(forFeedURL: feedURL, enabled: true)

        model.playEpisode(episode, podcastTitle: podcastTitle, feedURL: feedURL)
        model.toggleMiniPlayerPlayPause()

        let playDeadline = Date().addingTimeInterval(chunkReadyTolerance)
        var startedPlaying = false
        while Date() < playDeadline {
            if model.playbackCoordinator?.canStartPlayback == true,
               model.engine?.isPlaying == true {
                startedPlaying = true
                break
            }
            try await Task.sleep(for: .milliseconds(20))
        }

        XCTAssertTrue(
            startedPlaying,
            "engine.isPlaying must become true within \(chunkReadyTolerance)s of first-chunk readiness"
        )
        XCTAssertFalse(
            analyzer.analyzeReturned,
            "Playback must start before analyze() returns (full ASR not required)"
        )
    }

    // MARK: - Task 022: intro unrelated skip catch-up during progressive prepare (AC1)

    func testIntroUnrelatedSkipFiresWhenScheduleLandsDuringIntro() async throws {
        let analyzer = makeIntroRaceProgressiveAnalyzer()
        let audioURL = longFixtureURL(duration: episodeDuration)
        let engine = PlaybackEngine(
            url: audioURL,
            title: "Intro skip race",
            artist: "PodWash QA",
            nowPlayingUpdater: NowPlayingInfoRecorder()
        )
        await waitForEngineReady(engine)

        let skipCallback = expectation(description: "intro unrelated skip callback")
        skipCallback.assertForOverFulfill = false
        var capturedSkip: CensorInterval?
        engine.onUnrelatedContentSkip = { interval, skippedSeconds in
            capturedSkip = interval
            XCTAssertEqual(
                skippedSeconds,
                self.introSkipEnd - self.introSkipStart,
                accuracy: self.pipelineTolerance,
                "Callback must report full intro skip span"
            )
            skipCallback.fulfill()
        }

        let coordinator = PlaybackCoordinator(pipeline: analyzer, engine: engine)
        let unrelated = UnrelatedContentOptions(enabled: true, action: .skip)
        let chunkReady = expectation(description: "first chunk ready without intro skip")

        let prepareTask = Task {
            try await coordinator.preparePlaybackProgressive(
                episode: EpisodeIdentity(id: episodeID),
                audioURL: audioURL,
                targetWords: [],
                action: .mute,
                unrelatedContent: unrelated,
                onChunkReady: {
                    chunkReady.fulfill()
                }
            )
        }

        await fulfillment(of: [chunkReady], timeout: chunkReadyTolerance)
        XCTAssertTrue(coordinator.canStartPlayback, "Progressive play may start before terminal analyze")
        XCTAssertFalse(
            analyzer.analyzeReturned,
            "Intro skip must land while full analyze is still in flight"
        )
        XCTAssertTrue(
            coordinator.cachedIntervals.isEmpty,
            "First chunk must not yet include the intro unrelated skip"
        )

        engine.play()

        await fulfillment(of: [skipCallback], timeout: 5)

        engine.refreshCurrentTime()
        XCTAssertGreaterThanOrEqual(
            engine.currentTime,
            introSkipEnd - skipSeekTolerance,
            "Catch-up skip must land at ≥ end − 0.1 s"
        )
        XCTAssertLessThanOrEqual(
            engine.currentTime,
            introSkipEnd,
            "Catch-up skip must not overshoot intro interval end"
        )

        guard let capturedSkip else {
            XCTFail("Expected unrelated-content skip callback payload")
            _ = try? await prepareTask.value
            return
        }
        XCTAssertEqual(capturedSkip.start, introSkipStart, accuracy: pipelineTolerance)
        XCTAssertEqual(capturedSkip.end, introSkipEnd, accuracy: pipelineTolerance)
        XCTAssertEqual(capturedSkip.source, .unrelatedContent)
        XCTAssertEqual(capturedSkip.action, .skip)

        _ = try await prepareTask.value
    }

    // MARK: - AC8: partial schedule mutes within first chunk (offline RMS)

    func testPartialScheduleMutesWithinFirstChunk() async throws {
        let spy = ASRSpyTranscriber()
        let pipeline = AnalysisPipeline(
            transcriber: spy,
            cache: IntervalCache(baseDirectory: cacheDir)
        )
        let audioURL = sineFixtureURL()
        let engine = PlaybackEngine(url: audioURL, title: "Partial mute", artist: "PodWash QA")
        let coordinator = PlaybackCoordinator(pipeline: pipeline, engine: engine)

        var firstPartial: [CensorInterval] = []
        let firstChunkReady = expectation(description: "first partial intervals applied")
        pipeline.onPartialIntervals = { intervals, snapshot in
            if snapshot.processedEnd >= AnalysisChunking.chunkSize, firstPartial.isEmpty {
                firstPartial = intervals
                firstChunkReady.fulfill()
            }
        }

        let prepareTask = Task {
            try await coordinator.preparePlaybackProgressive(
                episode: EpisodeIdentity(id: episodeID),
                audioURL: audioURL,
                targetWords: fullTargetSet,
                action: .mute,
                injectedTranscript: try self.loadTranscript()
            )
        }

        await fulfillment(of: [firstChunkReady], timeout: 5)
        _ = try await prepareTask.value

        XCTAssertFalse(firstPartial.isEmpty, "Chunk 1 must emit ≥ 1 mute interval")

        let muteInsideFirstChunk = firstPartial.first { interval in
            interval.action == .mute
                && interval.start >= 0
                && interval.end <= chunkSize
                && (interval.end - interval.start) > 2 * OfflineRenderRMS.settleMargin
        }
        guard let muteInterval = muteInsideFirstChunk else {
            XCTFail("Expected ≥ 1 mute interval wholly inside [0, \(chunkSize)) from §8 transcript")
            return
        }

        let render = try await OfflineRenderRMS.render(
            fixtureNamed: sineFixtureName,
            fixtureExtension: sineFixtureExt,
            intervals: firstPartial,
            fadeDuration: IntervalScheduler.defaultFadeDuration,
            loadedBy: type(of: self)
        )

        let interior = render.windowsFullyInside(muteInterval)
        XCTAssertFalse(interior.isEmpty, "Expected interior windows for [\(muteInterval.start), \(muteInterval.end)]")
        for window in interior {
            XCTAssertLessThan(
                window.rms,
                0.01,
                "Interior RMS \(window.rms) at [\(window.startTime), \(window.endTime)] must be < 0.01"
            )
        }
    }
}
