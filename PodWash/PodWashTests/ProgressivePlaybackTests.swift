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
            await MainActor.run {
                onPartialIntervals?(partial, snapshot)
            }
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
            .appendingPathComponent("podwash-progressive-\(sineFixtureName).\(sineFixtureExt)")
        try? FileManager.default.removeItem(at: tempURL)
        do {
            try FileManager.default.copyItem(at: bundledURL, to: tempURL)
        } catch {
            XCTFail("Could not copy sine fixture: \(error)", file: file, line: line)
            return bundledURL
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

    private func makeProgressiveAnalyzer(
        terminalHold: Duration = .seconds(3)
    ) throws -> ProgressiveSteppedTestAnalyzer {
        let partials = try [
            firstChunkPartialIntervals(),
            [],
            [],
        ]
        return ProgressiveSteppedTestAnalyzer(
            snapshots: pinnedSnapshots(),
            partialIntervalsBySnapshot: partials,
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
