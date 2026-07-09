//
//  FixtureAnalysis.swift
//  PodWash
//
//  Slice 09 — Launch-argument stub for instant analysis in UI tests (slice-09-ux.md).
//

import Foundation

enum FixtureAnalysis {
    static let launchArgument = "-UITestFixtureAnalysis"

    static var isEnabled: Bool {
        ProcessInfo.processInfo.arguments.contains { argument in
            argument == launchArgument || argument.hasSuffix("UITestFixtureAnalysis")
        }
    }
}
