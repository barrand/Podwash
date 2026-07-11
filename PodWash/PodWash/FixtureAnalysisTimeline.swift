//
//  FixtureAnalysisTimeline.swift
//  PodWash
//
//  Slice 20 — Launch-argument fixture for stepped analysis timeline UITests (ADR-018).
//

import Foundation

enum FixtureAnalysisTimeline {
    static let launchArgument = "-UITestFixtureAnalysisTimeline"

    static let episodeDuration = 120.0
    static let segmentCount = 12
    static let bucketWidth = 10.0

    static var isEnabled: Bool {
        ProcessInfo.processInfo.arguments.contains { argument in
            argument == launchArgument || argument.hasSuffix("UITestFixtureAnalysisTimeline")
        }
    }

    /// Pinned stepped snapshots (slice-20 fixture strategy / ADR-018 §4).
    static var pinnedSnapshots: [AnalysisProgressSnapshot] {
        [
            AnalysisProgressSnapshot(
                episodeDuration: episodeDuration,
                processedEnd: 30.0,
                processingStart: 30.0,
                processingEnd: 40.0,
                adRanges: []
            ),
            AnalysisProgressSnapshot(
                episodeDuration: episodeDuration,
                processedEnd: 60.0,
                processingStart: 60.0,
                processingEnd: 70.0,
                adRanges: []
            ),
            AnalysisProgressSnapshot(
                episodeDuration: episodeDuration,
                processedEnd: 120.0,
                processingStart: 120.0,
                processingEnd: 120.0,
                adRanges: []
            ),
        ]
    }

    static func makeSteppedAnalyzer(
        pacing: any AnalysisProgressPacing = FixtureAnalysisProgressPacing()
    ) -> SteppedEpisodeAnalyzer {
        SteppedEpisodeAnalyzer(snapshots: pinnedSnapshots, pacing: pacing)
    }
}
