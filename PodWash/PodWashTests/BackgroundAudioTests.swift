//
//  BackgroundAudioTests.swift
//  PodWashTests
//
//  Slice 14 — Background audio session + UIBackgroundModes (ADR-011). AC2, AC4.
//
//  AC2: Injected AudioSessionConfiguring double records `.playback` category,
//  `.spokenAudio` mode, and setActive(true) ≥ 1 after coordinator bootstrap + first play().
//
//  AC4: Built test-host app Info.plist declares UIBackgroundModes `audio` exactly once.
//  Structural read via Bundle.main (test host = PodWash.app) — no device entitlement probe.
//
//  Until AudioSessionConfiguring, RemoteCommandCoordinator, and PlaybackEngine session
//  injection exist (Engineer), AC2 fails to compile — intended TDD state.
//  AC4 compiles but fails at runtime until Info.plist adds `audio`.
//

import AVFoundation
import XCTest
@testable import PodWash

/// Records AVAudioSession activation calls for AC2 (ADR-011 §5).
final class AudioSessionConfiguringSpy: AudioSessionConfiguring {
    private(set) var recordedCategory: AVAudioSession.Category?
    private(set) var recordedMode: AVAudioSession.Mode?
    private(set) var setActiveTrueCount = 0

    func activatePlaybackSession() {
        recordedCategory = .playback
        recordedMode = .spokenAudio
        setActiveTrueCount += 1
    }
}

@MainActor
final class BackgroundAudioTests: XCTestCase {

    private func testClipURL(file: StaticString = #filePath, line: UInt = #line) -> URL {
        let bundle = Bundle(for: type(of: self))
        guard let bundledURL = bundle.url(forResource: "test-clip", withExtension: "m4a") else {
            XCTFail("Missing test-clip.m4a in \(bundle.bundlePath)", file: file, line: line)
            return URL(fileURLWithPath: "/dev/null")
        }

        let tempURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("podwash-background-test-clip.m4a")
        try? FileManager.default.removeItem(at: tempURL)
        do {
            try FileManager.default.copyItem(at: bundledURL, to: tempURL)
        } catch {
            XCTFail("Could not copy test-clip fixture: \(error)", file: file, line: line)
            return bundledURL
        }
        return tempURL
    }

    // MARK: - AC2

    func testSessionCategoryPlaybackSpokenAudio() {
        let sessionSpy = AudioSessionConfiguringSpy()
        let url = testClipURL()
        let engine = PlaybackEngine(
            url: url,
            title: "Background Session",
            artist: "PodWash QA",
            nowPlayingUpdater: NowPlayingInfoRecorder(),
            audioSessionConfigurator: sessionSpy
        )

        let commands = RemoteCommandCenterDouble()
        let coordinator = RemoteCommandCoordinator(commands: commands)
        coordinator.activate()
        coordinator.bind(engine)

        addTeardownBlock { [engine] in
            engine.pause()
        }

        engine.play()

        XCTAssertEqual(sessionSpy.recordedCategory, .playback, "Session category must be .playback")
        XCTAssertEqual(sessionSpy.recordedMode, .spokenAudio, "Session mode must be .spokenAudio")
        XCTAssertGreaterThanOrEqual(sessionSpy.setActiveTrueCount, 1, "setActive(true) must run at least once on first play()")
    }

    // MARK: - AC4

    func testBackgroundModeDeclared() {
        guard let backgroundModes = Bundle.main.object(forInfoDictionaryKey: "UIBackgroundModes") as? [String] else {
            XCTFail("UIBackgroundModes missing from test-host app Info.plist")
            return
        }

        let audioOccurrences = backgroundModes.filter { $0 == "audio" }.count
        XCTAssertEqual(
            audioOccurrences,
            1,
            "UIBackgroundModes must contain the string 'audio' exactly once (found \(audioOccurrences) in \(backgroundModes))"
        )
    }
}
