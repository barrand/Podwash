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

    func testPreparationPreferencesStoreReleasesWithoutTaskLocalDeinitAbort() {
        let suite = "com.podwash.tests.preparation-preferences.\(UUID().uuidString)"
        autoreleasepool {
            let defaults = UserDefaults(suiteName: suite)!
            defaults.removePersistentDomain(forName: suite)
            let store = EpisodePreparationPreferencesStore(defaults: defaults)

            store.addExplicit("episode-1")
            XCTAssertEqual(store.preferences.explicitEpisodeIDs, Set(["episode-1"]))
        }
        UserDefaults.standard.removePersistentDomain(forName: suite)
    }

    // MARK: - Ready checks

    func testCleaningOffIsReadyWithoutDownloadOrCache() throws {
        let env = try makeEnv(cleaningOn: false)
        XCTAssertTrue(
            env.planner.isReadyForSeamlessPlay(episodeID: "warm-ep-1", feedURL: feedURL)
        )
        XCTAssertFalse(
            env.planner.isReadyOffline(episodeID: "warm-ep-1", feedURL: feedURL),
            "Ready to Play must still require a local file when cleaning is off"
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
            Set(env.planner.allJobs.filter { $0.stage == .ready }.map { $0.episodeID }).contains("warm-ep-1")
        }

        XCTAssertEqual(counter.analyzeCallCount, 1)
        XCTAssertNotNil(env.downloadManager.localFileURL(for: "warm-ep-1"))
        XCTAssertTrue(
            env.planner.isReadyForSeamlessPlay(episodeID: "warm-ep-1", feedURL: feedURL)
        )
    }

    func testCleaningOffStillDownloadsBeforeMarkingReadyOffline() async throws {
        let counter = CountingEpisodeAnalyzer()
        let env = try makeEnv(cleaningOn: false, analyzer: counter)

        env.planner.reaim(at: [comingUp("warm-ep-1")])

        await waitUntil(timeout: 5.0) {
            env.planner.job(for: "warm-ep-1")?.stage == .ready
        }

        XCTAssertNotNil(env.downloadManager.localFileURL(for: "warm-ep-1"))
        XCTAssertTrue(env.planner.isReadyOffline(episodeID: "warm-ep-1", feedURL: feedURL))
        XCTAssertEqual(counter.analyzeCallCount, 0, "Cleaning off should skip analysis, not the local download.")
    }

    func testReplayReanalyzesExistingAudioEvenWhenCleaningIsOff() async throws {
        let counter = CountingEpisodeAnalyzer()
        let env = try makeEnv(cleaningOn: false, analyzer: counter)
        try installLocalDownload(for: "warm-ep-1")

        env.planner.reaim(
            replayEpisodeID: "warm-ep-1",
            manualQueueIDs: [],
            predicted: []
        )

        await waitUntil(timeout: 5.0) {
            env.planner.job(for: "warm-ep-1")?.stage == .ready
        }

        XCTAssertEqual(counter.analyzeCallCount, 1)
        XCTAssertEqual(
            StubDownloadURLProtocol.chunksDelivered,
            0,
            "Replay should reuse an existing audio download instead of downloading it again."
        )
    }

    func testWarmTargetPreparesExactlyTwoAutomaticEpisodes() async throws {
        let env = try makeEnv(cleaningOn: true, episodeCount: 4)
        let candidates = (1...4).map { comingUp("warm-ep-\($0)") }

        env.planner.reaim(at: candidates)

        await waitUntil(timeout: 8.0) {
            Set(env.planner.allJobs.filter { $0.stage == .ready }.map { $0.episodeID }).count == WarmPlanner.peekCount
        }

        XCTAssertEqual(WarmPlanner.peekCount, 2)
        XCTAssertEqual(
            Set(env.planner.allJobs.filter { $0.stage == .ready }.map { $0.episodeID }),
            Set(candidates.prefix(2).map(\.episodeID)),
            "only the first two automatic choices should be prepared"
        )
    }

    func testAnalyzeRetriesOnceThenSucceeds() async throws {
        let flaky = FlakyThenSucceedAnalyzer(failuresBeforeSuccess: 1)
        let env = try makeEnv(cleaningOn: true, analyzer: flaky)

        env.planner.reaim(at: [comingUp("warm-ep-1")])

        await waitUntil(timeout: 5.0) {
            Set(env.planner.allJobs.filter { $0.stage == .ready }.map { $0.episodeID }).contains("warm-ep-1")
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
        XCTAssertFalse(Set(env.planner.allJobs.filter { $0.stage == .ready }.map { $0.episodeID }).contains("warm-ep-1"))
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
            Set(env.planner.allJobs.filter { $0.stage == .ready }.map { $0.episodeID }).contains("warm-ep-2")
        }

        // First generation should have been abandoned before completing.
        XCTAssertFalse(
            Set(env.planner.allJobs.filter { $0.stage == .ready }.map { $0.episodeID }).contains("warm-ep-1"),
            "Cancelled generation must not commit warm-ep-1"
        )
        XCTAssertTrue(Set(env.planner.allJobs.filter { $0.stage == .ready }.map { $0.episodeID }).contains("warm-ep-2"))
    }

    func testLongCandidateListOnlyPreparesItsFirstTwoChoices() async throws {
        let counter = CountingEpisodeAnalyzer()
        let env = try makeEnv(cleaningOn: true, analyzer: counter, episodeCount: 7)

        let candidates = (1...7).map { comingUp("warm-ep-\($0)") }

        env.planner.reaim(at: candidates)
        await waitUntil(timeout: 8.0) {
            Set(env.planner.allJobs.filter { $0.stage == .ready }.map { $0.episodeID }).count == WarmPlanner.peekCount
        }

        XCTAssertEqual(Set(env.planner.allJobs.filter { $0.stage == .ready }.map { $0.episodeID }), Set(["warm-ep-1", "warm-ep-2"]))
        XCTAssertEqual(counter.analyzeCallCount, 2)
    }

    // MARK: - Helpers

    func testExplicitIntentReconstructsWithoutQueueAndRetiresOnlyWhenReady() async throws {
        let env = try makeEnv(cleaningOn: true)
        env.settings.autoDownloadEnabled = false
        env.planner.requestExplicitPreparation(episodeID: "warm-ep-1")
        await env.planner.quiesce()
        let preferences = EpisodePreparationPreferencesStore(defaults: env.defaults)
        XCTAssertTrue(preferences.preferences.explicitEpisodeIDs.contains("warm-ep-1"))
        let restored = WarmPlanner(downloadManager: env.downloadManager, analyzer: InstantEpisodeAnalyzer(),
            settingsStore: env.settings, intervalCache: env.cache, cleaningStore: env.cleaningStore,
            podcastStore: env.podcastStore, jobStore: AnalysisJobStore(defaults: env.defaults),
            preferencesStore: preferences)
        restored.reaim(at: [])
        restored.reconcilePersistedJobs(requestedEpisodeIDs: restored.ownedEpisodeIDs)
        await waitUntil(timeout: 5) { restored.job(for: "warm-ep-1")?.stage == .ready }
        XCTAssertFalse(preferences.preferences.explicitEpisodeIDs.contains("warm-ep-1"))
        XCTAssertTrue(restored.isReadyOffline(episodeID: "warm-ep-1", feedURL: feedURL))
        restored.cancel()
    }

    func testChangedTargetsReprepareTheSameAutomaticWindow() async throws {
        let counter = CountingEpisodeAnalyzer()
        let env = try makeEnv(cleaningOn: true, analyzer: counter)
        let selection = [comingUp("warm-ep-1")]
        env.planner.reaim(at: selection)
        await waitUntil(timeout: 5) { env.planner.job(for: "warm-ep-1")?.stage == .ready }
        env.settings.addCustomWord("newtarget")
        env.planner.reaim(at: selection)
        await waitUntil(timeout: 5) { counter.analyzeCallCount == 2 }
        await waitUntil(timeout: 5) {
            env.planner.isReadyOffline(episodeID: "warm-ep-1", feedURL: self.feedURL)
        }
    }

    func testAutomaticWindowAdvancesAfterEarlierChoicesAreReady() async throws {
        let counter = CountingEpisodeAnalyzer()
        let env = try makeEnv(cleaningOn: true, analyzer: counter, episodeCount: 4)
        env.planner.reaim(at: [comingUp("warm-ep-1"), comingUp("warm-ep-2")])
        await waitUntil(timeout: 5) { env.planner.job(for: "warm-ep-2")?.stage == .ready }
        env.planner.reaim(at: [comingUp("warm-ep-3"), comingUp("warm-ep-4")])
        await waitUntil(timeout: 5) { env.planner.job(for: "warm-ep-4")?.stage == .ready }
        XCTAssertEqual(counter.analyzeCallCount, 4)
        XCTAssertTrue(env.planner.isReadyOffline(episodeID: "warm-ep-1", feedURL: feedURL))
        XCTAssertTrue(env.planner.isReadyOffline(episodeID: "warm-ep-4", feedURL: feedURL))
    }

    func testCancellingExplicitIntentRetainsAutomaticOwner() async throws {
        let env = try makeEnv(cleaningOn: true, analyzer: SlowEpisodeAnalyzer(delayMilliseconds: 100))
        env.planner.reaim(at: [comingUp("warm-ep-1")])
        env.planner.requestExplicitPreparation(episodeID: "warm-ep-1")
        env.planner.cancelExplicitPreparation(episodeID: "warm-ep-1")
        XCTAssertFalse(env.planner.hasExplicitPreparation(episodeID: "warm-ep-1"))
        XCTAssertTrue(env.planner.hasAutomaticPreparation(episodeID: "warm-ep-1"))
        await waitUntil(timeout: 5) { env.planner.job(for: "warm-ep-1")?.stage == .ready }
    }

    func testAutomaticQueueWindowDoesNotOwnThirdEntry() async throws {
        let env = try makeEnv(cleaningOn: false, episodeCount: 4)
        env.settings.autoDownloadEnabled = true
        env.planner.reaim(manualQueueIDs: ["warm-ep-1", "warm-ep-2", "warm-ep-3"], predicted: [])
        await waitUntil(timeout: 5) { env.planner.job(for: "warm-ep-2")?.stage == .ready }
        XCTAssertFalse(env.planner.hasAutomaticPreparation(episodeID: "warm-ep-3"))
        XCTAssertNil(env.downloadManager.localFileURL(for: "warm-ep-3"))
        env.planner.cancel()
    }

    func testExplicitRequestRetainsAutomaticWindowAndClearsOnCompletion() async throws {
        let env = try makeEnv(cleaningOn: false, episodeCount: 4)
        env.settings.autoDownloadEnabled = true
        env.planner.reaim(manualQueueIDs: ["warm-ep-1", "warm-ep-2"], predicted: [])
        env.planner.requestExplicitPreparation(episodeID: "warm-ep-4")
        await waitUntil(timeout: 5) {
            ["warm-ep-1", "warm-ep-2", "warm-ep-4"].allSatisfy { env.planner.job(for: $0)?.stage == .ready }
        }
        XCTAssertFalse(env.planner.hasExplicitPreparation(episodeID: "warm-ep-4"))
        XCTAssertTrue(env.planner.hasAutomaticPreparation(episodeID: "warm-ep-1"))
        env.planner.cancel()
    }

    func testSuppressedFirstChoiceDoesNotPromoteThirdAndResetsAfterLeavingWindow() async throws {
        let env = try makeEnv(cleaningOn: false, episodeCount: 4)
        env.settings.autoDownloadEnabled = true
        env.planner.reaim(manualQueueIDs: ["warm-ep-1", "warm-ep-2", "warm-ep-3"], predicted: [])
        env.planner.suppressAutomaticPreparation(episodeID: "warm-ep-1")
        await waitUntil(timeout: 5) { env.planner.job(for: "warm-ep-2")?.stage == .ready }
        XCTAssertFalse(env.planner.hasAutomaticPreparation(episodeID: "warm-ep-1"))
        XCTAssertFalse(env.planner.hasAutomaticPreparation(episodeID: "warm-ep-3"))
        env.planner.reaim(manualQueueIDs: ["warm-ep-2", "warm-ep-3"], predicted: [])
        env.planner.reaim(manualQueueIDs: ["warm-ep-1", "warm-ep-2"], predicted: [])
        XCTAssertTrue(env.planner.hasAutomaticPreparation(episodeID: "warm-ep-1"))
        env.planner.cancel()
    }

    func testAutomaticSettingOffLeavesQueueIdleButExplicitRequestStillWorks() async throws {
        let env = try makeEnv(cleaningOn: false)
        env.settings.autoDownloadEnabled = false
        env.planner.reaim(manualQueueIDs: ["warm-ep-1", "warm-ep-2"], predicted: [])
        XCTAssertFalse(env.planner.hasAutomaticPreparation(episodeID: "warm-ep-1"))
        env.planner.requestExplicitPreparation(episodeID: "warm-ep-2")
        await waitUntil(timeout: 5) { env.planner.job(for: "warm-ep-2")?.stage == .ready }
        XCTAssertNil(env.downloadManager.localFileURL(for: "warm-ep-1"))
        env.planner.cancel()
    }

    private struct Env {
        let defaults: UserDefaults
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
            podcastStore: podcastStore,
            // Warm job checkpoints are durable in production. Keep this harness
            // isolated so a completed job from another test cannot satisfy the
            // readiness predicate before this test's analyzer runs.
            jobStore: AnalysisJobStore(defaults: defaults),
            preferencesStore: EpisodePreparationPreferencesStore(defaults: defaults)
        )
        return Env(
            defaults: defaults,
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
