//
//  ResumePositionTests.swift
//  PodWashTests
//
//  Slice 11 — Resume position + played threshold unit tests (ADR-009). AC3–AC4.
//

import XCTest
@testable import PodWash

@MainActor
final class ResumePositionTests: XCTestCase {

    private var harness: PersistenceReloadHarness!

    override func setUp() {
        super.setUp()
        harness = PersistenceReloadHarness()
    }

    override func tearDown() {
        harness = nil
        super.tearDown()
    }

    // MARK: - AC3: saved position restores within ±1.0 s after reload

    func testPositionSaveRestoreWithinTolerance() throws {
        let persistence = harness.makeController()
        let podcastStore = PodcastStore(context: persistence.viewContext)
        try FixtureFeedLoader.seedEpisodes(into: podcastStore)

        let resume = ResumePositionStore(context: persistence.viewContext)
        let player = EpisodePlayingSpy()
        let queue = QueueStore(context: persistence.viewContext)
        let coordinator = QueueCoordinator(queue: queue, player: player, resume: resume)

        let savedPosition: TimeInterval = 127.5

        coordinator.pause(savingPosition: savedPosition)
        XCTAssertEqual(resume.position(for: "fixture-ep-001"), savedPosition, accuracy: 0.001)
        try persistence.save()

        let reloaded = harness.makeController()
        let reloadedResume = ResumePositionStore(context: reloaded.viewContext)
        let reloadedQueue = QueueStore(context: reloaded.viewContext)
        let reloadedPlayer = EpisodePlayingSpy()
        let reloadedCoordinator = QueueCoordinator(
            queue: reloadedQueue,
            player: reloadedPlayer,
            resume: reloadedResume
        )

        reloadedCoordinator.playEpisode("fixture-ep-001")

        XCTAssertFalse(reloadedPlayer.seekPositions.isEmpty, "playEpisode must seek before play when position > 0")
        let restored = reloadedPlayer.seekPositions[0]
        XCTAssertLessThanOrEqual(abs(restored - savedPosition), 1.0)
        XCTAssertEqual(reloadedResume.position(for: "fixture-ep-001"), savedPosition, accuracy: 0.001)
    }

    // MARK: - AC4: 95% played threshold is sticky across reload

    func testPlayedThresholdAndPersistence() throws {
        let persistence = harness.makeController()
        let podcastStore = PodcastStore(context: persistence.viewContext)
        try FixtureFeedLoader.seedEpisodes(into: podcastStore)

        let resume = ResumePositionStore(context: persistence.viewContext)
        let episodeID = "fixture-ep-004"
        let duration: TimeInterval = 100.0

        try resume.recordProgress(episodeID: episodeID, seconds: 94.9, duration: duration)
        XCTAssertFalse(resume.isPlayed(episodeID))

        try resume.recordProgress(episodeID: episodeID, seconds: 95.0, duration: duration)
        XCTAssertTrue(resume.isPlayed(episodeID))

        try persistence.save()

        let reloaded = harness.makeController()
        let reloadedResume = ResumePositionStore(context: reloaded.viewContext)

        XCTAssertTrue(reloadedResume.isPlayed(episodeID))
        XCTAssertFalse(reloadedResume.isPlayed("fixture-ep-001"))
    }
}
