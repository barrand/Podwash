//
//  ProductionAnalysisWiringTests.swift
//  PodWashTests
//
//  Slice 24 — Production analysis wiring (ADR-020). AC1–AC8.
//
//  Fixture provenance:
//  - transcripts/spec-section8.input.json + analysis/e2e_intervals.json — hand-computed
//    per matching-spec §8 (Slice 07; independent of pipeline output).
//  - audio/sine-300hz-5s.wav — synthetic sine for offline audioMix boundary asserts
//    (Slice 08 pattern).
//
//  Until WhisperModelLocator, ProductionAnalyzerFactory, and AppShellModel inject
//  seams exist (Engineer, slice-24 implement), this file fails to compile — intended
//  TDD red state.
//

import AVFoundation
import XCTest
@testable import PodWash

@MainActor
final class ProductionAnalysisWiringTests: XCTestCase {

    private let episodeID = "fixture-spec-section8"
    private let podcastTitle = "PodWash Fixture Feed"
    private let feedURL = FixtureFeed.fixtureFeedURL
    private let pipelineTolerance = 0.0005
    private let boundaryTolerance = 0.001
    private let sineFixtureName = "sine-300hz-5s"
    private let sineFixtureExt = "wav"
    private let modelSetupMessage =
        "Run scripts/setup-asr-models.sh and ensure the app target copies openai_whisper-tiny.en per ADR-020."

    private var harness: PersistenceReloadHarness!
    private var downloadsDirectory: URL!
    private var cacheDir: URL!
    private var settingsDefaultsSuite: String!
    private var pipelineSpy: PipelineAnalyzeSpy!

    private var innerProjectDir: URL {
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
    }

    override func setUp() async throws {
        harness = PersistenceReloadHarness()
        downloadsDirectory = FileManager.default.temporaryDirectory
            .appendingPathComponent("ProductionWiring-Downloads-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: downloadsDirectory, withIntermediateDirectories: true)

        cacheDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("ProductionWiring-Cache-\(UUID().uuidString)", isDirectory: true)

        settingsDefaultsSuite = "podwash.production-wiring.\(UUID().uuidString)"

        let spyTranscriber = ASRSpyTranscriber()
        let pipeline = AnalysisPipeline(
            transcriber: spyTranscriber,
            cache: IntervalCache(baseDirectory: cacheDir)
        )
        pipelineSpy = PipelineAnalyzeSpy(inner: pipeline)
    }

    override func tearDown() async throws {
        try? IntervalCache(baseDirectory: cacheDir).clear()
        if let downloadsDirectory {
            try? FileManager.default.removeItem(at: downloadsDirectory)
        }
        if let settingsDefaultsSuite {
            UserDefaults(suiteName: settingsDefaultsSuite)?.removePersistentDomain(forName: settingsDefaultsSuite)
        }
        pipelineSpy = nil
        cacheDir = nil
        downloadsDirectory = nil
        settingsDefaultsSuite = nil
        harness = nil
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

    private func loadGoldenE2E() throws -> [GoldenInterval] {
        try JSONDecoder().decode(
            [GoldenInterval].self,
            from: try fixtureData("e2e_intervals", subdirectory: "analysis")
        )
    }

    private func makePinnedSettingsStore() -> SettingsStore {
        guard let defaults = UserDefaults(suiteName: settingsDefaultsSuite!) else {
            XCTFail("Could not create isolated UserDefaults suite for pinned target set")
            return SettingsStore()
        }
        defaults.removePersistentDomain(forName: settingsDefaultsSuite!)
        let store = SettingsStore(userDefaults: defaults)
        for categoryID in WordCategories.allIDs {
            store.setCategoryEnabled(categoryID, false)
        }
        store.addCustomWord("shit")
        store.addCustomWord("damn")
        let pinned: Set<String> = ["shit", "damn"]
        XCTAssertEqual(
            store.activeNormalizedTargetSet(),
            pinned,
            "Precondition: pinned settings store must expose exactly {shit, damn} for AC4 spy assert"
        )
        return store
    }

    private func fixtureEpisode() -> Episode {
        Episode(
            id: episodeID,
            title: "Alpha Signal — Pilot Launch",
            pubDate: ISO8601DateFormatter().date(from: "2026-01-15T08:00:00Z")!,
            artworkURL: URL(string: "file:///fixtures/feeds/episode-0-art.png"),
            showNotes: "<p>Welcome to the pilot.</p>",
            audioURL: URL(string: "https://fixture.podwash.tests/audio/alpha.m4a")
        )
    }

    private func bundledSineURL(file: StaticString = #filePath, line: UInt = #line) -> URL {
        let bundle = Bundle(for: type(of: self))
        guard let bundledURL = bundle.url(
            forResource: sineFixtureName,
            withExtension: sineFixtureExt,
            subdirectory: "Fixtures/audio"
        ) ?? bundle.url(forResource: sineFixtureName, withExtension: sineFixtureExt) else {
            XCTFail("Missing \(sineFixtureName).\(sineFixtureExt)", file: file, line: line)
            return URL(fileURLWithPath: "/dev/null")
        }
        return bundledURL
    }

    /// Copies bundled sine WAV into the injectable downloads directory as the episode local file.
    private func installLocalDownload(for episodeID: String) throws {
        let source = bundledSineURL()
        let destination = DownloadPaths.localFileURL(
            episodeID: episodeID,
            downloadsDirectory: downloadsDirectory
        )
        try? FileManager.default.removeItem(at: destination)
        try FileManager.default.copyItem(at: source, to: destination)
        XCTAssertTrue(
            FileManager.default.fileExists(atPath: destination.path),
            "Precondition: local download stand-in must exist for local-file gate"
        )
    }

    private func makeShell(
        useInjectedSpy: Bool = true,
        settingsStore: SettingsStore? = nil,
        fixtureLibraryMode: Bool? = false,
        injectedTranscript: [TimedWord]? = nil
    ) -> AppShellModel {
        let persistence = harness.makeController()
        let commands = RemoteCommandCoordinator(commands: MPRemoteCommandCenterAdapter())
        let analyzer: (any EpisodeAnalyzing)? = useInjectedSpy ? pipelineSpy : nil
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
            settingsStore: settingsStore ?? makePinnedSettingsStore(),
            fixtureLibraryModeForTesting: fixtureLibraryMode,
            downloadManager: testDownloadManager
        )
        model.downloadsDirectoryForTesting = downloadsDirectory
        model.injectedTranscriptForTesting = injectedTranscript
        return model
    }

    private func waitUntil(
        timeout: TimeInterval = 5,
        pollInterval: TimeInterval = 0.05,
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

    private func isDownloading(_ state: DownloadState) -> Bool {
        if case .downloading = state { return true }
        return false
    }

    private func enginePlaybackURL(from model: AppShellModel) -> URL? {
        guard let engine = model.engine,
              let asset = engine.avPlayer.currentItem?.asset as? AVURLAsset else {
            return nil
        }
        return asset.url
    }

    private func assertEngineDoesNotStreamRemote(
        from model: AppShellModel,
        file: StaticString = #filePath,
        line: UInt = #line
    ) {
        guard let url = enginePlaybackURL(from: model) else { return }
        let scheme = url.scheme?.lowercased()
        XCTAssertFalse(
            scheme == "http" || scheme == "https",
            "Engine must not assign a remote stream URL before download completes; got \(url.absoluteString)",
            file: file,
            line: line
        )
    }

    private func withStubDownloadTransport(
        chunkDelay: TimeInterval = 0.2,
        _ body: () async throws -> Void
    ) async rethrows {
        StubDownloadURLProtocol.reset()
        StubDownloadURLProtocol.chunkDelay = chunkDelay
        URLProtocol.registerClass(StubDownloadURLProtocol.self)
        defer {
            StubDownloadURLProtocol.reset()
            URLProtocol.unregisterClass(StubDownloadURLProtocol.self)
        }
        try await body()
    }

    private func removeProductionDownload(for episodeID: String) {
        let localURL = DownloadPaths.localFileURL(
            episodeID: episodeID,
            downloadsDirectory: DownloadPaths.productionDownloadsDirectory
        )
        try? FileManager.default.removeItem(at: localURL)
    }

    private func assertBoundary(
        _ value: TimeInterval,
        near expected: TimeInterval,
        label: String,
        file: StaticString = #filePath,
        line: UInt = #line
    ) {
        XCTAssertEqual(value, expected, accuracy: boundaryTolerance, "\(label)", file: file, line: line)
    }

    // MARK: - AC1: bundled Whisper model folder completeness

    func testBundledWhisperModelFolderIsComplete() throws {
        let folder: URL
        do {
            folder = try WhisperModelLocator.resolvedModelFolder(in: .main)
        } catch {
            XCTFail(
                "Bundled Whisper model folder missing or incomplete: \(error). \(modelSetupMessage)"
            )
            return
        }

        let status = WhisperModelLocator.requiredSubdirectories(in: folder)
        for name in WhisperModelLocator.requiredMLModelcNames {
            guard status[name] == true else {
                XCTFail(
                    "Missing required model subdirectory '\(name)' in \(folder.path). \(modelSetupMessage)"
                )
                continue
            }
        }
    }

    // MARK: - AC2: production factory is not InstantEpisodeAnalyzer

    func testProductionAnalyzerIsNotInstantStub() throws {
        let pipeline = try ProductionAnalyzerFactory.makeProductionPipeline()
        XCTAssertFalse(
            pipeline is InstantEpisodeAnalyzer,
            "makeProductionPipeline must return AnalysisPipeline, not InstantEpisodeAnalyzer"
        )

        let defaultAnalyzer = AppShellModel.makeDefaultAnalyzer(fixtureLibraryMode: false)
        XCTAssertFalse(
            defaultAnalyzer is InstantEpisodeAnalyzer,
            "makeDefaultAnalyzer(fixtureLibraryMode: false) must not return InstantEpisodeAnalyzer"
        )
    }

    // MARK: - AC3: cleaning disabled skips analysis

    func testPlayEpisodeSkipsAnalysisWhenCleaningOff() async throws {
        let model = makeShell()
        let episode = fixtureEpisode()
        try installLocalDownload(for: episode.id)

        try model.cleaningStore.setEpisodeCleaning(episode.id, enabled: false)
        try model.cleaningStore.setChannelCleaning(forFeedURL: feedURL, enabled: false)

        model.playEpisode(episode, podcastTitle: podcastTitle, feedURL: feedURL)

        await waitUntil { model.playbackCoordinator != nil }
        try await Task.sleep(for: .milliseconds(300))

        XCTAssertEqual(pipelineSpy.analyzeCallCount, 0, "Cleaning off must not invoke analyze")
        XCTAssertEqual(model.playbackCoordinator?.cachedIntervals.count ?? 0, 0)
    }

    // MARK: - AC4: channel cleaning + local file + injected §8 transcript

    func testPlayEpisodePreparesIntervalsWithSettingsTargetSet() async throws {
        let settings = makePinnedSettingsStore()
        let transcript = try loadTranscript()
        let golden = try loadGoldenE2E()
        let model = makeShell(settingsStore: settings, injectedTranscript: transcript)
        let episode = fixtureEpisode()
        try installLocalDownload(for: episode.id)

        try model.cleaningStore.setEpisodeCleaning(episode.id, enabled: false)
        try model.cleaningStore.setChannelCleaning(forFeedURL: feedURL, enabled: true)

        model.playEpisode(episode, podcastTitle: podcastTitle, feedURL: feedURL)

        await waitUntil { self.pipelineSpy.analyzeCallCount >= 1 }

        XCTAssertEqual(pipelineSpy.analyzeCallCount, 1)
        XCTAssertEqual(
            pipelineSpy.lastTargetWords,
            settings.activeNormalizedTargetSet(),
            "preparePlayback must pass settingsStore.activeNormalizedTargetSet()"
        )

        let cached = model.playbackCoordinator?.cachedIntervals ?? []
        XCTAssertEqual(cached.count, golden.count)
        for (index, pair) in zip(cached, golden).enumerated() {
            XCTAssertEqual(pair.0.start, pair.1.start, accuracy: pipelineTolerance, "start \(index)")
            XCTAssertEqual(pair.0.end, pair.1.end, accuracy: pipelineTolerance, "end \(index)")
        }

        await waitUntil { model.playbackAnalysisSnapshot != nil }
        let snapshot = model.playbackAnalysisSnapshot
        XCTAssertNotNil(snapshot)
        XCTAssertGreaterThan(snapshot?.episodeDuration ?? 0, 0)
        let colors = AnalysisTimelineModel.segmentColors(snapshot: snapshot!)
        XCTAssertEqual(colors.count, AnalysisTimelineModel.defaultSegmentCount)
        XCTAssertFalse(colors.allSatisfy { $0 == .grey }, "Terminal snapshot should color segments after analysis")
    }

    func testPlayQueuesUntilAnalysisCompletes() async throws {
        let model = makeShell(injectedTranscript: try loadTranscript())
        let episode = fixtureEpisode()
        try installLocalDownload(for: episode.id)
        try model.cleaningStore.setChannelCleaning(forFeedURL: feedURL, enabled: true)

        model.playEpisode(episode, podcastTitle: podcastTitle, feedURL: feedURL)

        XCTAssertTrue(model.isPreparingPlayback, "Cleaning play path should enter preparing state")
        XCTAssertFalse(model.engine?.isPlaying ?? true, "Playback must not start before analysis")

        model.toggleMiniPlayerPlayPause()
        XCTAssertFalse(model.engine?.isPlaying ?? true, "Play tap during analysis must queue, not start")

        await waitUntil { !model.isPreparingPlayback }
        XCTAssertTrue(model.engine?.isPlaying ?? false, "Queued play should start after analysis completes")
        XCTAssertNotNil(model.playbackAnalysisSnapshot)
    }

    // MARK: - AC5: mute ramp boundaries after prepare

    func testPlayEpisodeAppliesMuteScheduleToEngine() async throws {
        let transcript = try loadTranscript()
        let golden = try loadGoldenE2E()
        let model = makeShell(injectedTranscript: transcript)
        let episode = fixtureEpisode()
        try installLocalDownload(for: episode.id)

        try model.cleaningStore.setEpisodeCleaning(episode.id, enabled: false)
        try model.cleaningStore.setChannelCleaning(forFeedURL: feedURL, enabled: true)

        model.playEpisode(episode, podcastTitle: podcastTitle, feedURL: feedURL)

        await waitUntil {
            (model.playbackCoordinator?.cachedIntervals.count ?? 0) == golden.count
        }

        guard let engine = model.engine,
              let playerItem = engine.avPlayer.currentItem,
              let mix = playerItem.audioMix else {
            XCTFail("Expected PlaybackEngine with non-nil audioMix after prepare with mute action")
            return
        }

        let audioURL = (playerItem.asset as? AVURLAsset)?.url ?? bundledSineURL()
        let duration = try await AVURLAsset(url: audioURL).load(.duration).seconds
        let onsets = AudioMixRampInspector.muteOnsetBoundaries(from: mix, duration: duration)
        let releases = AudioMixRampInspector.muteReleaseBoundaries(from: mix, duration: duration)

        XCTAssertEqual(onsets.count, golden.count, "onset ramp count")
        XCTAssertEqual(releases.count, golden.count, "release ramp count")

        for expected in golden {
            guard let onset = onsets.min(by: { abs($0 - expected.start) < abs($1 - expected.start) }) else {
                XCTFail("No onset boundary for start \(expected.start)")
                continue
            }
            assertBoundary(onset, near: expected.start, label: "onset at start \(expected.start)")

            guard let release = releases.min(by: { abs($0 - expected.end) < abs($1 - expected.end) }) else {
                XCTFail("No release boundary for end \(expected.end)")
                continue
            }
            assertBoundary(release, near: expected.end, label: "release at end \(expected.end)")
        }
    }

    // MARK: - AC6: channel-only cleaning gate

    func testPlayEpisodeRunsAnalysisWhenChannelOnEpisodeFlagOff() async throws {
        let model = makeShell(injectedTranscript: try loadTranscript())
        let episode = fixtureEpisode()
        try installLocalDownload(for: episode.id)

        try model.cleaningStore.setEpisodeCleaning(episode.id, enabled: false)
        try model.cleaningStore.setChannelCleaning(forFeedURL: feedURL, enabled: true)

        model.playEpisode(episode, podcastTitle: podcastTitle, feedURL: feedURL)

        await waitUntil { self.pipelineSpy.analyzeCallCount >= 1 }
        XCTAssertEqual(pipelineSpy.analyzeCallCount, 1, "Channel cleaning alone must trigger analyze once")
    }

    func testPlayEpisodeSkipsAnalysisWhenChannelOffEvenIfEpisodeFlagOn() async throws {
        let model = makeShell(injectedTranscript: try loadTranscript())
        let episode = fixtureEpisode()
        try installLocalDownload(for: episode.id)

        try model.cleaningStore.setEpisodeCleaning(episode.id, enabled: true)
        try model.cleaningStore.setChannelCleaning(forFeedURL: feedURL, enabled: false)

        model.playEpisode(episode, podcastTitle: podcastTitle, feedURL: feedURL)

        await waitUntil { model.playbackCoordinator != nil }
        try await Task.sleep(for: .milliseconds(300))

        XCTAssertEqual(
            pipelineSpy.analyzeCallCount,
            0,
            "Channel off must skip analyze even when a stale episode cleaning flag remains on"
        )
        XCTAssertEqual(model.playbackCoordinator?.cachedIntervals.count ?? 0, 0)
    }

    // MARK: - Task 012: download-before-play when channel cleaning on

    func testPlayEpisodeDownloadsInsteadOfStreamingWhenChannelCleaningOn() async throws {
        try await withStubDownloadTransport { [self] in
            let model = makeShell(
                fixtureLibraryMode: false,
                injectedTranscript: try loadTranscript()
            )
            let episode = fixtureEpisode()
            removeProductionDownload(for: episode.id)

            try model.cleaningStore.setChannelCleaning(forFeedURL: feedURL, enabled: true)

            model.playEpisode(episode, podcastTitle: podcastTitle, feedURL: feedURL)

            assertEngineDoesNotStreamRemote(from: model)
            XCTAssertNil(
                model.engine,
                "playEpisode must not create PlaybackEngine before download completes when channel cleaning is on"
            )

            await waitUntil(timeout: 2) {
                self.isDownloading(model.downloadManager.state(for: episode.id))
                    || model.downloadManager.state(for: episode.id) == .downloaded
            }
            if isDownloading(model.downloadManager.state(for: episode.id)) {
                assertEngineDoesNotStreamRemote(from: model)
                XCTAssertNil(
                    model.engine,
                    "PlaybackEngine must stay absent while download-before-play is in flight"
                )
            }
            XCTAssertTrue(
                isDownloading(model.downloadManager.state(for: episode.id))
                    || model.downloadManager.state(for: episode.id) == .downloaded,
                "playEpisode must start a download when channel cleaning is on and no local file exists"
            )
        }
    }

    func testPlayEpisodeStreamsWhenChannelCleaningOffAndNoLocalFile() async throws {
        let model = makeShell(fixtureLibraryMode: false)
        let episode = fixtureEpisode()
        removeProductionDownload(for: episode.id)

        try model.cleaningStore.setChannelCleaning(forFeedURL: feedURL, enabled: false)

        model.playEpisode(episode, podcastTitle: podcastTitle, feedURL: feedURL)

        await waitUntil { model.engine != nil }

        let playbackURL = enginePlaybackURL(from: model)
        XCTAssertEqual(playbackURL?.scheme?.lowercased(), "https")
        XCTAssertEqual(
            episode.audioURL?.absoluteString,
            playbackURL?.absoluteString,
            "Cleaning off must stream the remote enclosure URL when no sandbox file exists"
        )
        XCTAssertEqual(
            model.downloadManager.state(for: episode.id),
            .notDownloaded,
            "Cleaning off must not invoke download on tap-to-play"
        )
    }

    func testPlayEpisodeAnalyzesAfterDownloadCompletesWhenChannelCleaningOn() async throws {
        try await withStubDownloadTransport { [self] in
            let model = makeShell(
                fixtureLibraryMode: false,
                injectedTranscript: try loadTranscript()
            )
            let episode = fixtureEpisode()
            removeProductionDownload(for: episode.id)

            try model.cleaningStore.setChannelCleaning(forFeedURL: feedURL, enabled: true)

            model.playEpisode(episode, podcastTitle: podcastTitle, feedURL: feedURL)

            await waitUntil(timeout: 10) {
                let playbackURL = self.enginePlaybackURL(from: model)
                return playbackURL?.isFileURL == true
                    && FileManager.default.fileExists(atPath: playbackURL?.path ?? "")
                    && self.pipelineSpy.analyzeCallCount >= 1
            }

            let playbackURL = try XCTUnwrap(enginePlaybackURL(from: model))
            XCTAssertTrue(playbackURL.isFileURL)
            XCTAssertTrue(FileManager.default.fileExists(atPath: playbackURL.path))
            XCTAssertEqual(
                pipelineSpy.analyzeCallCount,
                1,
                "Local-file gate must invoke analyze exactly once after download completes"
            )
        }
    }

    // MARK: - AC7: streaming-only URL skips analysis even when cleaning is on

    func testStreamingURLSkipsAnalysisEvenWhenCleaningOn() async throws {
        let model = makeShell(injectedTranscript: try loadTranscript())
        let episode = fixtureEpisode()
        // No local download — resolver must return remote enclosure URL only.

        try model.cleaningStore.setEpisodeCleaning(episode.id, enabled: false)
        try model.cleaningStore.setChannelCleaning(forFeedURL: feedURL, enabled: true)

        model.playEpisode(episode, podcastTitle: podcastTitle, feedURL: feedURL)

        await waitUntil { model.playbackCoordinator != nil }
        try await Task.sleep(for: .milliseconds(300))

        XCTAssertEqual(
            pipelineSpy.analyzeCallCount,
            0,
            "Streaming-only audio must not invoke analyze (ADR-008 local-file gate)"
        )
    }

    // MARK: - AC8: fixture library mode skips prepare even when cleaning is on

    func testFixtureLibraryModeKeepsInstantAnalyzer() async throws {
        XCTAssertTrue(
            AppShellModel.makeDefaultAnalyzer(fixtureLibraryMode: true) is InstantEpisodeAnalyzer,
            "Factory must return InstantEpisodeAnalyzer when fixtureLibraryMode is true"
        )

        let model = makeShell(
            useInjectedSpy: true,
            fixtureLibraryMode: true,
            injectedTranscript: try loadTranscript()
        )
        XCTAssertTrue(
            model.isFixtureLibraryMode,
            "fixtureLibraryModeForTesting = true must drive isFixtureLibraryMode"
        )

        let episode = fixtureEpisode()
        try installLocalDownload(for: episode.id)
        try model.cleaningStore.setEpisodeCleaning(episode.id, enabled: false)
        try model.cleaningStore.setChannelCleaning(forFeedURL: feedURL, enabled: true)

        model.playEpisode(episode, podcastTitle: podcastTitle, feedURL: feedURL)

        await waitUntil { model.playbackCoordinator != nil }
        try await Task.sleep(for: .milliseconds(300))

        XCTAssertEqual(
            pipelineSpy.analyzeCallCount,
            0,
            "Injected spy must not be called — fixture mode skips preparePlayback even when channel cleaning is on and local file exists"
        )
        XCTAssertEqual(
            model.playbackCoordinator?.cachedIntervals.count ?? 0,
            0,
            "Fixture mode must leave cachedIntervals empty when preparePlayback is skipped"
        )
    }
}
