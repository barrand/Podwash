//
//  PlaybackRateTests.swift
//  PodWashTests
//
//  Slice 12 — Variable speed (ADR-001 extension). AC1–AC2.
//
//  AC1: discrete supported rates map to AVPlayer.rate while playing (±0.001).
//  AC2: changing playback rate must not shift mute ramp boundaries on the media
//  timeline; offline render at mix rate 1.0 still meets Slice 04 RMS thresholds.
//
//  Fixture provenance: sine-300hz-5s.wav per Fixtures/audio/sine-300hz-5s.provenance.md
//  (hand-generated 300 Hz tone; interval windows derived from ADR-002 §4 — not from
//  scheduler output). test-clip.m4a per Fixtures/audio/test-clip.provenance.md.
//
//  Until PlaybackEngine.setRate(_:) exists (Engineer, later effort), this file
//  fails to compile — intended TDD red state.
//

import AVFoundation
import XCTest
@testable import PodWash

@MainActor
final class PlaybackRateTests: XCTestCase {

    private let supportedRates: [Float] = [0.75, 1.0, 1.25, 1.5, 2.0, 3.0]
    private let rateTolerance: Float = 0.001
    private let boundaryTolerance = 0.001

    private let sineFixtureName = "sine-300hz-5s"
    private let sineFixtureExt = "wav"

    // MARK: - Fixture helpers

    private func testClipURL(file: StaticString = #filePath, line: UInt = #line) -> URL {
        let bundle = Bundle(for: type(of: self))
        guard let bundledURL = bundle.url(forResource: "test-clip", withExtension: "m4a") else {
            XCTFail("Missing test-clip.m4a in \(bundle.bundlePath)", file: file, line: line)
            return URL(fileURLWithPath: "/dev/null")
        }

        let tempURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("podwash-rate-test-clip.m4a")
        try? FileManager.default.removeItem(at: tempURL)
        do {
            try FileManager.default.copyItem(at: bundledURL, to: tempURL)
        } catch {
            XCTFail("Could not copy test-clip fixture: \(error)", file: file, line: line)
            return bundledURL
        }
        return tempURL
    }

    private func sineFixtureURL(file: StaticString = #filePath, line: UInt = #line) -> URL {
        let bundle = Bundle(for: type(of: self))
        guard let bundledURL = bundle.url(
            forResource: sineFixtureName,
            withExtension: sineFixtureExt,
            subdirectory: "Fixtures/audio"
        ) ?? bundle.url(forResource: sineFixtureName, withExtension: sineFixtureExt) else {
            XCTFail("Missing \(sineFixtureName).\(sineFixtureExt)", file: file, line: line)
            return URL(fileURLWithPath: "/dev/null")
        }

        let tempURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("podwash-rate-\(sineFixtureName).\(sineFixtureExt)")
        try? FileManager.default.removeItem(at: tempURL)
        do {
            try FileManager.default.copyItem(at: bundledURL, to: tempURL)
        } catch {
            XCTFail("Could not copy sine fixture: \(error)", file: file, line: line)
            return bundledURL
        }
        return tempURL
    }

    private func waitForPlaying(_ engine: PlaybackEngine, timeout: TimeInterval = 5) {
        let expectation = expectation(description: "timeControlStatus reaches playing")
        let observation = engine.avPlayer.observe(\.timeControlStatus, options: [.new]) { player, _ in
            if player.timeControlStatus == .playing {
                expectation.fulfill()
            }
        }
        addTeardownBlock { [engine] in
            engine.pause()
            observation.invalidate()
        }
        wait(for: [expectation], timeout: timeout)
    }

    // MARK: - AC1: supported rates match AVPlayer.rate while playing

    func testSupportedRatesMatchAVPlayer() throws {
        let engine = PlaybackEngine(
            url: testClipURL(),
            title: "Rate AC1",
            artist: "PodWash QA",
            nowPlayingUpdater: NowPlayingInfoRecorder()
        )

        for rate in supportedRates {
            engine.play()
            waitForPlaying(engine)

            engine.setRate(rate)

            XCTAssertEqual(
                engine.avPlayer.timeControlStatus,
                .playing,
                "Expected .playing after setRate(\(rate))"
            )
            XCTAssertEqual(
                engine.avPlayer.rate,
                rate,
                accuracy: rateTolerance,
                "AVPlayer.rate must match setRate(\(rate))"
            )

            engine.pause()
        }
    }

    // MARK: - AC2: rate change does not shift mute interval boundaries

    func testRateDoesNotShiftMuteIntervals() async throws {
        let audioURL = sineFixtureURL()
        let muteInterval = CensorInterval(start: 1.0, end: 1.5, action: .mute)
        let engine = PlaybackEngine(url: audioURL, title: "Rate AC2", artist: "PodWash QA")

        await engine.applySchedule(IntervalSchedule(intervals: [muteInterval]))

        engine.setRate(2.0)
        engine.play()

        guard let mix = engine.avPlayer.currentItem?.audioMix else {
            XCTFail("Expected non-nil audioMix after applySchedule with mute interval")
            return
        }

        let asset = AVURLAsset(url: audioURL)
        let duration = try await asset.load(.duration).seconds
        let onsets = AudioMixRampInspector.muteOnsetBoundaries(from: mix, duration: duration)
        let releases = AudioMixRampInspector.muteReleaseBoundaries(from: mix, duration: duration)

        XCTAssertEqual(onsets.count, 1, "Expected one mute onset boundary")
        XCTAssertEqual(releases.count, 1, "Expected one mute release boundary")
        XCTAssertEqual(onsets[0], 1.0, accuracy: boundaryTolerance, "Mute onset must stay at 1.0 s")
        XCTAssertEqual(releases[0], 1.5, accuracy: boundaryTolerance, "Mute release must stay at 1.5 s")

        // Offline render uses the mix at asset rate 1.0 (unchanged by playback rate).
        let render = try await OfflineRenderRMS.render(
            fixtureNamed: sineFixtureName,
            fixtureExtension: sineFixtureExt,
            intervals: [muteInterval],
            fadeDuration: IntervalScheduler.defaultFadeDuration,
            loadedBy: type(of: self)
        )

        let interior = render.windowsFullyInside(muteInterval)
        XCTAssertFalse(interior.isEmpty, "Expected interior windows for [1.0, 1.5]")
        for window in interior {
            XCTAssertLessThan(
                window.rms, 0.01,
                "Interior RMS \(window.rms) at [\(window.startTime), \(window.endTime)] must be < 0.01"
            )
        }

        let exterior = render.windowsOutside(by: OfflineRenderRMS.settleMargin)
        XCTAssertFalse(exterior.isEmpty, "Expected exterior windows")
        for window in exterior {
            XCTAssertGreaterThan(
                window.rms, 0.25,
                "Exterior RMS \(window.rms) at [\(window.startTime), \(window.endTime)] must be > 0.25"
            )
        }
    }
}
