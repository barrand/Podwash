//
//  FixtureFeed.swift
//  PodWash
//
//  Slice 06 — Launch-argument fixture mode for episode-list UI tests (ADR-004).
//

import Foundation

enum FixtureFeed {
    static let launchArgument = "-UITestFixtureFeed"

    static var isEnabled: Bool {
        ProcessInfo.processInfo.arguments.contains(launchArgument)
    }

    static func bundledData(in bundle: Bundle = .main) -> Data? {
        guard let url = bundledURL(in: bundle) else { return nil }
        return try? Data(contentsOf: url)
    }

    static func bundledURL(in bundle: Bundle = .main) -> URL? {
        bundle.url(forResource: "sample_feed", withExtension: "xml", subdirectory: "Fixtures/feeds")
            ?? bundle.url(forResource: "sample_feed", withExtension: "xml")
    }

    static let fixtureFeedURL = URL(string: "https://fixture.podwash.tests/sample-feed")!
}
