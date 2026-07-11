//
//  FixtureSkipOverride.swift
//  PodWash
//
//  Slice 19 — Launch-argument fixture for skip-override UI tests (ADR-013 §3.6).
//

import Foundation

enum FixtureSkipOverride {
    static let launchArgument = "-UITestFixtureSkipOverride"

    /// Stub unrelated-content skip interval for the fixture player.
    static let stubSkipInterval = CensorInterval(
        start: 2.0,
        end: 5.0,
        action: .skip,
        source: .unrelatedContent
    )

    nonisolated static var isEnabled: Bool {
        ProcessInfo.processInfo.arguments.contains { argument in
            argument == launchArgument || argument.hasSuffix("UITestFixtureSkipOverride")
        }
    }

    /// Reuses the bundled local clip (no network/ASR). Longer than the stub span.
    static func bundledURL(in bundle: Bundle = .main) -> URL? {
        bundle.url(forResource: "test-clip", withExtension: "m4a")
            ?? FixtureAudio.bundledURL(in: bundle)
    }

    static let fixtureTitle = "Skip Override Fixture"
    static let fixtureArtist = "PodWash Tests"
}
