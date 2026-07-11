//
//  FixtureDiscover.swift
//  PodWash
//
//  Slice 22 — Launch-argument fixture mode for Discover UI tests (ADR-014 §8).
//

import Foundation

enum FixtureDiscover {
    static let launchArgument = "-UITestFixtureDiscover"

    static var isEnabled: Bool {
        ProcessInfo.processInfo.arguments.contains(launchArgument)
    }

    static func makeStubbedSession() -> URLSession {
        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [DiscoverStubURLProtocol.self]
        return URLSession(configuration: config)
    }

    static func makeSearchClient() -> ITunesSearchClient {
        ITunesSearchClient(session: makeStubbedSession())
    }

    static func makeParser() -> RSSParser {
        RSSParser(session: makeStubbedSession())
    }
}
