//
//  ProductionAnalyzerFactory.swift
//  PodWash
//
//  Slice 24 — Production AnalysisPipeline vs Instant stub (ADR-020 §3–§4).
//

import Foundation

enum ProductionAnalyzerFactory {
    /// Fixture shell / exclusive UITest modes → Instant. Production → AnalysisPipeline.
    /// - Parameter fixtureLibraryMode: when non-nil, overrides ProcessInfo-backed
    ///   `FixtureLibrary.isEnabled` / `isEmptyEnabled` for analyzer choice (unit tests).
    ///   `nil` = read real launch args (production / UITest).
    static func makeAnalyzer(
        bundle: Bundle = .main,
        cacheBaseDirectory: URL? = nil,
        fixtureLibraryMode: Bool? = nil
    ) -> any EpisodeAnalyzing {
        let effectiveFixtureLibrary = fixtureLibraryMode
            ?? (FixtureLibrary.isEnabled
                || FixtureLibrary.isEmptyEnabled
                || FixtureProgressivePlayback.isEnabled
                || FixtureTranscript.isAnyEnabled)

        if effectiveFixtureLibrary {
            if FixtureProgressivePlayback.isEnabled {
                return FixtureProgressivePlayback.makeSteppedAnalyzer()
            }
            if FixtureLibraryAnalysisTimeline.isEnabled {
                return FixtureLibraryAnalysisTimeline.makeSteppedAnalyzer()
            }
            if FixtureTranscript.isNoCacheEnabled {
                return FixtureTranscript.makeAnalyzer()
            }
            return InstantEpisodeAnalyzer()
        }

        // When caller did not override, keep Instant for exclusive RootView fixture shells.
        if fixtureLibraryMode == nil, exclusiveRootViewFixtureModeActive {
            return InstantEpisodeAnalyzer()
        }

        do {
            return try makeProductionPipeline(
                bundle: bundle,
                cacheBaseDirectory: cacheBaseDirectory
            )
        } catch {
            preconditionFailure(
                "Production analyzer requires bundled Whisper model: \(error). Run scripts/setup-asr-models.sh per ADR-020."
            )
        }
    }

    /// Explicit production path (AC2). Must not return InstantEpisodeAnalyzer.
    static func makeProductionPipeline(
        bundle: Bundle = .main,
        cacheBaseDirectory: URL? = nil
    ) throws -> AnalysisPipeline {
        let folder = try WhisperModelLocator.resolvedModelFolder(in: bundle)
        let transcriber = WhisperKitASRTranscriber(modelFolder: folder)
        let cache: IntervalCache
        let transcriptCache: TranscriptCache
        if let cacheBaseDirectory {
            cache = IntervalCache(baseDirectory: cacheBaseDirectory)
            transcriptCache = TranscriptCache(
                baseDirectory: cacheBaseDirectory.appendingPathComponent("TranscriptCache", isDirectory: true)
            )
        } else {
            cache = .applicationSupport
            transcriptCache = .applicationSupport
        }
        return AnalysisPipeline(
            transcriber: transcriber,
            cache: cache,
            transcriptCache: transcriptCache
        )
    }

    /// Exclusive RootView UITest fixtures that keep Instant / stepped analyzers locally.
    private static var exclusiveRootViewFixtureModeActive: Bool {
        FixtureAnalysis.isEnabled
            || FixtureAnalysisTimeline.isEnabled
            || FixtureFeed.isEnabled
            || FixtureQueue.isEnabled
            || FixtureQueue.shouldPreserveOnLaunch
            || FixtureSkipOverride.isEnabled
            || FixtureSettings.isEnabled
            || FixtureBranding.isEnabled
            || FixtureAudio.isEnabled
            || FixtureDiscover.isEnabled
    }
}
