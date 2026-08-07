//
//  NowPlayingSessionTests.swift
//  PodWashTests
//
//  Slice 31 — Restore now-playing session on relaunch (ADR-027). AC1–AC4.
//  Provenance: fixture episode ids from hand-authored sample_feed.xml (Slice 06);
//  position 127.5 s is an arbitrary pinned scalar independent of implementation.
//

import AVFoundation
import XCTest
@testable import PodWash

@MainActor
final class NowPlayingSessionTests: XCTestCase {

  private var harness: PersistenceReloadHarness!
  private var downloadsDirectory: URL!
  private var intervalCache: IntervalCache!
  private var transcriptCache: TranscriptCache!
  private var artifactStore: EpisodeAnalysisArtifactStore!
  private var artifactDefaults: UserDefaults!

  private let activeEpisodeID = "fixture-ep-001"
  private let nextEpisodeID = "fixture-ep-002"
  private let thirdEpisodeID = "fixture-ep-003"
  private let pinnedPosition: TimeInterval = 127.5
  private let positionTolerance: TimeInterval = 1.0

  override func setUp() {
    super.setUp()
    harness = PersistenceReloadHarness()
    downloadsDirectory = FileManager.default.temporaryDirectory
      .appendingPathComponent("podwash-now-playing-session-\(UUID().uuidString)", isDirectory: true)
    try? FileManager.default.createDirectory(at: downloadsDirectory, withIntermediateDirectories: true)
    intervalCache = IntervalCache(
      baseDirectory: FileManager.default.temporaryDirectory
        .appendingPathComponent("podwash-now-playing-cache-\(UUID().uuidString)", isDirectory: true)
    )
    let artifactRoot = FileManager.default.temporaryDirectory
      .appendingPathComponent("podwash-now-playing-artifacts-\(UUID().uuidString)", isDirectory: true)
    transcriptCache = TranscriptCache(baseDirectory: artifactRoot.appendingPathComponent("transcripts"))
    let suite = "com.podwash.tests.now-playing-artifacts.\(UUID().uuidString)"
    artifactDefaults = UserDefaults(suiteName: suite)!
    artifactDefaults.removePersistentDomain(forName: suite)
    artifactStore = EpisodeAnalysisArtifactStore(
      baseDirectory: artifactRoot.appendingPathComponent("artifacts"),
      defaults: artifactDefaults
    )
  }

  override func tearDown() {
    try? FileManager.default.removeItem(at: downloadsDirectory)
    try? intervalCache.clear()
    try? transcriptCache.clear()
    try? FileManager.default.removeItem(at: artifactStore.baseDirectory.deletingLastPathComponent())
    intervalCache = nil
    transcriptCache = nil
    artifactStore = nil
    artifactDefaults = nil
    harness = nil
    super.tearDown()
  }

  // MARK: - AC1: active session + position + queue survive PersistenceController reload

  func testActiveSessionPersistsAcrossReload() throws {
    let persistence = harness.makeController()
    let context = persistence.viewContext
    let session = NowPlayingSessionStore(context: context)
    let resume = ResumePositionStore(context: context)
    let queue = QueueStore(context: context)

    try session.setActiveEpisodeID(activeEpisodeID)
    try resume.setPosition(pinnedPosition, for: activeEpisodeID)
    try queue.add(nextEpisodeID)
    try queue.add(thirdEpisodeID)
    try persistence.save()

    let reloaded = harness.makeController()
    let reloadedSession = NowPlayingSessionStore(context: reloaded.viewContext)
    let reloadedResume = ResumePositionStore(context: reloaded.viewContext)
    let reloadedQueue = QueueStore(context: reloaded.viewContext)

    XCTAssertEqual(reloadedSession.activeEpisodeID(), activeEpisodeID)
    let restoredPosition = reloadedResume.position(for: activeEpisodeID)
    XCTAssertLessThanOrEqual(abs(restoredPosition - pinnedPosition), positionTolerance)
    XCTAssertEqual(reloadedQueue.queueEpisodeIDs(), [nextEpisodeID, thirdEpisodeID])
  }

  // MARK: - AC2: bootstrap restores paused mini session at saved position

  func testBootstrapRestoresMiniPlayerPausedAtPosition() throws {
    let persistence = harness.makeController()
    try seedFeedAndSession(
      persistence: persistence,
      activeID: activeEpisodeID,
      position: pinnedPosition,
      queueIDs: [nextEpisodeID, thirdEpisodeID]
    )
    try installLocalDownload(for: activeEpisodeID)
    try persistence.save()

    let model = makeShell(persistence: persistence)
    model.restoreNowPlayingSessionIfNeeded()

    XCTAssertTrue(model.isMiniPlayerVisible)
    XCTAssertEqual(model.nowPlayingEpisodeID, activeEpisodeID)
    XCTAssertNotNil(model.engine, "restore must build a paused engine session")
    XCTAssertFalse(model.engine?.isPlaying ?? true, "restore must not auto-play")

    waitUntil(timeout: 3.0) {
      guard let engine = model.engine else { return false }
      return abs(engine.currentTime - self.pinnedPosition) <= self.positionTolerance
    }

    let current = model.engine?.currentTime ?? 0
    XCTAssertLessThanOrEqual(abs(current - pinnedPosition), positionTolerance)

    // Tear down session before AppShellModel leaves scope (MainActor deinit hygiene).
    model.stopAndDismissPlayer()
  }

  func testBootstrapRestoresCompletedAnalysisIntoSeekBar() throws {
    let persistence = harness.makeController()
    try seedFeedAndSession(
      persistence: persistence,
      activeID: activeEpisodeID,
      position: pinnedPosition,
      queueIDs: []
    )
    try installLocalDownload(for: activeEpisodeID)
    try persistence.save()

    let model = makeShell(persistence: persistence)
    model.settingsStore.unrelatedContentEnabled = true
    let feedURL = try XCTUnwrap(model.podcastStore.episodeLookup(id: activeEpisodeID)?.feedURL)
    try model.cleaningStore.setChannelCleaning(forFeedURL: feedURL, enabled: true)
    try model.cleaningStore.setChannelUnrelatedContent(forFeedURL: feedURL, enabled: true)
    let cachedIntervals = [
      CensorInterval(start: 0.5, end: 1.0, action: .mute, source: .profanity),
      CensorInterval(start: 1.5, end: 2.0, action: .skip, source: .unrelatedContent)
    ]
    try intervalCache.store(
      cachedIntervals,
      episodeID: activeEpisodeID,
      targetWords: model.settingsStore.activeNormalizedTargetSet()
    )

    model.restoreNowPlayingSessionIfNeeded()

    waitUntil(timeout: 3.0) { model.isPlayerSeekBarAnalysisComplete }
    XCTAssertEqual(model.nowPlayingMuteIntervals, cachedIntervals)
    XCTAssertFalse(model.playbackAnalysisSnapshot?.adRanges.isEmpty ?? true)

    model.stopAndDismissPlayer()
  }

  func testBootstrapRestoresDurableArtifactWithoutRunningAnalysis() throws {
    let persistence = harness.makeController()
    try seedFeedAndSession(
      persistence: persistence,
      activeID: activeEpisodeID,
      position: pinnedPosition,
      queueIDs: []
    )
    try installLocalDownload(for: activeEpisodeID)
    try transcriptCache.store(
      [TimedWord(word: "artifactword", start: 2, end: 2.4)],
      episodeID: activeEpisodeID
    )
    try artifactStore.store(EpisodeAnalysisArtifact(
      episodeID: activeEpisodeID,
      adSpans: [ContentSegment(start: 10, end: 20)],
      analysisFingerprint: "previous-model",
      completedAt: Date()
    ))
    try persistence.save()

    let settings = makeIsolatedSettingsStore()
    settings.addCustomWord("artifactword")
    settings.unrelatedContentEnabled = true
    let analyzer = CountingRestoreAnalyzer()
    let model = makeShell(persistence: persistence, settingsStore: settings, analyzer: analyzer)

    model.restoreNowPlayingSessionIfNeeded()

    waitUntil(timeout: 3.0) {
      model.nowPlayingMuteIntervals.contains { $0.source == .unrelatedContent }
    }
    XCTAssertTrue(model.nowPlayingTranscriptExists)
    XCTAssertEqual(analyzer.calls, 0, "cold restoration must not start analysis")
    XCTAssertTrue(
      model.nowPlayingMuteIntervals.contains { $0.source == .profanity },
      "current word-list must rebuild profanity markers from the restored transcript"
    )
    XCTAssertTrue(
      model.nowPlayingMuteIntervals.contains { $0.source == .unrelatedContent },
      "durable prior ad spans must survive an exact-cache miss"
    )

    model.stopAndDismissPlayer()
  }

  func testBootstrapWithMissingArtifactsDoesNotAnalyzeUntilListenerInteracts() throws {
    let persistence = harness.makeController()
    try seedFeedAndSession(
      persistence: persistence,
      activeID: activeEpisodeID,
      position: pinnedPosition,
      queueIDs: []
    )
    try installLocalDownload(for: activeEpisodeID)
    try persistence.save()

    let analyzer = CountingRestoreAnalyzer()
    let model = makeShell(persistence: persistence, analyzer: analyzer)

    model.restoreNowPlayingSessionIfNeeded()

    XCTAssertNotNil(model.engine)
    XCTAssertEqual(analyzer.calls, 0, "restoring a session must never begin analysis")
    XCTAssertEqual(model.analysisRecoveryState, .missingArtifacts)

    model.stopAndDismissPlayer()
  }

  // MARK: - AC3: finish + empty queue clears durable session

  func testSessionClearsWhenEpisodeEndsWithEmptyQueue() throws {
    let persistence = harness.makeController()
    try seedFeedAndSession(
      persistence: persistence,
      activeID: activeEpisodeID,
      position: pinnedPosition,
      queueIDs: []
    )

    let context = persistence.viewContext
    let session = NowPlayingSessionStore(context: context)
    let queue = QueueStore(context: context)
    let resume = ResumePositionStore(context: context)
    let player = EpisodePlayingSpy()

    let coordinator = QueueCoordinator(
      queue: queue,
      player: player,
      resume: resume,
      sessionStore: session
    )

    coordinator.handlePlaybackEnded(episodeID: activeEpisodeID, duration: 600.0)

    XCTAssertNil(session.activeEpisodeID())
    try persistence.save()

    let reloaded = harness.makeController()
    let reloadedSession = NowPlayingSessionStore(context: reloaded.viewContext)
    XCTAssertNil(reloadedSession.activeEpisodeID())

    let model = makeShell(persistence: reloaded)
    model.restoreNowPlayingSessionIfNeeded()

    XCTAssertFalse(model.isMiniPlayerVisible)
    XCTAssertNil(model.nowPlayingEpisodeID)
    XCTAssertNil(model.nowPlayingSessionStore.activeEpisodeID())

    model.stopAndDismissPlayer()
  }

  // MARK: - AC4: finish + non-empty queue advances durable active id

  func testSessionSurvivesAdvanceWhenQueueNonEmpty() throws {
    let persistence = harness.makeController()
    try seedFeedAndSession(
      persistence: persistence,
      activeID: activeEpisodeID,
      position: pinnedPosition,
      queueIDs: [nextEpisodeID, thirdEpisodeID]
    )

    let context = persistence.viewContext
    let session = NowPlayingSessionStore(context: context)
    let queue = QueueStore(context: context)
    let resume = ResumePositionStore(context: context)
    let player = EpisodePlayingSpy()

    let coordinator = QueueCoordinator(
      queue: queue,
      player: player,
      resume: resume,
      sessionStore: session
    )

    coordinator.handlePlaybackEnded(episodeID: activeEpisodeID, duration: 600.0)

    XCTAssertEqual(session.activeEpisodeID(), nextEpisodeID)
    XCTAssertEqual(queue.queueEpisodeIDs(), [thirdEpisodeID])
    XCTAssertEqual(coordinator.currentEpisodeID, nextEpisodeID)
    XCTAssertEqual(player.playCalls.count, 1)
    XCTAssertEqual(player.playCalls[0].episodeID, nextEpisodeID)
  }

  // MARK: - Helpers

  private func seedFeedAndSession(
    persistence: PersistenceController,
    activeID: String,
    position: TimeInterval,
    queueIDs: [String]
  ) throws {
    let context = persistence.viewContext
    let podcastStore = PodcastStore(context: context)
    try FixtureFeedLoader.seedEpisodes(into: podcastStore)

    let session = NowPlayingSessionStore(context: context)
    let resume = ResumePositionStore(context: context)
    let queue = QueueStore(context: context)

    try session.setActiveEpisodeID(activeID)
    try resume.setPosition(position, for: activeID)
    for id in queueIDs {
      try queue.add(id)
    }
  }

  private func installLocalDownload(for episodeID: String) throws {
    guard let source = FixtureAudio.bundledURL(in: Bundle.main) else {
      XCTFail("Missing test-clip.m4a in host bundle for restore bootstrap")
      return
    }
    let destination = DownloadPaths.localFileURL(
      episodeID: episodeID,
      downloadsDirectory: downloadsDirectory
    )
    try? FileManager.default.removeItem(at: destination)
    try FileManager.default.copyItem(at: source, to: destination)
  }

  private func makeShell(
    persistence: PersistenceController,
    settingsStore: SettingsStore? = nil,
    analyzer: (any EpisodeAnalyzing)? = nil
  ) -> AppShellModel {
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
      episodeAnalyzer: analyzer ?? InstantEpisodeAnalyzer(),
      settingsStore: settingsStore ?? makeIsolatedSettingsStore(),
      fixtureLibraryModeForTesting: false,
      downloadManager: testDownloadManager,
      transcriptCache: transcriptCache,
      intervalCache: intervalCache,
      artifactStore: artifactStore
    )
    model.downloadsDirectoryForTesting = downloadsDirectory
    return model
  }

  private func makeIsolatedSettingsStore() -> SettingsStore {
    let suite = "com.podwash.tests.now-playing-session.\(UUID().uuidString)"
    guard let defaults = UserDefaults(suiteName: suite) else {
      XCTFail("Could not create isolated UserDefaults suite")
      return SettingsStore()
    }
    defaults.removePersistentDomain(forName: suite)
    return SettingsStore(userDefaults: defaults)
  }

  private func waitUntil(
    timeout: TimeInterval,
    pollInterval: TimeInterval = 0.05,
    _ condition: @escaping () -> Bool,
    file: StaticString = #filePath,
    line: UInt = #line
  ) {
    let deadline = Date().addingTimeInterval(timeout)
    while Date() < deadline {
      if condition() { return }
      RunLoop.current.run(until: Date().addingTimeInterval(pollInterval))
    }
    XCTFail("Condition not met within \(timeout)s", file: file, line: line)
  }
}

private final class CountingRestoreAnalyzer: EpisodeAnalyzing, @unchecked Sendable {
  var calls = 0
  var onPartialIntervals: AnalysisPartialIntervalsHandler?

  func analyze(
    episode: EpisodeIdentity,
    audioURL: URL,
    targetWords: Set<String>,
    injectedTranscript: [TimedWord]?
  ) async throws -> [CensorInterval] {
    calls += 1
    return []
  }

  func analyze(
    episode: EpisodeIdentity,
    audioURL: URL,
    targetWords: Set<String>,
    injectedTranscript: [TimedWord]?,
    profanityAction: CensorAction,
    unrelatedContent: UnrelatedContentOptions
  ) async throws -> [CensorInterval] {
    calls += 1
    return []
  }
}
