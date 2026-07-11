//
//  DiscoverViewModelTests.swift
//  PodWashTests
//
//  Slice 22 — Discover subscribe orchestration (ADR-014 §6). AC5.
//

import XCTest
@testable import PodWash

@MainActor
final class DiscoverViewModelTests: XCTestCase {

    override func tearDown() {
        ITunesStubURLProtocol.reset()
        super.tearDown()
    }

    // MARK: - AC5: subscribe persists feed; RSS failure surfaces typed .failed

    func testSubscribePersistsFeedAndSurfacesFailure() async throws {
        ITunesStubURLProtocol.requestHandler = try ITunesStubURLProtocol.defaultHandler()
        let session = ITunesStubURLProtocol.makeStubbedSession()

        let persistence = PersistenceController.inMemory()
        let store = PodcastStore(context: persistence.viewContext, retaining: persistence)
        let searchClient = ITunesSearchClient(session: session)
        let parser = RSSParser(session: session)

        let viewModel = DiscoverViewModel(
            searchClient: searchClient,
            parser: parser,
            store: store,
            searchDebounceNanoseconds: 0
        )

        await viewModel.loadPopular()
        let golden = try ITunesGoldenFixtures.popularResults()[0]

        await viewModel.subscribe(atIndex: 0)

        XCTAssertTrue(store.isSubscribed(feedURL: golden.feedURL))
        XCTAssertEqual(store.subscription(forFeedURL: golden.feedURL)?.episodes.count, 5)

        // RSS failure branch: stub throws on feed fetch.
        ITunesStubURLProtocol.requestHandler = { request in
            guard let url = request.url, url.host == "fixture.podwash.tests" else {
                return try ITunesStubURLProtocol.defaultHandler()(request)
            }
            throw URLError(.notConnectedToInternet)
        }

        let failureStore = PodcastStore(context: PersistenceController.inMemory().viewContext)
        let failureViewModel = DiscoverViewModel(
            searchClient: searchClient,
            parser: RSSParser(session: session),
            store: failureStore,
            searchDebounceNanoseconds: 0
        )

        await failureViewModel.loadPopular()
        await failureViewModel.subscribe(atIndex: 0)

        XCTAssertEqual(failureViewModel.subscribeState, .failed)
        XCTAssertFalse(failureStore.isSubscribed(feedURL: golden.feedURL))
    }
}
