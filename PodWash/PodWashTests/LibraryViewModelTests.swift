//
//  LibraryViewModelTests.swift
//  PodWashTests
//
//  Slice 23 — Library subscription list (ADR-015 §3). AC1.
//
//  Golden titles hand-transcribed from Fixtures/itunes/itunes_popular_response.json
//  entries 0–1 (independent provenance; see Fixtures/itunes/README.md).
//  Until LibraryViewModel exists (Engineer), this file fails to compile — TDD red.
//

import XCTest
@testable import PodWash

@MainActor
final class LibraryViewModelTests: XCTestCase {

    // Hand-transcribed from itunes_popular_response.json (Slice 22 golden; independent).
    private let goldenTitle0 = "Fixture Popular Alpha"
    private let goldenTitle1 = "Fixture Popular Beta"

    private var harness: PersistenceReloadHarness!

    override func setUp() {
        super.setUp()
        harness = PersistenceReloadHarness()
    }

    override func tearDown() {
        harness = nil
        super.tearDown()
    }

    // MARK: - AC1: subscription count + exact title order; survives reload

    func testLibraryListsAllSubscriptionsAfterReload() throws {
        let persistence = harness.makeController()
        let store = PodcastStore(context: persistence.viewContext, retaining: persistence)
        try seedTwoGoldenSubscriptions(into: store)

        let viewModel = LibraryViewModel(store: store)
        viewModel.reload()

        XCTAssertEqual(viewModel.subscriptionCount, 2)
        XCTAssertEqual(viewModel.titles, [goldenTitle0, goldenTitle1])

        try persistence.save()

        let reloaded = harness.makeController()
        let reloadedStore = PodcastStore(context: reloaded.viewContext, retaining: reloaded)
        let reloadedViewModel = LibraryViewModel(store: reloadedStore)
        reloadedViewModel.reload()

        XCTAssertEqual(reloadedViewModel.subscriptionCount, 2)
        XCTAssertEqual(reloadedViewModel.titles, [goldenTitle0, goldenTitle1])
    }

    // MARK: - Seed helpers

    private func seedTwoGoldenSubscriptions(into store: PodcastStore) throws {
        let parser = RSSParser()
        let goldenPopular = try ITunesGoldenFixtures.popularResults()

        let feedA = try parser.parse(data: try ITunesGoldenFixtures.rssPayload(for: goldenPopular[0].feedURL))
        try store.saveSubscription(from: goldenPopular[0], feed: feedA)

        let feedB = try parser.parse(data: try ITunesGoldenFixtures.rssPayload(for: goldenPopular[1].feedURL))
        try store.saveSubscription(from: goldenPopular[1], feed: feedB)
    }
}
