//
//  ProductionAnalyzerFactory.swift
//  PodWash
//
//  Slice 24 — Production AnalysisPipeline vs Instant stub (ADR-020 §3–§4).
//  Slice 28 — dual-SDK pin, compute split, pin-mismatch wipe (ADR-024 §5).
//

import Foundation

enum ProductionAnalyzerFactory {
    /// Fixture shell / exclusive UITest modes → Instant. Production → AnalysisPipeline.
    /// - Parameter fixtureLibraryMode: when non-nil, overrides ProcessInfo-backed
    ///   `FixtureLibrary.isEnabled` / `isEmptyEnabled` for analyzer choice (unit tests).
    ///   `nil` = read real launch args (production / UITest).
    /// - Parameter compute: when non-nil, overrides platform default compute preference.
    static func makeAnalyzer(
        bundle: Bundle = .main,
        cacheBaseDirectory: URL? = nil,
        fixtureLibraryMode: Bool? = nil,
        compute: ASRComputePreference? = nil
    ) -> any EpisodeAnalyzing {
        let effectiveFixtureLibrary = fixtureLibraryMode
            ?? (FixtureLibrary.isEnabled
                || FixtureLibrary.isEmptyEnabled
                || FixtureProgressivePlayback.isEnabled
                || FixtureTranscript.isAnyEnabled
                || FixtureMuteMarkers.isAnyEnabled)

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
            // FixtureMuteMarkers + other Library fixtures: Instant (seeds mute/ad intervals when enabled).
            return InstantEpisodeAnalyzer()
        }

        // When caller did not override, keep Instant for exclusive RootView fixture shells.
        if fixtureLibraryMode == nil, exclusiveRootViewFixtureModeActive {
            return InstantEpisodeAnalyzer()
        }

        do {
            return try makeProductionPipeline(
                bundle: bundle,
                cacheBaseDirectory: cacheBaseDirectory,
                compute: compute
            )
        } catch {
            preconditionFailure(
                "Production analyzer requires bundled Whisper model: \(error). Run scripts/setup-asr-models.sh per ADR-024."
            )
        }
    }

    /// Simulator → explicit cpuOnly; device → WhisperKit defaults (ANE-capable).
    static func defaultComputePreference() -> ASRComputePreference {
        #if targetEnvironment(simulator)
        return .cpuOnly
        #else
        return .whisperKitDefault
        #endif
    }

    /// Explicit production path (AC2 / AC5). Must not return InstantEpisodeAnalyzer.
    static func makeProductionPipeline(
        bundle: Bundle = .main,
        cacheBaseDirectory: URL? = nil,
        compute: ASRComputePreference? = nil
    ) throws -> AnalysisPipeline {
        let pin = try WhisperModelLocator.logicalPin(in: bundle)
        let folder = try WhisperModelLocator.resolvedModelFolder(in: bundle)

        let supportRoot: URL
        let intervalCacheDir: URL
        let transcriptCacheDir: URL
        if let cacheBaseDirectory {
            supportRoot = cacheBaseDirectory
            intervalCacheDir = cacheBaseDirectory.appendingPathComponent("IntervalCache", isDirectory: true)
            transcriptCacheDir = cacheBaseDirectory.appendingPathComponent("TranscriptCache", isDirectory: true)
        } else {
            supportRoot = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
            intervalCacheDir = supportRoot.appendingPathComponent("IntervalCache", isDirectory: true)
            transcriptCacheDir = supportRoot.appendingPathComponent("TranscriptCache", isDirectory: true)
        }

        try ASRModelPinStore.reconcile(
            bundledPin: pin,
            storedPinURL: ASRModelPinStore.storedPinURL(applicationSupport: supportRoot),
            intervalCacheDirectory: intervalCacheDir,
            transcriptCacheDirectory: transcriptCacheDir
        )

        let resolvedCompute = compute ?? defaultComputePreference()
        let transcriber = WhisperKitASRTranscriber(modelFolder: folder, compute: resolvedCompute)
        let cache = IntervalCache(baseDirectory: intervalCacheDir, asrModelPin: pin)
        let transcriptCache = TranscriptCache(baseDirectory: transcriptCacheDir)
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
