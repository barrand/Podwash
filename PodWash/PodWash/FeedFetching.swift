//
//  FeedFetching.swift
//  PodWash
//
//  Slice 06 — Injectable network boundary for RSS fetch (ADR-004).
//

import Foundation

protocol FeedFetching: Sendable {
    func data(from url: URL) async throws -> Data
}

struct URLSessionFeedFetcher: FeedFetching {
    let session: URLSession

    init(session: URLSession = .shared) {
        self.session = session
    }

    func data(from url: URL) async throws -> Data {
        do {
            let (data, response) = try await session.data(from: url)
            if let httpResponse = response as? HTTPURLResponse,
               !(200 ... 299).contains(httpResponse.statusCode) {
                throw RSSParserError.networkFailure
            }
            return data
        } catch is RSSParserError {
            throw RSSParserError.networkFailure
        } catch {
            throw RSSParserError.networkFailure
        }
    }
}
