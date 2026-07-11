//
//  PodcastStoreMultiSubscriptionTests.swift
//  PodWashTests
//
//  Slice 22 — Multi-subscription persistence + idempotency (ADR-014 §4–§5). AC3–AC4.
//

import XCTest
@testable import PodWash

@MainActor
final class PodcastStoreMultiSubscriptionTests: XCTestCase {

    private var harness: PersistenceReloadHarness!

    override func setUp() {
        super.setUp()
        harness = PersistenceReloadHarness()
    }

    override func tearDown() {
        harness = nil
        super.tearDown()
    }

    // MARK: - AC3: two subscriptions survive PersistenceController reload

    func testMultipleSubscriptionsPersistAcrossReload() throws {
        let persistence = harness.makeController()
        let store = PodcastStore(context: persistence.viewContext, retaining: persistence)
        let parser = RSSParser()
        let goldenPopular = try ITunesGoldenFixtures.popularResults()

        let feedA = try parser.parse(data: try ITunesGoldenFixtures.rssPayload(for: goldenPopular[0].feedURL))
        try store.saveSubscription(from: goldenPopular[0], feed: feedA)

        let feedB = try parser.parse(data: try ITunesGoldenFixtures.rssPayload(for: goldenPopular[1].feedURL))
        try store.saveSubscription(from: goldenPopular[1], feed: feedB)

        XCTAssertEqual(store.subscriptionCount, 2)

        try persistence.save()

        let reloaded = harness.makeController()
        let reloadedStore = PodcastStore(context: reloaded.viewContext, retaining: reloaded)

        XCTAssertEqual(reloadedStore.subscriptionCount, 2)
        XCTAssertEqual(
            reloadedStore.allSubscriptions().map(\.title),
            [goldenPopular[0].title, goldenPopular[1].title]
        )
    }

    // MARK: - AC4: duplicate feedURL subscribe is idempotent

    func testDuplicateSubscribeIsIdempotent() throws {
        let persistence = harness.makeController()
        let store = PodcastStore(context: persistence.viewContext, retaining: persistence)
        let parser = RSSParser()
        let golden = try ITunesGoldenFixtures.popularResults()[0]
        let feed = try parser.parse(data: try ITunesGoldenFixtures.rssPayload(for: golden.feedURL))

        try store.saveSubscription(from: golden, feed: feed)
        try store.saveSubscription(from: golden, feed: feed)

        XCTAssertEqual(store.subscriptionCount, 1)
        XCTAssertEqual(store.subscription(forFeedURL: golden.feedURL)?.episodes.count, 5)
    }
}
