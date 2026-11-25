import XCTest
@testable import PodWash

@MainActor final class EpisodeRowActionTests: XCTestCase {
    private var harness: PersistenceReloadHarness!
    private var model: AppShellModel!
    private var downloads: DownloadManager!
    private var transcripts: TranscriptCache!
    private var root: URL!
    private var suite: String!
    private let feedURL = URL(string: "https://fixture.podwash.tests/shared-rows")!

    override func setUp() async throws {
        harness = PersistenceReloadHarness()
        let persistence = harness.makeController()
        root = FileManager.default.temporaryDirectory.appendingPathComponent("shared-row-actions-\(UUID())")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        suite = "shared-row-actions-\(UUID())"
        let defaults = UserDefaults(suiteName: suite)!
        let settings = SettingsStore(userDefaults: defaults)
        settings.autoDownloadEnabled = false
        settings.cloudTranscriptProcessingConsentPrompted = true
        downloads = DownloadManager(downloadsDirectory: root,
            stateStore: InMemoryDownloadStateStore())
        transcripts = TranscriptCache(baseDirectory: root.appendingPathComponent("transcripts"))
        let cache = IntervalCache(baseDirectory: root.appendingPathComponent("intervals"))
        model = AppShellModel(persistence: persistence,
            remoteCommands: RemoteCommandCoordinator(commands: MPRemoteCommandCenterAdapter()),
            episodeAnalyzer: InstantEpisodeAnalyzer(), settingsStore: settings,
            fixtureLibraryModeForTesting: true, downloadManager: downloads,
            transcriptCache: transcripts, intervalCache: cache,
            analysisJobStore: AnalysisJobStore(defaults: defaults),
            preparationPreferencesStore: EpisodePreparationPreferencesStore(defaults: defaults))
        let episodes = (1...4).map { Episode(id: "row-\($0)", title: "Episode \($0)",
            pubDate: Date(), artworkURL: nil, showNotes: nil,
            audioURL: URL(string: "https://fixture.podwash.tests/audio/\($0).m4a")) }
        try model.podcastStore.save(PodcastFeed(title: "Show", artworkURL: nil,
            description: nil, episodes: episodes), feedURL: feedURL)
        let source = try XCTUnwrap(FixtureAudio.bundledURL(in: .main))
        for episode in episodes {
            try FileManager.default.copyItem(at: source, to: DownloadPaths.localFileURL(
                episodeID: episode.id, downloadsDirectory: root))
            try cache.store([], episodeID: episode.id, targetWords: settings.activeNormalizedTargetSet())
            try transcripts.store([TimedWord(word: "hello", start: 0, end: 1)], episodeID: episode.id)
        }
    }

    override func tearDown() async throws {
        model.stopAndDismissPlayer()
        model = nil
        downloads = nil
        transcripts = nil
        try? FileManager.default.removeItem(at: root)
        UserDefaults(suiteName: suite)?.removePersistentDomain(forName: suite)
        harness = nil
    }

    func testRemoveFromQueueRetainsAudioAndTranscript() throws {
        model.addToUpNext("row-1")
        model.removeFromUpNext(episodeID: "row-1")
        XCTAssertTrue(model.queueStore.queueEpisodeIDs().isEmpty)
        XCTAssertNotNil(downloads.verifiedLocalFileURL(for: "row-1"))
        XCTAssertNotNil(transcripts.load(episodeID: "row-1"))
    }

    func testClearAndUndoPreservesNewQueueAdditions() throws {
        model.addToUpNext("row-1")
        model.addToUpNext("row-2")
        let removed = model.clearUpNext()
        model.addToUpNext("row-3")
        model.restoreUpNext(removed)
        XCTAssertEqual(model.queueStore.queueEpisodeIDs(), ["row-2", "row-1", "row-3"])
        XCTAssertNotNil(downloads.verifiedLocalFileURL(for: "row-1"))
    }

    func testRemoveUndoPreservesInterveningQueueAndPositionChanges() throws {
        for id in ["row-1", "row-2", "row-3"] { model.addToUpNext(id) }
        let snapshot = model.removeFromUpNextWithUndo(episodeID: "row-2")
        model.addToUpNext("row-4")
        model.moveUpNextToTop(episodeID: "row-3")
        try model.resumeStore.setPosition(42, for: "row-2")
        model.restoreQueueMutation(snapshot)
        XCTAssertEqual(model.queueStore.queueEpisodeIDs(), ["row-3", "row-4", "row-2", "row-1"])
        XCTAssertEqual(model.resumeStore.position(for: "row-2"), 42)
    }

    func testMarkPlayedUndoPreservesNewPlaybackPosition() throws {
        model.addToUpNext("row-1")
        let snapshot = model.markPlayedWithUndo(episodeID: "row-1")
        try model.resumeStore.setPosition(42, for: "row-1")
        model.restoreQueueMutation(snapshot)
        XCTAssertFalse(model.resumeStore.isPlayed("row-1"))
        XCTAssertEqual(model.resumeStore.position(for: "row-1"), 42)
        XCTAssertEqual(model.queueStore.queueEpisodeIDs(), ["row-1"])
    }

    func testLibraryAndQueueShareStateAndMenuOnlyMetadataDiffers() throws {
        let episode = try XCTUnwrap(model.podcastStore.episodeLookup(id: "row-1")?.episode)
        let library = model.episodeRowSnapshot(episode, context: .library)
        let queue = model.episodeRowSnapshot(episode, context: .queue)
        XCTAssertEqual(library.presentation, queue.presentation)
        XCTAssertEqual(library.menu, queue.menu)
        XCTAssertEqual(library.cleaningSummary, queue.cleaningSummary)
        XCTAssertNotEqual(library.context, queue.context)
    }

    func testStaleMenuActionsRevalidateMembershipAndPlayedState() throws {
        model.addToUpNext("row-1")
        let bindings = model.episodeRowBindings("row-1", context: .library)
        model.removeFromUpNext(episodeID: "row-1")
        bindings.perform(.removeFromUpNext)
        XCTAssertNil(model.episodeUndoMessage)
        try model.resumeStore.setPlayed(true, for: "row-1")
        bindings.perform(.markPlayed)
        XCTAssertNil(model.episodeUndoMessage)
        XCTAssertTrue(model.resumeStore.isPlayed("row-1"))
    }

    func testConsentDefersExplicitPreparationWithoutQueueOrPlaybackMutation() async throws {
        model.settingsStore.cloudTranscriptProcessingConsentPrompted = false
        model.addToUpNext("row-2")
        model.requestEpisodeDownload("row-1")
        XCTAssertTrue(model.isCloudTranscriptConsentPresented)
        XCTAssertNil(model.nowPlayingEpisodeID)
        XCTAssertEqual(model.queueStore.queueEpisodeIDs(), ["row-2"])
        model.declineCloudTranscriptProcessing()
        XCTAssertFalse(model.isCloudTranscriptConsentPresented)
        XCTAssertTrue(model.settingsStore.cloudTranscriptProcessingConsentPrompted)
        XCTAssertFalse(model.settingsStore.canUseCloudTranscriptProcessing)
        for _ in 0..<50 {
            if model.episodeRowSnapshot(try XCTUnwrap(model.podcastStore.episodeLookup(id: "row-1")?.episode), context: .library).presentation.primaryControl == .play { break }
            try await Task.sleep(for: .milliseconds(20))
        }
        XCTAssertNil(model.nowPlayingEpisodeID)
        XCTAssertEqual(model.queueStore.queueEpisodeIDs(), ["row-2"])
    }

    func testReplayPreparationDoesNotResetHistoryOrStartPlayback() async throws {
        try model.resumeStore.setPlayed(true, for: "row-1")
        try model.resumeStore.setPosition(42, for: "row-1")
        model.requestEpisodeDownload("row-1")
        for _ in 0..<100 {
            if model.replayReadyEpisodeID == "row-1" { break }
            try await Task.sleep(for: .milliseconds(20))
        }
        XCTAssertEqual(model.replayReadyEpisodeID, "row-1")
        XCTAssertTrue(model.resumeStore.isPlayed("row-1"))
        XCTAssertEqual(model.resumeStore.position(for: "row-1"), 42)
        XCTAssertNil(model.nowPlayingEpisodeID)
        XCTAssertTrue(model.queueStore.queueEpisodeIDs().isEmpty)
        XCTAssertNotNil(downloads.verifiedLocalFileURL(for: "row-1"))
    }

    func testEngineCompletionAddsOneHistoryRowAndIgnoresDuplicateCallback() throws {
        let episode = try XCTUnwrap(model.podcastStore.episodeLookup(id: "row-1")?.episode)
        model.playEpisode(episode, podcastTitle: "Show", feedURL: feedURL)
        let complete = try XCTUnwrap(model.engine?.onPlaybackEnded)
        complete()
        let first = try XCTUnwrap(model.historyEntries.first?.completedAt)
        complete()
        XCTAssertEqual(model.historyEntries.map(\.episode.id), [episode.id])
        XCTAssertEqual(model.historyEntries.first?.completedAt, first)
        XCTAssertTrue(model.resumeStore.isPlayed(episode.id))
    }

    func testHistoryKeepsTranscriptWhileReplayUsesFreshAnalysis() async throws {
        let episode = try XCTUnwrap(model.podcastStore.episodeLookup(id: "row-1")?.episode)
        let key = ListeningHistoryEntry.ID(feedURL: feedURL, episodeID: episode.id)
        _ = try model.listeningHistory.recordCompletion(episode: episode, feedURL: feedURL,
            showTitle: "Show", runID: "playback", at: Date()) {
                try model.resumeStore.stageCompletion(for: episode.id, duration: 90)
            }

        let entry = try XCTUnwrap(model.listeningHistory.entry(for: key))
        model.historyRowBindings(entry).primary.prepare()
        for _ in 0..<100 where model.replayReadyEpisodeID != episode.id {
            try await Task.sleep(for: .milliseconds(20))
        }
        XCTAssertEqual(model.replayReadyEpisodeID, episode.id)
        XCTAssertNil(transcripts.load(episodeID: episode.id))
        XCTAssertNotNil(transcripts.historyArchive.load(episodeID: key.accessibilityID))
        XCTAssertTrue(model.historyRowSnapshot(entry).menu.contains(.transcript))
        model.historyRowBindings(entry).perform(.transcript)
        XCTAssertEqual(model.transcriptSheetEpisodeID, episode.id)
        XCTAssertNil(model.nowPlayingEpisodeID)
    }

    func testHistoryPlayNextRestoresReplayIntentWithUndo() throws {
        try model.resumeStore.setPlayed(true, for: "row-1")
        model.addToUpNext("row-1")
        let before = try XCTUnwrap(model.queueStore.entry(for: "row-1"))
        XCTAssertEqual(before.replayFeedURL, feedURL)
        XCTAssertTrue(model.queuePresentation.upNext.contains { $0.episodeID == "row-1" })
        let removed = model.clearUpNext()
        model.restoreUpNext(removed)
        let restored = try XCTUnwrap(model.queueStore.entry(for: "row-1"))
        XCTAssertEqual(restored.replayFeedURL, feedURL)
        XCTAssertNotEqual(restored.objectID, before.objectID)
        XCTAssertTrue(model.resumeStore.isPlayed("row-1"))
    }

    func testUpNextAcceptsReplayBeforeConsumingItAndStartsAtBeginning() async throws {
        let current = try XCTUnwrap(model.podcastStore.episodeLookup(id: "row-1")?.episode)
        model.playEpisode(current, podcastTitle: "Show", feedURL: feedURL)
        try model.resumeStore.setPlayed(true, for: "row-2")
        try model.resumeStore.setPosition(42, for: "row-2")
        model.addToUpNext("row-2")
        let complete = try XCTUnwrap(model.engine?.onPlaybackEnded)

        complete()
        XCTAssertEqual(model.queueStore.queueEpisodeIDs(), ["row-2"])
        for _ in 0..<150 where model.nowPlayingEpisodeID != "row-2" {
            try await Task.sleep(for: .milliseconds(20))
        }
        XCTAssertEqual(model.nowPlayingEpisodeID, "row-2")
        XCTAssertTrue(model.queueStore.queueEpisodeIDs().isEmpty)
        XCTAssertEqual(model.resumeStore.position(for: "row-2"), 0)
        XCTAssertFalse(model.resumeStore.isPlayed("row-2"))
        XCTAssertEqual(model.historyEntries.map(\.episode.id), ["row-1"])
    }

    func testManualPlayedCommitAlwaysRemovesLocalAudio() async throws {
        let snapshot = model.markPlayedWithUndo(episodeID: "row-1")
        model.commitQueueMutation(snapshot)
        for _ in 0..<100 where downloads.verifiedLocalFileURL(for: "row-1") != nil {
            try await Task.sleep(for: .milliseconds(20))
        }
        XCTAssertNil(downloads.verifiedLocalFileURL(for: "row-1"))
        XCTAssertTrue(model.resumeStore.isPlayed("row-1"))
        XCTAssertNotNil(transcripts.load(episodeID: "row-1"))
    }
}
