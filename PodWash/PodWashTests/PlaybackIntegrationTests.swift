//
//  PlaybackIntegrationTests.swift
//  PodWashTests
//
//  Slice 08 — Playback integration (ADR-006). AC1–AC4: cache → scheduler → engine
//  wiring, offline RMS, action toggle without reanalysis, empty-interval path.
//

import AVFoundation
import XCTest
@testable import PodWash

/// Wraps AnalysisPipeline and counts analyze invocations (ADR-006 §5).
final class PipelineAnalyzeSpy: EpisodeAnalyzing, @unchecked Sendable {
    private(set) var analyzeCallCount = 0
    private let inner: AnalysisPipeline

    init(inner: AnalysisPipeline) {
        self.inner = inner
    }

    func analyze(
        episode: EpisodeIdentity,
        audioURL: URL,
        targetWords: Set<String>,
        injectedTranscript: [TimedWord]?
    ) async throws -> [CensorInterval] {
        analyzeCallCount += 1
        return try await inner.analyze(
            episode: episode,
            audioURL: audioURL,
            targetWords: targetWords,
            injectedTranscript: injectedTranscript
        )
    }
}

@MainActor
final class PlaybackIntegrationTests: XCTestCase {

    private let episodeID = "fixture-spec-section8"
    private let fullTargetSet: Set<String> = ["shit", "damn"]
    private let boundaryTolerance = 0.001
    private let pipelineTolerance = 0.0005
    private let sineFixtureName = "sine-300hz-5s"
    private let sineFixtureExt = "wav"

    private var cacheDir: URL!
    private var spy: ASRSpyTranscriber!
    private var pipeline: AnalysisPipeline!
    private var pipelineSpy: PipelineAnalyzeSpy!

    private var innerProjectDir: URL {
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
    }

    override func setUp() async throws {
        cacheDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("PlaybackIntegration-\(UUID().uuidString)", isDirectory: true)
        spy = ASRSpyTranscriber()
        pipeline = AnalysisPipeline(
            transcriber: spy,
            cache: IntervalCache(baseDirectory: cacheDir)
        )
        pipelineSpy = PipelineAnalyzeSpy(inner: pipeline)
    }

    override func tearDown() async throws {
        try? IntervalCache(baseDirectory: cacheDir).clear()
    }

    // MARK: - Fixture helpers

    private struct GoldenInterval: Decodable {
        let start: Double
        let end: Double
    }

    private func fixtureData(_ name: String, subdirectory: String) throws -> Data {
        let bundle = Bundle(for: type(of: self))
        if let url = bundle.url(forResource: name, withExtension: "json", subdirectory: subdirectory)
            ?? bundle.url(forResource: name, withExtension: "json") {
            return try Data(contentsOf: url)
        }
        let sourceURL = innerProjectDir
            .appendingPathComponent("PodWashTests/Fixtures/\(subdirectory)/\(name).json")
        return try Data(contentsOf: sourceURL)
    }

    private func loadTranscript() throws -> [TimedWord] {
        try JSONDecoder().decode([TimedWord].self, from: try fixtureData("spec-section8.input", subdirectory: "transcripts"))
    }

    private func loadGoldenE2E() throws -> [GoldenInterval] {
        try JSONDecoder().decode([GoldenInterval].self, from: try fixtureData("e2e_intervals", subdirectory: "analysis"))
    }

    private func dummyAudioURL() -> URL {
        innerProjectDir.appendingPathComponent("PodWashTests/Fixtures/asr/speech-pangram.wav")
    }

    private func sineFixtureURL(file: StaticString = #filePath, line: UInt = #line) -> URL {
        let bundle = Bundle(for: type(of: self))
        guard let bundledURL = bundle.url(forResource: sineFixtureName, withExtension: sineFixtureExt, subdirectory: "Fixtures/audio")
            ?? bundle.url(forResource: sineFixtureName, withExtension: sineFixtureExt) else {
            XCTFail("Missing \(sineFixtureName).\(sineFixtureExt)", file: file, line: line)
            return URL(fileURLWithPath: "/dev/null")
        }
        let tempURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("podwash-playback-\(sineFixtureName).\(sineFixtureExt)")
        try? FileManager.default.removeItem(at: tempURL)
        do {
            try FileManager.default.copyItem(at: bundledURL, to: tempURL)
        } catch {
            XCTFail("Could not copy sine fixture: \(error)", file: file, line: line)
            return bundledURL
        }
        return tempURL
    }

    private func makeCoordinator(audioURL: URL) -> (PlaybackCoordinator, PlaybackEngine) {
        let engine = PlaybackEngine(url: audioURL, title: "Integration", artist: "PodWash QA")
        let coordinator = PlaybackCoordinator(pipeline: pipelineSpy, engine: engine)
        return (coordinator, engine)
    }

    private func assertBoundary(
        _ value: TimeInterval,
        near expected: TimeInterval,
        label: String,
        file: StaticString = #filePath,
        line: UInt = #line
    ) {
        XCTAssertEqual(value, expected, accuracy: boundaryTolerance, "\(label)", file: file, line: line)
    }

    // MARK: - AC1: cached intervals configure audioMix ramp boundaries

    func testCachedIntervalsConfigureAudioMix() async throws {
        let audioURL = sineFixtureURL()
        let (coordinator, engine) = makeCoordinator(audioURL: audioURL)
        let transcript = try loadTranscript()
        let golden = try loadGoldenE2E()

        try await coordinator.preparePlayback(
            episode: EpisodeIdentity(id: episodeID),
            audioURL: dummyAudioURL(),
            targetWords: fullTargetSet,
            action: .mute,
            injectedTranscript: transcript
        )

        XCTAssertEqual(coordinator.cachedIntervals.count, golden.count)
        for (index, pair) in zip(coordinator.cachedIntervals, golden).enumerated() {
            XCTAssertEqual(pair.0.start, pair.1.start, accuracy: pipelineTolerance, "start \(index)")
            XCTAssertEqual(pair.0.end, pair.1.end, accuracy: pipelineTolerance, "end \(index)")
        }

        guard let mix = engine.avPlayer.currentItem?.audioMix else {
            XCTFail("Expected non-nil audioMix after preparePlayback with mute action")
            return
        }

        let asset = AVURLAsset(url: audioURL)
        let duration = try await asset.load(.duration).seconds
        let onsets = AudioMixRampInspector.muteOnsetBoundaries(from: mix, duration: duration)
        let releases = AudioMixRampInspector.muteReleaseBoundaries(from: mix, duration: duration)

        XCTAssertEqual(onsets.count, golden.count, "onset ramp count")
        XCTAssertEqual(releases.count, golden.count, "release ramp count")

        for expected in golden {
            guard let onset = onsets.min(by: { abs($0 - expected.start) < abs($1 - expected.start) }) else {
                XCTFail("No onset boundary for start \(expected.start)")
                continue
            }
            assertBoundary(onset, near: expected.start, label: "onset at start \(expected.start)")

            guard let release = releases.min(by: { abs($0 - expected.end) < abs($1 - expected.end) }) else {
                XCTFail("No release boundary for end \(expected.end)")
                continue
            }
            assertBoundary(release, near: expected.end, label: "release at end \(expected.end)")
        }
    }

    // MARK: - AC2: offline render meets Slice 04 RMS thresholds

    func testOfflineRenderMeetsRMSThresholds() async throws {
        let (coordinator, _) = makeCoordinator(audioURL: sineFixtureURL())
        let transcript = try loadTranscript()

        try await coordinator.preparePlayback(
            episode: EpisodeIdentity(id: episodeID),
            audioURL: dummyAudioURL(),
            targetWords: fullTargetSet,
            action: .mute,
            injectedTranscript: transcript
        )

        let intervals = coordinator.cachedIntervals
        XCTAssertFalse(intervals.isEmpty, "precondition: pipeline produced intervals")

        let render = try await OfflineRenderRMS.render(
            fixtureNamed: sineFixtureName,
            fixtureExtension: sineFixtureExt,
            intervals: intervals,
            fadeDuration: IntervalScheduler.defaultFadeDuration,
            loadedBy: type(of: self)
        )

        for interval in intervals where interval.action == .mute {
            let interior = render.windowsFullyInside(interval)
            XCTAssertFalse(interior.isEmpty, "Expected interior windows for [\(interval.start), \(interval.end)]")
            for window in interior {
                XCTAssertLessThan(
                    window.rms, 0.01,
                    "Interior RMS \(window.rms) at [\(window.startTime), \(window.endTime)]"
                )
            }
        }

        let exterior = render.windowsOutside(by: OfflineRenderRMS.settleMargin)
        XCTAssertFalse(exterior.isEmpty, "Expected exterior windows")
        for window in exterior {
            XCTAssertGreaterThan(
                window.rms, 0.25,
                "Exterior RMS \(window.rms) at [\(window.startTime), \(window.endTime)]"
            )
        }
    }

    // MARK: - AC3: action toggle without reanalysis

    func testActionToggleNoReanalysis() async throws {
        let engine = PlaybackEngine(url: sineFixtureURL(), title: "Toggle", artist: "PodWash QA")
        let coordinator = PlaybackCoordinator(pipeline: pipelineSpy, engine: engine)
        let transcript = try loadTranscript()

        try await coordinator.preparePlayback(
            episode: EpisodeIdentity(id: episodeID),
            audioURL: dummyAudioURL(),
            targetWords: fullTargetSet,
            action: .mute,
            injectedTranscript: transcript
        )

        let analyzeAfterPrepare = pipelineSpy.analyzeCallCount
        let asrAfterPrepare = spy.transcribeCallCount
        XCTAssertEqual(analyzeAfterPrepare, 1, "First prepare should call analyze once")
        XCTAssertEqual(asrAfterPrepare, 0, "Injected transcript bypasses ASR")

        await coordinator.setAction(.skip)
        XCTAssertEqual(pipelineSpy.analyzeCallCount, analyzeAfterPrepare, "setAction(.skip) must not analyze")
        XCTAssertEqual(spy.transcribeCallCount, asrAfterPrepare, "setAction(.skip) must not transcribe")
        XCTAssertTrue(engine.activeSchedule?.intervals.allSatisfy { $0.action == .skip } ?? false)

        await coordinator.setAction(.mute)
        XCTAssertEqual(pipelineSpy.analyzeCallCount, analyzeAfterPrepare, "setAction(.mute) must not analyze")
        XCTAssertEqual(spy.transcribeCallCount, asrAfterPrepare, "setAction(.mute) must not transcribe")
        XCTAssertTrue(engine.activeSchedule?.intervals.allSatisfy { $0.action == .mute } ?? false)
    }

    // MARK: - AC4: no intervals — nil mix, no crash

    func testNoIntervalsPlaysNormally() async throws {
        let engine = PlaybackEngine(url: sineFixtureURL(), title: "Empty", artist: "PodWash QA")
        let coordinator = PlaybackCoordinator(pipeline: pipelineSpy, engine: engine)

        try await coordinator.preparePlayback(
            episode: EpisodeIdentity(id: "empty-intervals"),
            audioURL: dummyAudioURL(),
            targetWords: ["nonexistenttoken"],
            action: .mute,
            injectedTranscript: try loadTranscript()
        )

        XCTAssertTrue(coordinator.cachedIntervals.isEmpty)
        XCTAssertNil(engine.avPlayer.currentItem?.audioMix, "Empty intervals must leave audioMix nil")

        engine.play()
        engine.pause()
        XCTAssertFalse(engine.isPlaying)
    }
}
