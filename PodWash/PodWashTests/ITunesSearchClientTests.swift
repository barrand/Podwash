//
//  ITunesSearchClientTests.swift
//  PodWashTests
//
//  Slice 22 — iTunes Search client unit tests (ADR-014). AC1–AC2.
//

import XCTest
@testable import PodWash

final class ITunesSearchClientTests: XCTestCase {

    override func tearDown() {
        ITunesStubURLProtocol.reset()
        super.tearDown()
    }

    // MARK: - AC1: fetchPopular matches golden JSON

    func testFetchPopularMatchesGolden() async throws {
        ITunesStubURLProtocol.requestHandler = try ITunesStubURLProtocol.defaultHandler()
        let session = ITunesStubURLProtocol.makeStubbedSession()
        let client = ITunesSearchClient(session: session)

        let golden = try ITunesGoldenFixtures.loadPopularGolden()
        let results = try await client.fetchPopular()

        XCTAssertEqual(results.count, 3)
        for index in 0 ..< 3 {
            XCTAssertEqual(results[index].title, golden.results[index].collectionName)
            XCTAssertEqual(
                results[index].feedURL.absoluteString,
                golden.results[index].feedUrl
            )
        }
    }

    // MARK: - AC2: search term matches golden; empty term short-circuits

    func testSearchTermMatchesGolden() async throws {
        ITunesStubURLProtocol.requestHandler = try ITunesStubURLProtocol.defaultHandler()
        let session = ITunesStubURLProtocol.makeStubbedSession()
        let client = ITunesSearchClient(session: session)

        let golden = try ITunesGoldenFixtures.loadSearchGolden()
        let beforeCount = ITunesStubURLProtocol.requestCount

        let results = try await client.search(term: ITunesGoldenFixtures.pinnedSearchTerm)

        XCTAssertEqual(results.count, 2)
        for index in 0 ..< 2 {
            XCTAssertEqual(results[index].title, golden.results[index].collectionName)
            XCTAssertEqual(
                results[index].feedURL.absoluteString,
                golden.results[index].feedUrl
            )
        }

        let emptyResults = try await client.search(term: "")
        XCTAssertEqual(emptyResults.count, 0)
        XCTAssertEqual(ITunesStubURLProtocol.requestCount, beforeCount + 1)
    }
}
