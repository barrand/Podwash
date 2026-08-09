//
//  SmartAutoplayCoordinatorTests.swift
//  PodWashTests
//
//  ADR-029 — Queue precedence + smart next + skip dismiss.
//

import XCTest
@testable import PodWash

@MainActor
final class SmartAutoplayCoordinatorTests: XCTestCase {

    private var harness: PersistenceReloadHarness!

    override func setUp() {
        super.setUp()
        harness = PersistenceReloadHarness()
    }

    override func tearDown() {
        harness = nil
        super.tearDown()
    }

    func testManualQueueWinsOverSmartNext() throws {
        let persistence = harness.makeController()
        let queue = QueueStore(context: persistence.viewContext)
        let resume = ResumePositionStore(context: persistence.viewContext)
        let player = EpisodePlayingSpy()

        try queue.add("queued-ep")

        let coordinator = QueueCoordinator(queue: queue, player: player, resume: resume)
        var smartCalled = false
        coordinator.resolveSmartNext = { _ in
            smartCalled = true
            return "smart-ep"
        }

        coordinator.handlePlaybackEnded(episodeID: "current-ep", duration: 100)

        player.waitForPlayCallCount(1, timeout: 1.0)
        XCTAssertEqual(player.playCalls[0].episodeID, "queued-ep")
        XCTAssertFalse(smartCalled)
    }

    func testSmartNextUsedWhenQueueEmpty() throws {
        let persistence = harness.makeController()
        let queue = QueueStore(context: persistence.viewContext)
        let resume = ResumePositionStore(context: persistence.viewContext)
        let player = EpisodePlayingSpy()

        let coordinator = QueueCoordinator(queue: queue, player: player, resume: resume)
        coordinator.resolveSmartNext = { _ in
            return "smart-ep"
        }

        coordinator.handlePlaybackEnded(episodeID: "current-ep", duration: 100)

        player.waitForPlayCallCount(1, timeout: 1.0)
        XCTAssertEqual(player.playCalls[0].episodeID, "smart-ep")
    }

    func testBingeFlagPersistsAcrossReload() throws {
        let persistence = harness.makeController()
        let store = PodcastStore(context: persistence.viewContext)
        let feedURL = URL(string: "https://example.com/serial.xml")!
        let feed = PodcastFeed(
            title: "Serial",
            artworkURL: nil,
            description: nil,
            episodes: [
                Episode(
                    id: "s1",
                    title: "One",
                    pubDate: Date(timeIntervalSince1970: 1),
                    artworkURL: nil,
                    showNotes: nil,
                    audioURL: URL(string: "https://example.com/s1.mp3")
                ),
            ]
        )
        try store.save(feed, feedURL: feedURL)
        try store.setBinge(true, feedURL: feedURL)
        try persistence.save()

        let reloaded = harness.makeController()
        let reloadedStore = PodcastStore(context: reloaded.viewContext)
        XCTAssertTrue(reloadedStore.isBinge(feedURL: feedURL))
    }

    func testDismissPersistsAcrossReload() throws {
        let persistence = harness.makeController()
        let store = PodcastStore(context: persistence.viewContext)
        let feedURL = URL(string: "https://example.com/a.xml")!
        let feed = PodcastFeed(
            title: "A",
            artworkURL: nil,
            description: nil,
            episodes: [
                Episode(
                    id: "ep-1",
                    title: "One",
                    pubDate: Date(timeIntervalSince1970: 1),
                    artworkURL: nil,
                    showNotes: nil,
                    audioURL: URL(string: "https://example.com/1.mp3")
                ),
            ]
        )
        try store.save(feed, feedURL: feedURL)
        try store.setDismissedFromAutoplay(true, episodeID: "ep-1")
        try persistence.save()

        let reloaded = harness.makeController()
        let reloadedStore = PodcastStore(context: reloaded.viewContext)
        XCTAssertTrue(reloadedStore.isDismissedFromAutoplay(episodeID: "ep-1"))
    }
}
