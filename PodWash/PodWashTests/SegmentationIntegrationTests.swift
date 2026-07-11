//
//  SegmentationIntegrationTests.swift
//  PodWashTests
//
//  Slice 19 — Segmentation integration (ADR-013). AC1–AC3, AC5 unit.
//  Pipeline → cache → playback with independent profanity/segment actions.
//
//  Fixture provenance: Fixtures/segmentation/segmentation-provenance.md
//  (integration_transcript.json + integration_golden.json — hand-labeled, not
//  generated from implementation under test).
//
//  Until IntervalSource, UnrelatedContentOptions, pipeline merge, coordinator
//  by-source mapping, and skip-override APIs exist (Engineer, later effort),
//  this file fails to compile — intended TDD red state.
//

import AVFoundation
import XCTest
@testable import PodWash

/// Wraps AnalysisPipeline and counts analyze invocations (ADR-013 §3.3 / ADR-006 §5).
final class SegmentationPipelineAnalyzeSpy: EpisodeAnalyzing, @unchecked Sendable {
    private(set) var analyzeCallCount = 0
    private let inner: AnalysisPipeline

    init(inner: AnalysisPipeline) {
        self.inner = inner
    }

    func analyze(
        episode: EpisodeIdentity,
        audioURL: URL,
        targetWords: Set<String>,
        injectedTranscript: [TimedWord]?,
        profanityAction: CensorAction = .mute,
        unrelatedContent: UnrelatedContentOptions = .init(enabled: false, action: .skip)
    ) async throws -> [CensorInterval] {
        analyzeCallCount += 1
        return try await inner.analyze(
            episode: episode,
            audioURL: audioURL,
            targetWords: targetWords,
            injectedTranscript: injectedTranscript,
            profanityAction: profanityAction,
            unrelatedContent: unrelatedContent
        )
    }
}

@MainActor
final class SegmentationIntegrationTests: XCTestCase {

    private let episodeID = "fixture-segmentation-integration"
    private let targetWords: Set<String> = ["shit", "damn"]
    private let profanityTolerance = 0.0005
    private let segmentTolerance = 0.001
    private let sineFixtureName = "sine-300hz-5s"
    private let sineFixtureExt = "wav"

    private var cacheDir: URL!
    private var asrSpy: ASRSpyTranscriber!
    private var pipeline: AnalysisPipeline!
    private var pipelineSpy: SegmentationPipelineAnalyzeSpy!

    private var innerProjectDir: URL {
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
    }

    override func setUp() async throws {
        cacheDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("SegmentationIntegration-\(UUID().uuidString)", isDirectory: true)
        asrSpy = ASRSpyTranscriber()
        pipeline = AnalysisPipeline(
            transcriber: asrSpy,
            cache: IntervalCache(baseDirectory: cacheDir),
            segmenter: HeuristicContentSegmenter()
        )
        pipelineSpy = SegmentationPipelineAnalyzeSpy(inner: pipeline)
    }

    override func tearDown() async throws {
        try? IntervalCache(baseDirectory: cacheDir).clear()
    }

    // MARK: - Fixture loading

    private struct IntegrationGolden: Decodable {
        let profanity: [Bound]
        let segments: [Bound]

        struct Bound: Decodable {
            let start: Double
            let end: Double
        }
    }

    private func segmentationFixtureURL(
        _ name: String,
        file: StaticString = #filePath,
        line: UInt = #line
    ) throws -> URL {
        let bundle = Bundle(for: type(of: self))
        if let url = bundle.url(forResource: name, withExtension: "json", subdirectory: "Fixtures/segmentation")
            ?? bundle.url(forResource: name, withExtension: "json") {
            return url
        }
        let sourceURL = innerProjectDir
            .appendingPathComponent("PodWashTests/Fixtures/segmentation/\(name).json")
        if FileManager.default.fileExists(atPath: sourceURL.path) {
            return sourceURL
        }
        XCTFail("Missing segmentation fixture '\(name).json'", file: file, line: line)
        throw CocoaError(.fileNoSuchFile)
    }

    private func loadIntegrationTranscript() throws -> [TimedWord] {
        let url = try segmentationFixtureURL("integration_transcript")
        return try JSONDecoder().decode([TimedWord].self, from: Data(contentsOf: url))
    }

    private func loadIntegrationGolden() throws -> IntegrationGolden {
        let url = try segmentationFixtureURL("integration_golden")
        return try JSONDecoder().decode(IntegrationGolden.self, from: Data(contentsOf: url))
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
            .appendingPathComponent("podwash-seg-int-\(sineFixtureName).\(sineFixtureExt)")
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
        let engine = PlaybackEngine(url: audioURL, title: "Seg Integration", artist: "PodWash QA")
        let coordinator = PlaybackCoordinator(pipeline: pipelineSpy, engine: engine)
        return (coordinator, engine)
    }

    private func unrelatedIntervals(in schedule: IntervalSchedule?) -> [CensorInterval] {
        schedule?.intervals.filter { $0.source == .unrelatedContent } ?? []
    }

    // MARK: - AC1: dual actions, golden bounds, cache hit on second analyze

    func testSegmentsAndProfanityCachedWithIndependentActions() async throws {
        let transcript = try loadIntegrationTranscript()
        let golden = try loadIntegrationGolden()
        let episode = EpisodeIdentity(id: episodeID)
        let unrelatedEnabled = UnrelatedContentOptions(enabled: true, action: .skip)

        let first = try await pipeline.analyze(
            episode: episode,
            audioURL: dummyAudioURL(),
            targetWords: targetWords,
            injectedTranscript: transcript,
            profanityAction: .mute,
            unrelatedContent: unrelatedEnabled
        )

        XCTAssertGreaterThanOrEqual(first.count, 3, "Expected ≥ 3 intervals total")

        let segmentIntervals = first.filter { $0.source == .unrelatedContent }
        let profanityIntervals = first.filter { $0.source == .profanity }

        XCTAssertEqual(segmentIntervals.count, 2, "Exactly 2 unrelated-content intervals")
        XCTAssertGreaterThanOrEqual(profanityIntervals.count, 1, "≥ 1 profanity interval")

        for expected in golden.segments {
            let match = segmentIntervals.contains { interval in
                abs(interval.start - expected.start) <= segmentTolerance
                    && abs(interval.end - expected.end) <= segmentTolerance
            }
            XCTAssertTrue(
                match,
                "No segment interval matching [\(expected.start), \(expected.end)] within ±\(segmentTolerance)s"
            )
        }

        for expected in golden.profanity {
            let match = profanityIntervals.contains { interval in
                abs(interval.start - expected.start) <= profanityTolerance
                    && abs(interval.end - expected.end) <= profanityTolerance
            }
            XCTAssertTrue(
                match,
                "No profanity interval matching [\(expected.start), \(expected.end)] within ±\(profanityTolerance)s"
            )
        }

        XCTAssertTrue(profanityIntervals.allSatisfy { $0.action == .mute })
        XCTAssertTrue(segmentIntervals.allSatisfy { $0.action == .skip })

        let transcribeAfterFirst = asrSpy.transcribeCallCount
        XCTAssertEqual(transcribeAfterFirst, 0, "Injected transcript must bypass ASR on first analyze")

        let second = try await pipeline.analyze(
            episode: episode,
            audioURL: dummyAudioURL(),
            targetWords: targetWords,
            injectedTranscript: transcript,
            profanityAction: .mute,
            unrelatedContent: unrelatedEnabled
        )

        XCTAssertEqual(second, first)
        XCTAssertEqual(asrSpy.transcribeCallCount, transcribeAfterFirst, "Cache hit must not call ASR again")
        XCTAssertEqual(pipelineSpy.analyzeCallCount, 2, "Second analyze still invokes pipeline (cache load inside)")
    }

    // MARK: - AC2: off-by-default excludes segment intervals from scheduler

    func testOffByDefaultExcludesSegmentIntervals() async throws {
        let transcript = try loadIntegrationTranscript()
        let audioURL = sineFixtureURL()

        let (coordinatorOff, engineOff) = makeCoordinator(audioURL: audioURL)
        try await coordinatorOff.preparePlayback(
            episode: EpisodeIdentity(id: "\(episodeID)-off"),
            audioURL: dummyAudioURL(),
            targetWords: targetWords,
            action: .mute,
            unrelatedContent: UnrelatedContentOptions(enabled: false, action: .skip),
            injectedTranscript: transcript
        )

        XCTAssertEqual(
            unrelatedIntervals(in: engineOff.activeSchedule).count, 0,
            "Default-off settings must schedule 0 unrelated-content intervals"
        )

        let (coordinatorOn, engineOn) = makeCoordinator(audioURL: audioURL)
        try await coordinatorOn.preparePlayback(
            episode: EpisodeIdentity(id: "\(episodeID)-on"),
            audioURL: dummyAudioURL(),
            targetWords: targetWords,
            action: .mute,
            unrelatedContent: UnrelatedContentOptions(enabled: true, action: .skip),
            injectedTranscript: transcript
        )

        XCTAssertGreaterThanOrEqual(
            unrelatedIntervals(in: engineOn.activeSchedule).count, 2,
            "Enabled unrelated-content must schedule ≥ 2 segment intervals"
        )
    }

    // MARK: - AC3: skip landing + override replay

    func testSkipAndOverrideReplay() async throws {
        let engine = PlaybackEngine(
            url: sineFixtureURL(),
            title: "Skip Override",
            artist: "PodWash QA"
        )
        let skipInterval = CensorInterval(
            start: 2.0,
            end: 5.0,
            action: .skip,
            source: .unrelatedContent
        )
        await engine.applySchedule(IntervalSchedule(intervals: [skipInterval]))

        await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
            engine.seek(to: 1.9) { continuation.resume() }
        }

        let skipLanded = expectation(description: "skip lands near interval end")
        var skipObserver: Any?
        skipObserver = engine.avPlayer.addPeriodicTimeObserver(
            forInterval: CMTime(seconds: 0.02, preferredTimescale: 600),
            queue: .main
        ) { time in
            if time.seconds >= skipInterval.end - 0.1 {
                skipLanded.fulfill()
            }
        }
        addTeardownBlock { [engine] in
            if let skipObserver { engine.avPlayer.removeTimeObserver(skipObserver) }
        }

        engine.play()
        await fulfillment(of: [skipLanded], timeout: 10)

        XCTAssertGreaterThanOrEqual(
            engine.currentTime, skipInterval.end - 0.1,
            "Skip must land at ≥ end − 0.1 (\(skipInterval.end - 0.1)); got \(engine.currentTime)"
        )
        XCTAssertLessThanOrEqual(
            engine.currentTime, skipInterval.end,
            "Skip must not overshoot past end (\(skipInterval.end)); got \(engine.currentTime)"
        )
        XCTAssertEqual(engine.avPlayer.timeControlStatus, .playing)

        let overrideLanded = expectation(description: "override seeks to segment start")
        var overrideObserver: Any?
        overrideObserver = engine.avPlayer.addPeriodicTimeObserver(
            forInterval: CMTime(seconds: 0.02, preferredTimescale: 600),
            queue: .main
        ) { time in
            if time.seconds >= 1.95 && time.seconds <= 2.05 {
                overrideLanded.fulfill()
            }
        }
        addTeardownBlock { [engine] in
            if let overrideObserver { engine.avPlayer.removeTimeObserver(overrideObserver) }
            engine.pause()
        }

        engine.overrideUnrelatedContentSkip(skipInterval)
        await fulfillment(of: [overrideLanded], timeout: 2.0)

        XCTAssertGreaterThanOrEqual(engine.currentTime, 1.95)
        XCTAssertLessThanOrEqual(engine.currentTime, 2.05)
        XCTAssertEqual(engine.avPlayer.timeControlStatus, .playing)
    }

    // MARK: - AC5: fresh SettingsStore defaults

    func testUnrelatedContentDefaultsOff() {
        let suiteName = "podwash.seg-int.settings.\(UUID().uuidString)"
        guard let userDefaults = UserDefaults(suiteName: suiteName) else {
            XCTFail("Could not create isolated UserDefaults suite")
            return
        }
        defer { userDefaults.removePersistentDomain(forName: suiteName) }
        userDefaults.removePersistentDomain(forName: suiteName)

        let store = SettingsStore(userDefaults: userDefaults)
        XCTAssertFalse(store.unrelatedContentEnabled, "Fresh store: unrelatedContentEnabled must be false")
        XCTAssertEqual(store.unrelatedContentAction, .skip, "Fresh store: unrelatedContentAction must be .skip")
    }
}
