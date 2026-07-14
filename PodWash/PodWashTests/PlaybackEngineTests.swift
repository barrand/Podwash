//
//  PlaybackEngineTests.swift
//  PodWashTests
//
//  Slice 03 — Player shell unit tests (ADR-001).
//

import AVFoundation
import XCTest
@testable import PodWash

@MainActor
final class NowPlayingInfoRecorder: NowPlayingInfoUpdating {
    private(set) var lastTitle: String?
    private(set) var lastArtist: String?
    private(set) var lastElapsed: TimeInterval = 0
    private(set) var lastDuration: TimeInterval = 0
    private(set) var updateCount = 0

    // Avoid MainActor/TaskLocal deinit crash under SWIFT_DEFAULT_ACTOR_ISOLATION.
    nonisolated deinit {}

    func updateNowPlayingInfo(
        title: String,
        artist: String,
        duration: TimeInterval,
        elapsed: TimeInterval
    ) {
        lastTitle = title
        lastArtist = artist
        lastElapsed = elapsed
        lastDuration = duration
        updateCount += 1
    }

    /// Slice 14 AC3 — elapsed/duration must track engine within ±0.25 s after each transport step.
    func assertSynced(with engine: PlaybackEngine, expectedDuration: TimeInterval, file: StaticString = #filePath, line: UInt = #line) {
        XCTAssertLessThanOrEqual(
            abs(lastElapsed - engine.currentTime),
            0.25,
            "Now Playing elapsed must track engine.currentTime",
            file: file,
            line: line
        )
        XCTAssertLessThanOrEqual(
            abs(lastDuration - expectedDuration),
            0.25,
            "Now Playing duration must track fixture duration",
            file: file,
            line: line
        )
    }
}

@MainActor
final class PlaybackEngineTests: XCTestCase {

    private func fixtureURL() -> URL {
        let bundle = Bundle(for: PlaybackEngineTests.self)
        guard let bundledURL = bundle.url(forResource: "test-clip", withExtension: "m4a") else {
            XCTFail("Missing test-clip.m4a in \(bundle.bundlePath)")
            return URL(fileURLWithPath: "/dev/null")
        }

        let tempURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("podwash-test-clip.m4a")
        try? FileManager.default.removeItem(at: tempURL)
        do {
            try FileManager.default.copyItem(at: bundledURL, to: tempURL)
        } catch {
            XCTFail("Could not copy fixture to temp: \(error)")
            return bundledURL
        }
        return tempURL
    }

    func testPlayReachesPlayingViaKVOExpectation() throws {
        let url = fixtureURL()
        let engine = PlaybackEngine(
            url: url,
            title: "Test Title",
            artist: "Test Artist",
            nowPlayingUpdater: NowPlayingInfoRecorder()
        )

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

        engine.play()
        wait(for: [expectation], timeout: 5)
        XCTAssertEqual(engine.avPlayer.timeControlStatus, .playing)
    }

    func testSeekUpdatesCurrentTime() throws {
        let url = fixtureURL()
        let engine = PlaybackEngine(
            url: url,
            title: "Test Title",
            artist: "Test Artist",
            nowPlayingUpdater: NowPlayingInfoRecorder()
        )

        let target: TimeInterval = 10
        let seekExpectation = expectation(description: "seek completes")
        engine.seek(to: target) {
            seekExpectation.fulfill()
        }
        wait(for: [seekExpectation], timeout: 5)

        XCTAssertEqual(engine.currentTime, target, accuracy: 0.25)
        XCTAssertEqual(engine.avPlayer.currentTime().seconds, target, accuracy: 0.25)
    }

    func testNowPlayingDoubleReceivesMetadata() throws {
        let url = fixtureURL()
        let recorder = NowPlayingInfoRecorder()
        let engine = PlaybackEngine(
            url: url,
            title: "Episode Alpha",
            artist: "PodWash QA",
            nowPlayingUpdater: recorder
        )

        let playingExpectation = expectation(description: "playback starts")
        let observation = engine.avPlayer.observe(\.timeControlStatus, options: [.new]) { player, _ in
            if player.timeControlStatus == .playing {
                playingExpectation.fulfill()
            }
        }
        addTeardownBlock { [engine] in
            engine.pause()
            observation.invalidate()
        }

        engine.play()
        wait(for: [playingExpectation], timeout: 5)

        XCTAssertEqual(recorder.lastTitle, "Episode Alpha")
        XCTAssertEqual(recorder.lastArtist, "PodWash QA")
    }

    func testPlayableURLRemapsID3PayloadStoredAsM4A() throws {
        let source = FileManager.default.temporaryDirectory
            .appendingPathComponent("podwash-mp3-in-m4a-\(UUID().uuidString).m4a")
        var data = Data([0x49, 0x44, 0x33])
        data.append(Data(repeating: 0, count: 128))
        try data.write(to: source)
        defer { try? FileManager.default.removeItem(at: source) }

        let engine = PlaybackEngine(url: source, title: "MP3 remap", artist: "PodWash QA")
        let assetURL = (engine.avPlayer.currentItem?.asset as? AVURLAsset)?.url
        XCTAssertEqual(assetURL?.pathExtension.lowercased(), "mp3")
    }

    func testUITestTargetParallelizationDisabledInScheme() throws {
        let repoRoot = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        let schemeURL = repoRoot.appendingPathComponent(
            "PodWash/PodWash.xcodeproj/xcshareddata/xcschemes/PodWash.xcscheme"
        )
        let schemeXML = try String(contentsOf: schemeURL, encoding: .utf8)

        let pattern = #"<TestableReference[^>]*>[\s\S]*?PodWashUITests[\s\S]*?</TestableReference>"#
        let range = NSRange(schemeXML.startIndex..., in: schemeXML)
        guard let match = try NSRegularExpression(pattern: pattern).firstMatch(in: schemeXML, range: range),
              let swiftRange = Range(match.range, in: schemeXML) else {
            XCTFail("PodWashUITests TestableReference not found in \(schemeURL.path)")
            return
        }

        let uiTestsReference = String(schemeXML[swiftRange])
        XCTAssertTrue(
            uiTestsReference.contains("parallelizable = \"NO\""),
            "PodWashUITests must have parallelizable = \"NO\" in \(schemeURL.path)"
        )
    }
}
