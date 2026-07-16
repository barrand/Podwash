//
//  AnalysisProgressChromeTests.swift
//  PodWashTests
//
//  Slice 33 — In-flight analysis progress chrome (ADR-030 §5). AC4.
//
//  Golden progress fractions hand-computed from processedEnd/duration pins
//  (30/120 = 0.25, 60/120 = 0.5) — not from implementation under test.
//
//  Until SuperSeekBarModel.analysisProgress and in-flight timeline retirement exist
//  (Engineer), this file fails to compile or assert — intended TDD red state.
//

import XCTest
@testable import PodWash

@MainActor
final class AnalysisProgressChromeTests: XCTestCase {

    private let progressTolerance = 0.02
    private let chunkReadyTolerance: TimeInterval = 0.5
    private let episodeID = "slice-33-analysis-progress"
    private let feedURL = FixtureFeed.fixtureFeedURL
    private let podcastTitle = "PodWash Fixture Feed"

    private var downloadsDirectory: URL!
    private var settingsDefaultsSuite: String!
    private var harness: PersistenceReloadHarness!

    override func setUp() async throws {
        downloadsDirectory = FileManager.default.temporaryDirectory
            .appendingPathComponent("AnalysisProgressChrome-Downloads-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: downloadsDirectory, withIntermediateDirectories: true)
        settingsDefaultsSuite = "podwash.analysis-progress.\(UUID().uuidString)"
        harness = PersistenceReloadHarness()
    }

    override func tearDown() async throws {
        try? FileManager.default.removeItem(at: downloadsDirectory)
        if let settingsDefaultsSuite {
            UserDefaults(suiteName: settingsDefaultsSuite)?.removePersistentDomain(forName: settingsDefaultsSuite)
        }
        harness = nil
        downloadsDirectory = nil
        settingsDefaultsSuite = nil
    }

    // MARK: - AC4 (pure fraction)

    func testAnalysisProgressFractionMatchesProcessedEndOverDuration() {
        XCTAssertEqual(
            SuperSeekBarModel.analysisProgress(processedEnd: 30.0, duration: 120.0),
            0.25,
            accuracy: progressTolerance,
            "First-chunk frontier 30/120 must normalize to 0.25 ± \(progressTolerance)"
        )
        XCTAssertEqual(
            SuperSeekBarModel.analysisProgress(processedEnd: 60.0, duration: 120.0),
            0.5,
            accuracy: progressTolerance,
            "Mid-run frontier 60/120 must normalize to 0.5 ± \(progressTolerance)"
        )
        XCTAssertEqual(
            SuperSeekBarModel.analysisProgress(processedEnd: 0.0, duration: 0.0),
            0.0,
            accuracy: progressTolerance,
            "Zero duration must yield progress 0"
        )
    }

    // MARK: - AC4 (shell seam — no in-flight segment colors)

    func testInFlightShowsProgressWithoutSegmentColors() async throws {
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
            "Playback must start within \(chunkReadyTolerance)s after first chunk without segment-color gate"
        )

        guard let snapshot = model.playbackAnalysisSnapshot else {
            XCTFail("playbackAnalysisSnapshot must exist while analysis is in flight")
            return
        }
        XCTAssertLessThan(
            snapshot.processedEnd,
            snapshot.episodeDuration,
            "Fixture must remain in-flight (processedEnd < duration)"
        )

        let fraction = SuperSeekBarModel.analysisProgress(
            processedEnd: snapshot.processedEnd,
            duration: snapshot.episodeDuration
        )
        XCTAssertEqual(
            fraction,
            30.0 / 120.0,
            accuracy: progressTolerance,
            "In-flight progress fraction must reflect processedEnd/duration"
        )

        XCTAssertNil(
            model.fullPlayerTimelineColors,
            "In-flight player chrome must not publish segment colors on playback.superSeekBar"
        )
        XCTAssertNil(
            model.miniPlayerTimelineColors,
            "In-flight mini player must not publish segment colors"
        )
    }

    // MARK: - Fixture helpers (ProgressivePlaybackTests pattern)

    private struct GoldenInterval: Decodable {
        let start: Double
        let end: Double
    }

    private var innerProjectDir: URL {
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
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
            forResource: "sine-300hz-5s",
            withExtension: "wav",
            subdirectory: "Fixtures/audio"
        ) ?? bundle.url(forResource: "sine-300hz-5s", withExtension: "wav") else {
            XCTFail("Missing sine-300hz-5s.wav", file: file, line: line)
            return URL(fileURLWithPath: "/dev/null")
        }
        let tempURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("podwash-analysis-progress-\(UUID().uuidString).wav")
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

    private func makeProgressiveAnalyzer(
        terminalHold: Duration = .seconds(3),
        /// Keep first-chunk frontier (30/120) visible for AC4 progress asserts.
        betweenSnapshotDelay: Duration = .seconds(2)
    ) throws -> ProgressiveSteppedTestAnalyzer {
        let partials = try [
            loadFirstChunkGolden().map {
                CensorInterval(start: $0.start, end: $0.end, action: .mute, source: .profanity)
            },
            [],
            [],
        ]
        return ProgressiveSteppedTestAnalyzer(
            snapshots: FixtureProgressivePlayback.pinnedSnapshots,
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
            title: "Analysis Progress Fixture Episode",
            pubDate: ISO8601DateFormatter().date(from: "2026-01-15T08:00:00Z")!,
            artworkURL: URL(string: "file:///fixtures/feeds/episode-0-art.png"),
            showNotes: "<p>Analysis progress chrome fixture.</p>",
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
}
