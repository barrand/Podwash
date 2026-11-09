import Foundation

/// Exercises the real download/planner/shell path with deterministic work duration.
enum FixtureBackgroundActivity {
    static var isEnabled: Bool {
        ProcessInfo.processInfo.arguments.contains("-UITestFixtureBackgroundActivity")
    }
    static var fails: Bool {
        ProcessInfo.processInfo.arguments.contains("-UITestFixtureBackgroundActivityFailure")
    }

    static func makeAnalyzer() -> any EpisodeAnalyzing {
        if fails { return FailingAnalyzer() }
        return SteppedEpisodeAnalyzer(snapshots: FixtureAnalysisTimeline.pinnedSnapshots,
            pacing: ImmediateAnalysisProgressPacing(), firstSnapshotHold: .seconds(12))
    }

    private final class FailingAnalyzer: EpisodeAnalyzing, @unchecked Sendable {
        func analyze(episode: EpisodeIdentity, audioURL: URL, targetWords: Set<String>,
                     injectedTranscript: [TimedWord]?) async throws -> [CensorInterval] {
            try await Task.sleep(for: .seconds(1))
            throw CocoaError(.fileReadCorruptFile)
        }
    }
}
