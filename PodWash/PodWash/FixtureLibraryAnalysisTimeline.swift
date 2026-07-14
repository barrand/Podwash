//
//  FixtureLibraryAnalysisTimeline.swift
//  PodWash
//
//  Task 011 — Play-time analysis timeline fixture for Library player chrome UITests.
//  Parallel to `-UITestFixtureAnalysisTimeline` (episode rows) but drives
//  `miniPlayerAnalysisTimeline` / `playbackAnalysisTimeline` via `AppShellModel`.
//

import Foundation

enum FixtureLibraryAnalysisTimeline {
    static let launchArgument = "-UITestFixtureLibraryAnalysisTimeline"

    static var isEnabled: Bool {
        ProcessInfo.processInfo.arguments.contains { argument in
            argument == launchArgument || argument.hasSuffix("UITestFixtureLibraryAnalysisTimeline")
        }
    }

    /// Stepped analyzer pinned to terminal `ready:12,processing:0,pending:0`.
    static func makeSteppedAnalyzer(
        pacing: any AnalysisProgressPacing = FixtureAnalysisProgressPacing()
    ) -> SteppedEpisodeAnalyzer {
        FixtureAnalysisTimeline.makeSteppedAnalyzer(pacing: pacing)
    }
}
