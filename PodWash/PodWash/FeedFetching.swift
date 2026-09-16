//
//  FeedFetching.swift
//  PodWash
//
//  Slice 06 — Injectable network boundary for RSS fetch (ADR-004).
//

import Foundation

struct FeedValidators: Codable, Equatable, Sendable {
    var etag: String?
    var lastModified: String?
}

enum FeedFetchResult: Sendable {
    case modified(Data, FeedValidators)
    case notModified(FeedValidators)
}

protocol FeedFetching: Sendable {
    func data(from url: URL) async throws -> Data
    func fetch(from url: URL, validators: FeedValidators?) async throws -> FeedFetchResult
}

extension FeedFetching {
    /// Keeps existing fixtures and protocol conformers source compatible.
    func fetch(from url: URL, validators: FeedValidators?) async throws -> FeedFetchResult {
        .modified(try await data(from: url), FeedValidators(etag: nil, lastModified: nil))
    }
}

struct URLSessionFeedFetcher: FeedFetching {
    let session: URLSession

    init(session: URLSession = .shared) {
        self.session = session
    }

    func data(from url: URL) async throws -> Data {
        switch try await fetch(from: url, validators: nil) {
        case let .modified(data, _): return data
        case .notModified: throw RSSParserError.networkFailure
        }
    }

    func fetch(from url: URL, validators: FeedValidators?) async throws -> FeedFetchResult {
        do {
            var request = URLRequest(url: url)
            request.timeoutInterval = 30
            if let etag = validators?.etag { request.setValue(etag, forHTTPHeaderField: "If-None-Match") }
            if let modified = validators?.lastModified { request.setValue(modified, forHTTPHeaderField: "If-Modified-Since") }
            let (data, response) = try await session.data(for: request)
            guard let httpResponse = response as? HTTPURLResponse else { throw RSSParserError.networkFailure }
            let received = FeedValidators(
                etag: httpResponse.value(forHTTPHeaderField: "ETag"),
                lastModified: httpResponse.value(forHTTPHeaderField: "Last-Modified")
            )
            if httpResponse.statusCode == 304 { return .notModified(received) }
            if !(200 ... 299).contains(httpResponse.statusCode) {
                throw RSSParserError.networkFailure
            }
            return .modified(data, received)
        } catch is RSSParserError {
            throw RSSParserError.networkFailure
        } catch {
            throw RSSParserError.networkFailure
        }
    }
}
