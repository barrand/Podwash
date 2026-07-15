//
//  PersistenceMigrationTests.swift
//  PodWashTests
//
//  Slice 11 — Core Data migration smoke from Slice 06/09/10 stubs (ADR-009). AC5.
//

import XCTest
@testable import PodWash

@MainActor
final class PersistenceMigrationTests: XCTestCase {

    private var harness: PersistenceReloadHarness!

    override func setUp() {
        super.setUp()
        harness = PersistenceReloadHarness()
    }

    override func tearDown() {
        harness = nil
        super.tearDown()
    }

    // MARK: - AC5: podcast + cleaning + download state survive container reload

    func testInMemoryStubMigrationSurvivesReload() throws {
        let persistence = harness.makeController()

        let podcastStore = PodcastStore(context: persistence.viewContext)
        let cleaningStore = CleaningToggleStore(context: persistence.viewContext)
        let downloadStore = DownloadStateStore(context: persistence.viewContext)

        let feed = try FixtureFeedLoader.loadSampleFeed()
        try podcastStore.save(feed)

        try cleaningStore.setChannelCleaning(true)
        try cleaningStore.setEpisodeCleaning("fixture-ep-001", enabled: true)
        try downloadStore.setState(.downloaded, for: "fixture-ep-001")

        XCTAssertEqual(podcastStore.episodes.count, 5)
        XCTAssertTrue(cleaningStore.isChannelCleaningEnabled)
        XCTAssertTrue(cleaningStore.isEpisodeCleaningEnabled("fixture-ep-001"))
        XCTAssertEqual(downloadStore.state(for: "fixture-ep-001"), .downloaded)

        try persistence.save()

        let reloaded = harness.makeController()
        let reloadedPodcast = PodcastStore(context: reloaded.viewContext)
        let reloadedCleaning = CleaningToggleStore(context: reloaded.viewContext)
        let reloadedDownload = DownloadStateStore(context: reloaded.viewContext)

        XCTAssertEqual(reloadedPodcast.episodes.count, 5)
        XCTAssertEqual(reloadedPodcast.episodes[0].id, "fixture-ep-001")
        XCTAssertTrue(reloadedCleaning.isChannelCleaningEnabled)
        XCTAssertTrue(reloadedCleaning.isEpisodeCleaningEnabled("fixture-ep-001"))
        XCTAssertEqual(reloadedDownload.state(for: "fixture-ep-001"), .downloaded)
    }

    // MARK: - Task 023: channel cleaning + unrelated default on

    func testNewSubscriptionDefaultsChannelCleaningAndUnrelatedOn() throws {
        let persistence = harness.makeController()
        let podcastStore = PodcastStore(context: persistence.viewContext, retaining: persistence)
        let cleaningStore = CleaningToggleStore(context: persistence.viewContext, retaining: persistence)

        let feed = try FixtureFeedLoader.loadSampleFeed()
        let feedURL = URL(string: "https://fixture.podwash.tests/new-subscription")!
        try podcastStore.save(feed, feedURL: feedURL)

        XCTAssertTrue(
            cleaningStore.isChannelCleaningEnabled(forFeedURL: feedURL),
            "New subscription must default channelCleaningEnabled to true"
        )
        XCTAssertTrue(
            cleaningStore.isChannelUnrelatedContentEnabled(forFeedURL: feedURL),
            "New subscription must default channelUnrelatedContentEnabled to true"
        )
    }

    func testMigrateAllChannelsCleaningAndUnrelatedOn() throws {
        let persistence = harness.makeController()
        let podcastStore = PodcastStore(context: persistence.viewContext, retaining: persistence)
        let cleaningStore = CleaningToggleStore(context: persistence.viewContext, retaining: persistence)

        let feed = try FixtureFeedLoader.loadSampleFeed()
        let feedURLA = URL(string: "https://fixture.podwash.tests/migrate-a")!
        let feedURLB = URL(string: "https://fixture.podwash.tests/migrate-b")!
        try podcastStore.save(feed, feedURL: feedURLA)
        try podcastStore.save(feed, feedURL: feedURLB)

        try cleaningStore.setChannelCleaning(forFeedURL: feedURLA, enabled: false)
        try cleaningStore.setChannelUnrelatedContent(forFeedURL: feedURLA, enabled: false)
        try cleaningStore.setChannelCleaning(forFeedURL: feedURLB, enabled: false)
        try cleaningStore.setChannelUnrelatedContent(forFeedURL: feedURLB, enabled: false)

        XCTAssertFalse(cleaningStore.isChannelCleaningEnabled(forFeedURL: feedURLA))
        XCTAssertFalse(cleaningStore.isChannelUnrelatedContentEnabled(forFeedURL: feedURLA))
        XCTAssertFalse(cleaningStore.isChannelCleaningEnabled(forFeedURL: feedURLB))
        XCTAssertFalse(cleaningStore.isChannelUnrelatedContentEnabled(forFeedURL: feedURLB))

        try cleaningStore.migrateAllChannelsCleaningAndUnrelatedOnIfNeeded()

        for feedURL in [feedURLA, feedURLB] {
            XCTAssertTrue(
                cleaningStore.isChannelCleaningEnabled(forFeedURL: feedURL),
                "Migrate must set channelCleaningEnabled true for \(feedURL.absoluteString)"
            )
            XCTAssertTrue(
                cleaningStore.isChannelUnrelatedContentEnabled(forFeedURL: feedURL),
                "Migrate must set channelUnrelatedContentEnabled true for \(feedURL.absoluteString)"
            )
        }

        try cleaningStore.migrateAllChannelsCleaningAndUnrelatedOnIfNeeded()

        for feedURL in [feedURLA, feedURLB] {
            XCTAssertTrue(cleaningStore.isChannelCleaningEnabled(forFeedURL: feedURL))
            XCTAssertTrue(cleaningStore.isChannelUnrelatedContentEnabled(forFeedURL: feedURL))
        }
    }

    func testFeedRefreshPreservesDownloadStateOnEpisodeRows() throws {
        let persistence = harness.makeController()
        let podcastStore = PodcastStore(context: persistence.viewContext)
        let downloadStore = DownloadStateStore(context: persistence.viewContext)

        let feed = try FixtureFeedLoader.loadSampleFeed()
        try podcastStore.save(feed)
        try downloadStore.setState(.downloaded, for: "fixture-ep-001")

        try podcastStore.save(feed)

        XCTAssertEqual(downloadStore.state(for: "fixture-ep-001"), .downloaded)
    }
}
