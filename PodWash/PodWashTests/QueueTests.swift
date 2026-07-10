//
//  QueueTests.swift
//  PodWashTests
//
//  Slice 11 — Queue order + auto-advance unit tests (ADR-009). AC1–AC2.
//

import XCTest
@testable import PodWash

@MainActor
final class QueueTests: XCTestCase {

    private var harness: PersistenceReloadHarness!

    override func setUp() {
        super.setUp()
        harness = PersistenceReloadHarness()
    }

    override func tearDown() {
        harness = nil
        super.tearDown()
    }

    // MARK: - AC1: queue add / remove / move survives container reload

    func testQueueOperationsPersistAcrossReload() throws {
        let persistence = harness.makeController()
        let queue = QueueStore(context: persistence.viewContext)

        try queue.add("fixture-ep-001")
        try queue.add("fixture-ep-002")
        try queue.add("fixture-ep-003")
        XCTAssertEqual(queue.queueEpisodeIDs(), ["fixture-ep-001", "fixture-ep-002", "fixture-ep-003"])

        try queue.remove("fixture-ep-002")
        XCTAssertEqual(queue.queueEpisodeIDs(), ["fixture-ep-001", "fixture-ep-003"])

        try queue.move("fixture-ep-003", toIndex: 0)
        XCTAssertEqual(queue.queueEpisodeIDs(), ["fixture-ep-003", "fixture-ep-001"])

        try persistence.save()

        // Simulate relaunch: release live contexts, open a new controller on the same store id.
        let reloaded = harness.makeController()
        let reloadedQueue = QueueStore(context: reloaded.viewContext)

        XCTAssertEqual(reloadedQueue.queueEpisodeIDs(), ["fixture-ep-003", "fixture-ep-001"])
        XCTAssertEqual(reloadedQueue.queueEpisodeIDs().count, 2)
    }

    // MARK: - AC2: auto-advance plays next queued episode within 1.0 s

    func testAutoAdvanceOnEpisodeEnd() throws {
        let persistence = harness.makeController()
        let queue = QueueStore(context: persistence.viewContext)
        let resume = ResumePositionStore(context: persistence.viewContext)
        let player = EpisodePlayingSpy()

        try queue.add("fixture-ep-002")
        try queue.add("fixture-ep-003")

        let coordinator = QueueCoordinator(queue: queue, player: player, resume: resume)
        XCTAssertEqual(queue.queueEpisodeIDs(), ["fixture-ep-002", "fixture-ep-003"])

        let endedAt = Date()
        coordinator.handlePlaybackEnded(episodeID: "fixture-ep-001", duration: 600.0)

        player.waitForPlayCallCount(1, timeout: 1.0)
        XCTAssertEqual(player.playCalls.count, 1)
        XCTAssertEqual(player.playCalls[0].episodeID, "fixture-ep-002")
        XCTAssertLessThanOrEqual(player.playCalls[0].date.timeIntervalSince(endedAt), 1.0)

        XCTAssertEqual(queue.queueEpisodeIDs(), ["fixture-ep-003"])
        XCTAssertEqual(coordinator.currentEpisodeID, "fixture-ep-002")
    }
}
