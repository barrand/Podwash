//
//  FixtureProgressivePlayback.swift
//  PodWash
//
//  Slice 25 — Launch-argument progressive playback UITest fixture (ADR-021 §5).
//

import Foundation

enum FixtureProgressivePlayback {
    static let launchArgument = "-UITestFixtureProgressivePlayback"
    static let freezeArgumentPrefix = "-UITestFixtureProgressivePlaybackFreezeAt"

    static let episodeDuration = 120.0
    static let segmentCount = 12
    static let bucketWidth = 10.0
    static let audioResourceName = "progressive-120s"
    static let audioResourceExtension = "m4a"

    /// Partial mute intervals for first chunk (end ≤ 30). Matches progressive golden.
    static let firstChunkPartialIntervals: [CensorInterval] = [
        CensorInterval(start: 0.92, end: 1.87, action: .mute, source: .profanity),
        CensorInterval(start: 2.92, end: 3.32, action: .mute, source: .profanity),
    ]

    static var isEnabled: Bool {
        ProcessInfo.processInfo.arguments.contains { argument in
            argument == launchArgument || argument.hasSuffix("UITestFixtureProgressivePlayback")
        }
    }

    /// When set, stepped analyzer holds after the matching mid-run snapshot (AC5).
    static var freezeAtProcessedEnd: Double? {
        for argument in ProcessInfo.processInfo.arguments {
            guard argument.hasPrefix(freezeArgumentPrefix) else { continue }
            let raw = String(argument.dropFirst(freezeArgumentPrefix.count))
            if let value = Double(raw) { return value }
        }
        return nil
    }

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

    static func bundledURL(in bundle: Bundle = .main) -> URL? {
        bundle.url(
            forResource: audioResourceName,
            withExtension: audioResourceExtension,
            subdirectory: "Fixtures/audio"
        ) ?? bundle.url(forResource: audioResourceName, withExtension: audioResourceExtension)
            ?? FixtureAudio.bundledURL(in: bundle)
    }

    static func makeSteppedAnalyzer(
        pacing: any AnalysisProgressPacing = FixtureAnalysisProgressPacing(delayNanoseconds: 400_000_000)
    ) -> SteppedEpisodeAnalyzer {
        // Hold first chunk long enough for Library → full-player navigation + AC3 poll,
        // but short enough that mid (AC5, 5 s wait) and terminal (AC4, 10 s) still arrive.
        // When FreezeAt is set (seek-clamp tests), skip the long hold so mid-run is reachable
        // within the 5 s AX poll — mini-player navigation is faster than full-player expand,
        // so the wait often starts while the 7 s first-chunk hold is still active.
        let firstHold: Duration? = freezeAtProcessedEnd == nil ? .seconds(7) : nil
        return SteppedEpisodeAnalyzer(
            snapshots: pinnedSnapshots,
            pacing: pacing,
            partialIntervalsBySnapshot: [
                firstChunkPartialIntervals,
                [],
                [],
            ],
            freezeAtProcessedEnd: freezeAtProcessedEnd,
            firstSnapshotHold: firstHold
        )
    }
}
