//
//  EpisodeListViewModelTests.swift
//  PodWashTests
//
//  Slice 06 — Episode list view model unit tests (ADR-004). AC5.
//

import XCTest
@testable import PodWash

// MARK: - URLProtocol stub (injected transport; no live network)

final class FeedStubURLProtocol: URLProtocol {
    nonisolated(unsafe) static var requestHandler: ((URLRequest) throws -> (HTTPURLResponse, Data))?

    override class func canInit(with request: URLRequest) -> Bool { true }

    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        guard let handler = Self.requestHandler else {
            client?.urlProtocol(self, didFailWithError: URLError(.unknown))
            return
        }
        do {
            let (response, data) = try handler(request)
            client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
            client?.urlProtocol(self, didLoad: data)
            client?.urlProtocolDidFinishLoading(self)
        } catch {
            client?.urlProtocol(self, didFailWithError: error)
        }
    }

    override func stopLoading() {}
}

@MainActor
final class EpisodeListViewModelTests: XCTestCase {

    private func makeStubbedSession() -> URLSession {
        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [FeedStubURLProtocol.self]
        return URLSession(configuration: config)
    }

    override func tearDown() {
        FeedStubURLProtocol.requestHandler = nil
        super.tearDown()
    }

    // MARK: - AC5: network failure surfaces typed error state

    func testNetworkFailureErrorState() async {
        FeedStubURLProtocol.requestHandler = { _ in
            throw URLError(.notConnectedToInternet)
        }

        let session = makeStubbedSession()
        let parser = RSSParser(session: session)
        let store = InMemoryPodcastStore()
        let viewModel = EpisodeListViewModel(parser: parser, store: store)

        let feedURL = URL(string: "https://fixture.podwash.tests/remote-feed")!
        await viewModel.load(feedURL: feedURL)

        XCTAssertEqual(viewModel.phase, .failed(.networkFailure))
    }
}
