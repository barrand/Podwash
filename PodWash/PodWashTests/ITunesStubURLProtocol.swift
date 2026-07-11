//
//  ITunesStubURLProtocol.swift
//  PodWashTests
//
//  Slice 22 — Offline iTunes + RSS transport stub (ADR-014 §8).
//

import Foundation

/// Serves hand-authored iTunes JSON and paired RSS fixtures; no live network.
final class ITunesStubURLProtocol: URLProtocol {

    nonisolated(unsafe) static var requestHandler: ((URLRequest) throws -> (HTTPURLResponse, Data))?
    nonisolated(unsafe) static var requestCount = 0

    override class func canInit(with request: URLRequest) -> Bool { true }

    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        Self.requestCount += 1
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

    static func reset() {
        requestHandler = nil
        requestCount = 0
    }

    /// Default handler: popular JSON, search JSON for `fixture-query`, RSS by feed URL.
    static func defaultHandler() -> (URLRequest) throws -> (HTTPURLResponse, Data) {
        let popularData = try ITunesGoldenFixtures.fixtureData("itunes_popular_response", extension: "json")
        let searchData = try ITunesGoldenFixtures.fixtureData("itunes_search_response", extension: "json")

        return { request in
            guard let url = request.url else {
                throw URLError(.badURL)
            }

            if url.host == "itunes.apple.com", url.path == "/search" {
                let items = URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems ?? []
                let term = items.first(where: { $0.name == "term" })?.value ?? ""

                let payload: Data
                if term == "podcast" {
                    payload = popularData
                } else if term == ITunesGoldenFixtures.pinnedSearchTerm {
                    payload = searchData
                } else {
                    payload = Data("{\"resultCount\":0,\"results\":[]}".utf8)
                }

                let response = HTTPURLResponse(
                    url: url,
                    statusCode: 200,
                    httpVersion: "HTTP/1.1",
                    headerFields: ["Content-Type": "application/json"]
                )!
                return (response, payload)
            }

            if url.host == "fixture.podwash.tests" {
                let payload = try ITunesGoldenFixtures.rssPayload(for: url)
                let response = HTTPURLResponse(
                    url: url,
                    statusCode: 200,
                    httpVersion: "HTTP/1.1",
                    headerFields: ["Content-Type": "application/rss+xml"]
                )!
                return (response, payload)
            }

            throw URLError(.unsupportedURL)
        }
    }

    static func makeStubbedSession() -> URLSession {
        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [ITunesStubURLProtocol.self]
        return URLSession(configuration: config)
    }
}
