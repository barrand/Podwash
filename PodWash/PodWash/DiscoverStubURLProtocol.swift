//
//  DiscoverStubURLProtocol.swift
//  PodWash
//
//  Slice 22 — App-target URLProtocol for -UITestFixtureDiscover (ADR-014 §8).
//

import Foundation

/// Serves bundled iTunes JSON + sample RSS when FixtureDiscover is enabled.
final class DiscoverStubURLProtocol: URLProtocol {

    override class func canInit(with request: URLRequest) -> Bool { true }

    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        guard let url = request.url else {
            client?.urlProtocol(self, didFailWithError: URLError(.badURL))
            return
        }

        do {
            let (response, data) = try Self.response(for: url)
            client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
            client?.urlProtocol(self, didLoad: data)
            client?.urlProtocolDidFinishLoading(self)
        } catch {
            client?.urlProtocol(self, didFailWithError: error)
        }
    }

    override func stopLoading() {}

    private static func response(for url: URL) throws -> (HTTPURLResponse, Data) {
        if url.host == "itunes.apple.com", url.path == "/search" {
            let items = URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems ?? []
            let term = items.first(where: { $0.name == "term" })?.value ?? ""

            let payload: Data
            if term == "podcast" {
                payload = try bundledData(name: "itunes_popular_response", extension: "json", subdirectory: "Fixtures/itunes")
            } else if term == "fixture-query" {
                payload = try bundledData(name: "itunes_search_response", extension: "json", subdirectory: "Fixtures/itunes")
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
            if url.path.contains("/feeds/") || url.path.contains("sample-feed") {
                let payload = try bundledData(name: "sample_feed", extension: "xml", subdirectory: "Fixtures/feeds")
                let response = HTTPURLResponse(
                    url: url,
                    statusCode: 200,
                    httpVersion: "HTTP/1.1",
                    headerFields: ["Content-Type": "application/rss+xml"]
                )!
                return (response, payload)
            }
            // Artwork and other fixture assets: empty 404 (no live network).
            let response = HTTPURLResponse(
                url: url,
                statusCode: 404,
                httpVersion: "HTTP/1.1",
                headerFields: nil
            )!
            return (response, Data())
        }

        throw URLError(.unsupportedURL)
    }

    private static func bundledData(
        name: String,
        extension ext: String,
        subdirectory: String
    ) throws -> Data {
        let bundle = Bundle.main
        if let url = bundle.url(forResource: name, withExtension: ext, subdirectory: subdirectory)
            ?? bundle.url(forResource: name, withExtension: ext) {
            return try Data(contentsOf: url)
        }
        throw URLError(.fileDoesNotExist)
    }
}
