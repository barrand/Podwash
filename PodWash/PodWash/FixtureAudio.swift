//
//  FixtureAudio.swift
//  PodWash
//
//  Slice 03 — Launch-argument fixture mode for UI tests (ADR-001).
//

import Foundation

enum FixtureAudio {
    static let launchArgument = "-UITestFixtureAudio"

    static var isEnabled: Bool {
        ProcessInfo.processInfo.arguments.contains(launchArgument)
    }

    static func bundledURL(in bundle: Bundle = .main) -> URL? {
        bundle.url(forResource: "test-clip", withExtension: "m4a")
    }

    static let fixtureTitle = "Fixture Clip"
    static let fixtureArtist = "PodWash Tests"
}
