//
//  WarmPlannerTests.swift
//  PodWashTests
//
//  ADR-029 — Warm pool: ready checks, download+analyze, retry, cap, re-aim.
//

import XCTest
@testable import PodWash

@MainActor
final class WarmPlannerTests: XCTestCase {

    private var harness: PersistenceReloadHarness!
    private var downloadsDirectory: URL!
    private var cacheDirectory: URL!
    private var feedURL: URL!

    override func setUp() async throws {
        harness = PersistenceReloadHarness()
        feedURL = URL(string: "https://example.com/warm-feed.xml")!
        downloadsDirectory = FileManager.default.temporaryDirectory
            .appendingPathComponent("warm-dl-\(UUID().uuidString)", isDirectory: true)
        cacheDirectory = FileManager.default.temporaryDirectory
            .appendingPathComponent("warm-cache-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: downloadsDirectory, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: cacheDirectory, withIntermediateDirectories: true)
        StubDownloadURLProtocol.reset()
    }

    override func tearDown() async throws {
        StubDownloadURLProtocol.reset()
        try? FileManager.default.removeItem(at: downloadsDirectory)
        try? FileManager.default.removeItem(at: cacheDirectory)
        harness = nil
    }

    // MARK: - Ready checks

    func testCleaningOffIsReadyWithoutDownloadOrCache() throws {
        let env = try makeEnv(cleaningOn: false)
        XCTAssertTrue(
            env.planner.isReadyForSeamlessPlay(episodeID: "warm-ep-1", feedURL: feedURL)
        )
    }

    func testCleaningOnRequiresLocalFileAndCacheHit() throws {
        let env = try makeEnv(cleaningOn: true)
        XCTAssertFalse(
            env.planner.isReadyForSeamlessPlay(episodeID: "warm-ep-1", feedURL: feedURL)
        )

        try installLocalDownload(for: "warm-ep-1")
        XCTAssertFalse(
            env.planner.isReadyForSeamlessPlay(episodeID: "warm-ep-1", feedURL: feedURL),
            "Local file alone is not enough while cleaning is on"
        )

        try env.cache.store(
            [],
            episodeID: "warm-ep-1",
            targetWords: env.settings.activeNormalizedTargetSet()
        )
        XCTAssertTrue(
            env.planner.isReadyForSeamlessPlay(episodeID: "warm-ep-1", feedURL: feedURL)
        )
    }

    // MARK: - Warm path

    func testReaimDownloadsAndAnalyzesIntoCache() async throws {
        let counter = CountingEpisodeAnalyzer()
        let env = try makeEnv(cleaningOn: true, analyzer: counter)

        env.planner.reaim(at: [comingUp("warm-ep-1")])

        await waitUntil(timeout: 5.0) {
            env.planner.warmedEpisodeIDs.contains("warm-ep-1")
        }

        XCTAssertEqual(counter.analyzeCallCount, 1)
        XCTAssertNotNil(env.downloadManager.localFileURL(for: "warm-ep-1"))
        XCTAssertTrue(
            env.planner.isReadyForSeamlessPlay(episodeID: "warm-ep-1", feedURL: feedURL)
        )
    }

    func testAnalyzeRetriesOnceThenSucceeds() async throws {
        let flaky = FlakyThenSucceedAnalyzer(failuresBeforeSuccess: 1)
        let env = try makeEnv(cleaningOn: true, analyzer: flaky)

        env.planner.reaim(at: [comingUp("warm-ep-1")])

        await waitUntil(timeout: 5.0) {
            env.planner.warmedEpisodeIDs.contains("warm-ep-1")
        }

        XCTAssertEqual(flaky.attemptCount, 2)
        XCTAssertTrue(
            env.planner.isReadyForSeamlessPlay(episodeID: "warm-ep-1", feedURL: feedURL)
        )
    }

    func testAnalyzeRetriesOnceThenGivesUp() async throws {
        let alwaysFail = FlakyThenSucceedAnalyzer(failuresBeforeSuccess: 99)
        let env = try makeEnv(cleaningOn: true, analyzer: alwaysFail)

        env.planner.reaim(at: [comingUp("warm-ep-1")])

        // Allow warm task to finish failing.
        try await Task.sleep(for: .milliseconds(800))

        XCTAssertEqual(alwaysFail.attemptCount, 2, "Must attempt once + one retry")
        XCTAssertFalse(env.planner.warmedEpisodeIDs.contains("warm-ep-1"))
        XCTAssertFalse(
            env.planner.isReadyForSeamlessPlay(episodeID: "warm-ep-1", feedURL: feedURL)
        )
    }

    func testReaimCancelsInFlightWarmGeneration() async throws {
        let slow = SlowEpisodeAnalyzer(delayMilliseconds: 600)
        let env = try makeEnv(cleaningOn: true, analyzer: slow)

        env.planner.reaim(at: [comingUp("warm-ep-1")])
        try await Task.sleep(for: .milliseconds(50))
        env.planner.reaim(at: [comingUp("warm-ep-2")])

        await waitUntil(timeout: 5.0) {
            env.planner.warmedEpisodeIDs.contains("warm-ep-2")
        }

        // First generation should have been abandoned before completing.
        XCTAssertFalse(
            env.planner.warmedEpisodeIDs.contains("warm-ep-1"),
            "Cancelled generation must not commit warm-ep-1"
        )
        XCTAssertTrue(env.planner.warmedEpisodeIDs.contains("warm-ep-2"))
    }

    func testWarmCapStopsAtFiveAnalyzedEpisodes() async throws {
        let counter = CountingEpisodeAnalyzer()
        let env = try makeEnv(cleaningOn: true, analyzer: counter, episodeCount: 7)

        // Two reaims of 3 + 3 would be 6 without a cap; cap must keep ≤ 5.
        let batch1 = (1...3).map { comingUp("warm-ep-\($0)") }
        let batch2 = (4...6).map { comingUp("warm-ep-\($0)") }

        env.planner.reaim(at: batch1)
        await waitUntil(timeout: 8.0) {
            env.planner.warmedEpisodeIDs.count >= 3
        }

        env.planner.reaim(at: batch2)
        await waitUntil(timeout: 8.0) {
            Set(["warm-ep-4", "warm-ep-5", "warm-ep-6"]).isSubset(of: env.planner.warmedEpisodeIDs)
                || env.planner.warmedEpisodeIDs.count >= WarmPlanner.warmCap
        }

        // Allow eviction loop to settle.
        try await Task.sleep(for: .milliseconds(200))
        XCTAssertLessThanOrEqual(env.planner.warmedEpisodeIDs.count, WarmPlanner.warmCap)
    }

    // MARK: - Helpers

    private struct Env {
        let planner: WarmPlanner
        let downloadManager: DownloadManager
        let cache: IntervalCache
        let settings: SettingsStore
        let podcastStore: PodcastStore
        let cleaningStore: CleaningToggleStore
    }

    private func makeEnv(
        cleaningOn: Bool,
        analyzer: any EpisodeAnalyzing = InstantEpisodeAnalyzer(),
        episodeCount: Int = 2
    ) throws -> Env {
        let persistence = harness.makeController()
        let context = persistence.viewContext
        let podcastStore = PodcastStore(context: context)
        let cleaningStore = CleaningToggleStore(context: context)

        var episodes: [Episode] = []
        for i in 1...episodeCount {
            episodes.append(
                Episode(
                    id: "warm-ep-\(i)",
                    title: "Warm \(i)",
                    pubDate: Date(timeIntervalSince1970: TimeInterval(i)),
                    artworkURL: nil,
                    showNotes: nil,
                    audioURL: URL(string: "https://fixture.podwash.tests/audio/warm-\(i).m4a")
                )
            )
        }
        let feed = PodcastFeed(
            title: "Warm Show",
            artworkURL: nil,
            description: nil,
            episodes: episodes
        )
        try podcastStore.save(feed, feedURL: feedURL)
        try cleaningStore.setChannelCleaning(forFeedURL: feedURL, enabled: cleaningOn)

        let suite = "com.podwash.tests.warm.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defaults.removePersistentDomain(forName: suite)
        let settings = SettingsStore(userDefaults: defaults)

        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [StubDownloadURLProtocol.self]
        let downloadManager = DownloadManager(
            sessionConfiguration: config,
            downloadsDirectory: downloadsDirectory,
            stateStore: InMemoryDownloadStateStore(
                backing: DownloadStateStore(context: context)
            )
        )
        let cache = IntervalCache(baseDirectory: cacheDirectory, asrModelPin: "test-pin")

        let planner = WarmPlanner(
            downloadManager: downloadManager,
            analyzer: analyzer,
            settingsStore: settings,
            intervalCache: cache,
            cleaningStore: cleaningStore,
            podcastStore: podcastStore
        )
        return Env(
            planner: planner,
            downloadManager: downloadManager,
            cache: cache,
            settings: settings,
            podcastStore: podcastStore,
            cleaningStore: cleaningStore
        )
    }

    private func comingUp(_ episodeID: String) -> ComingUpItem {
        ComingUpItem(
            episodeID: episodeID,
            episodeTitle: episodeID,
            podcastTitle: "Warm Show",
            feedURL: feedURL,
            isBinge: false
        )
    }

    private func installLocalDownload(for episodeID: String) throws {
        let destination = DownloadPaths.localFileURL(
            episodeID: episodeID,
            downloadsDirectory: downloadsDirectory
        )
        try Data(repeating: 0xAB, count: 64).write(to: destination)
    }

    private func waitUntil(
        timeout: TimeInterval,
        pollInterval: TimeInterval = 0.05,
        _ condition: @escaping () -> Bool
    ) async {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if condition() { return }
            try? await Task.sleep(for: .milliseconds(Int(pollInterval * 1000)))
        }
        XCTFail("Condition not met within \(timeout)s")
    }
}

// MARK: - Analyzer doubles

@MainActor
final class CountingEpisodeAnalyzer: EpisodeAnalyzing, @unchecked Sendable {
    private(set) var analyzeCallCount = 0
    nonisolated(unsafe) var onPartialIntervals: AnalysisPartialIntervalsHandler?
    nonisolated deinit {}

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
        analyzeCallCount += 1
        return []
    }
}

@MainActor
final class FlakyThenSucceedAnalyzer: EpisodeAnalyzing, @unchecked Sendable {
    private let failuresBeforeSuccess: Int
    private(set) var attemptCount = 0
    nonisolated(unsafe) var onPartialIntervals: AnalysisPartialIntervalsHandler?
    nonisolated deinit {}

    init(failuresBeforeSuccess: Int) {
        self.failuresBeforeSuccess = failuresBeforeSuccess
    }

    enum FlakyError: Error { case intentional }

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
        attemptCount += 1
        if attemptCount <= failuresBeforeSuccess {
            throw FlakyError.intentional
        }
        return []
    }
}

@MainActor
final class SlowEpisodeAnalyzer: EpisodeAnalyzing, @unchecked Sendable {
    private let delayMilliseconds: Int
    nonisolated(unsafe) var onPartialIntervals: AnalysisPartialIntervalsHandler?
    nonisolated deinit {}

    init(delayMilliseconds: Int) {
        self.delayMilliseconds = delayMilliseconds
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
        try await Task.sleep(for: .milliseconds(delayMilliseconds))
        return []
    }
}
