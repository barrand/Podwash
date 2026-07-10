//
//  RemoteCommandTests.swift
//  PodWashTests
//
//  Slice 14 — Lock screen / Control Center remote commands (ADR-011). AC1, AC3.
//
//  AC1: RemoteCommandCoordinator forwards play/pause/±15 s skip / change-position
//  to PlaybackTransporting via injectable RemoteCommandHandling double — no live
//  MPRemoteCommandCenter (ADR-000 / ADR-011 §8).
//
//  AC3: PlaybackEngine pushes Now Playing elapsed/duration on play, pause, and
//  finished seek; NowPlayingInfoRecorder captures ≥ 3 updates within ±0.25 s of
//  engine state. Fixture: test-clip.m4a (30.0 s) per Fixtures/audio/test-clip.provenance.md.
//
//  Pinned AC1 timeline: start currentTime 20.0 s, duration 30.0 s; skip forward
//  effective target 30.0 s; skip backward effective target 5.0 s; seek-to 10.0 s.
//  Provenance: hand-derived from slice AC1 arithmetic — independent of transport impl.
//
//  Until RemoteCommandCoordinator, RemoteCommandHandling, PlaybackTransporting, and
//  PlaybackEngine Now Playing on pause/seek exist (Engineer), this file fails to
//  compile or run red — intended TDD state.
//

import AVFoundation
import MediaPlayer
import XCTest
@testable import PodWash

// MARK: - Test doubles (ADR-011 §3–§4)

/// Programmatic remote-command seam; fires installed handlers without MediaPlayer UI.
@MainActor
final class RemoteCommandCenterDouble: RemoteCommandHandling {
    private var playHandler: (() -> MPRemoteCommandHandlerStatus)?
    private var pauseHandler: (() -> MPRemoteCommandHandlerStatus)?
    private var skipForwardHandler: (() -> MPRemoteCommandHandlerStatus)?
    private var skipBackwardHandler: (() -> MPRemoteCommandHandlerStatus)?
    private var changePositionHandler: ((TimeInterval) -> MPRemoteCommandHandlerStatus)?

    func installPlayHandler(_ handler: @escaping () -> MPRemoteCommandHandlerStatus) {
        playHandler = handler
    }

    func installPauseHandler(_ handler: @escaping () -> MPRemoteCommandHandlerStatus) {
        pauseHandler = handler
    }

    func installSkipForwardHandler(
        interval: TimeInterval,
        _ handler: @escaping () -> MPRemoteCommandHandlerStatus
    ) {
        XCTAssertEqual(interval, 15.0, accuracy: 0.001, "Skip forward interval must match in-app ±15 s")
        skipForwardHandler = handler
    }

    func installSkipBackwardHandler(
        interval: TimeInterval,
        _ handler: @escaping () -> MPRemoteCommandHandlerStatus
    ) {
        XCTAssertEqual(interval, 15.0, accuracy: 0.001, "Skip backward interval must match in-app ±15 s")
        skipBackwardHandler = handler
    }

    func installChangePlaybackPositionHandler(
        _ handler: @escaping (TimeInterval) -> MPRemoteCommandHandlerStatus
    ) {
        changePositionHandler = handler
    }

    @discardableResult
    func firePlay() -> MPRemoteCommandHandlerStatus {
        guard let playHandler else {
            XCTFail("play handler not installed")
            return .commandFailed
        }
        return playHandler()
    }

    @discardableResult
    func firePause() -> MPRemoteCommandHandlerStatus {
        guard let pauseHandler else {
            XCTFail("pause handler not installed")
            return .commandFailed
        }
        return pauseHandler()
    }

    @discardableResult
    func fireSkipForward() -> MPRemoteCommandHandlerStatus {
        guard let skipForwardHandler else {
            XCTFail("skipForward handler not installed")
            return .commandFailed
        }
        return skipForwardHandler()
    }

    @discardableResult
    func fireSkipBackward() -> MPRemoteCommandHandlerStatus {
        guard let skipBackwardHandler else {
            XCTFail("skipBackward handler not installed")
            return .commandFailed
        }
        return skipBackwardHandler()
    }

    @discardableResult
    func fireChangePlaybackPosition(to position: TimeInterval) -> MPRemoteCommandHandlerStatus {
        guard let changePositionHandler else {
            XCTFail("changePlaybackPosition handler not installed")
            return .commandFailed
        }
        return changePositionHandler(position)
    }
}

/// Records transport invocations for AC1 handler → engine forwarding asserts.
@MainActor
final class PlaybackTransportSpy: PlaybackTransporting {
    private(set) var playCallCount = 0
    private(set) var pauseCallCount = 0
    private(set) var seekToCallCount = 0
    private(set) var seekByCallCount = 0
    private(set) var lastSeekToTarget: TimeInterval?
    private(set) var lastSeekByDelta: TimeInterval?

    private(set) var currentTime: TimeInterval
    let duration: TimeInterval

    init(currentTime: TimeInterval, duration: TimeInterval) {
        self.currentTime = currentTime
        self.duration = duration
    }

    func play() {
        playCallCount += 1
    }

    func pause() {
        pauseCallCount += 1
    }

    func seek(to seconds: TimeInterval, completion: (() -> Void)?) {
        seekToCallCount += 1
        lastSeekToTarget = seconds
        currentTime = clamp(seconds)
        completion?()
    }

    func seek(by delta: TimeInterval) {
        seekByCallCount += 1
        lastSeekByDelta = delta
        currentTime = clamp(currentTime + delta)
    }

    private func clamp(_ value: TimeInterval) -> TimeInterval {
        let upper = duration > 0 ? duration : value
        return min(max(0, value), upper)
    }

    func effectiveTarget(startTime: TimeInterval, delta: TimeInterval) -> TimeInterval {
        min(max(0, startTime + delta), duration > 0 ? duration : startTime + delta)
    }
}

@MainActor
final class RemoteCommandTests: XCTestCase {

    private let fixtureDuration: TimeInterval = 30.0
    private let ac1StartTime: TimeInterval = 20.0
    private let syncTolerance: TimeInterval = 0.25

    // MARK: - Fixture helpers

    private func testClipURL(file: StaticString = #filePath, line: UInt = #line) -> URL {
        let bundle = Bundle(for: type(of: self))
        guard let bundledURL = bundle.url(forResource: "test-clip", withExtension: "m4a") else {
            XCTFail("Missing test-clip.m4a in \(bundle.bundlePath)", file: file, line: line)
            return URL(fileURLWithPath: "/dev/null")
        }

        let tempURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("podwash-remote-test-clip.m4a")
        try? FileManager.default.removeItem(at: tempURL)
        do {
            try FileManager.default.copyItem(at: bundledURL, to: tempURL)
        } catch {
            XCTFail("Could not copy test-clip fixture: \(error)", file: file, line: line)
            return bundledURL
        }
        return tempURL
    }

    private func waitForDuration(_ engine: PlaybackEngine, expected: TimeInterval, timeout: TimeInterval = 5) {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if engine.duration > 0, abs(engine.duration - expected) <= syncTolerance {
                return
            }
            RunLoop.main.run(until: Date().addingTimeInterval(0.05))
        }
        XCTFail("Timed out waiting for duration ≈ \(expected) s (got \(engine.duration))")
    }

    // MARK: - AC1

    func testRemoteHandlersInvokeTransportSpy() {
        let commands = RemoteCommandCenterDouble()
        let coordinator = RemoteCommandCoordinator(commands: commands)
        coordinator.activate()

        func bindFreshSpy() -> PlaybackTransportSpy {
            let spy = PlaybackTransportSpy(currentTime: ac1StartTime, duration: fixtureDuration)
            coordinator.bind(spy)
            return spy
        }

        var spy = bindFreshSpy()
        _ = commands.firePlay()
        XCTAssertEqual(spy.playCallCount, 1, "play handler must invoke transport.play() once")

        spy = bindFreshSpy()
        _ = commands.firePause()
        XCTAssertEqual(spy.pauseCallCount, 1, "pause handler must invoke transport.pause() once")

        spy = bindFreshSpy()
        _ = commands.fireSkipForward()
        XCTAssertEqual(spy.seekByCallCount, 1, "skipForward must invoke seek(by:) once")
        XCTAssertEqual(spy.lastSeekByDelta ?? 0, 15.0, accuracy: syncTolerance)
        let forwardTarget = spy.effectiveTarget(startTime: ac1StartTime, delta: 15.0)
        XCTAssertEqual(forwardTarget, 30.0, accuracy: syncTolerance)
        XCTAssertEqual(spy.currentTime, forwardTarget, accuracy: syncTolerance)

        spy = bindFreshSpy()
        _ = commands.fireSkipBackward()
        XCTAssertEqual(spy.seekByCallCount, 1, "skipBackward must invoke seek(by:) once")
        XCTAssertEqual(spy.lastSeekByDelta ?? 0, -15.0, accuracy: syncTolerance)
        let backwardTarget = spy.effectiveTarget(startTime: ac1StartTime, delta: -15.0)
        XCTAssertEqual(backwardTarget, 5.0, accuracy: syncTolerance)
        XCTAssertEqual(spy.currentTime, backwardTarget, accuracy: syncTolerance)

        spy = bindFreshSpy()
        _ = commands.fireChangePlaybackPosition(to: 10.0)
        XCTAssertEqual(spy.seekToCallCount, 1, "changePlaybackPosition must invoke seek(to:) once")
        XCTAssertEqual(spy.lastSeekToTarget ?? 0, 10.0, accuracy: syncTolerance)
    }

    // MARK: - AC3

    func testNowPlayingElapsedTracksTransport() {
        let url = testClipURL()
        let recorder = NowPlayingInfoRecorder()
        let engine = PlaybackEngine(
            url: url,
            title: "Remote Metadata",
            artist: "PodWash QA",
            nowPlayingUpdater: recorder
        )

        waitForDuration(engine, expected: fixtureDuration)

        var playingObservation: NSKeyValueObservation?
        let playingExpectation = expectation(description: "playback starts")
        playingObservation = engine.avPlayer.observe(\.timeControlStatus, options: [.new]) { player, _ in
            guard player.timeControlStatus == .playing else { return }
            playingObservation?.invalidate()
            playingObservation = nil
            playingExpectation.fulfill()
        }
        addTeardownBlock { [engine] in
            engine.pause()
            playingObservation?.invalidate()
        }

        engine.play()
        wait(for: [playingExpectation], timeout: 5)
        engine.refreshCurrentTime()
        recorder.assertSynced(with: engine, expectedDuration: fixtureDuration)

        engine.pause()
        engine.refreshCurrentTime()
        recorder.assertSynced(with: engine, expectedDuration: fixtureDuration)

        let seekExpectation = expectation(description: "seek completes")
        engine.seek(to: 10.0) {
            seekExpectation.fulfill()
        }
        wait(for: [seekExpectation], timeout: 5)
        engine.refreshCurrentTime()
        recorder.assertSynced(with: engine, expectedDuration: fixtureDuration)

        XCTAssertGreaterThanOrEqual(
            recorder.updateCount,
            3,
            "Now Playing must update on play, pause, and finished seek (≥ 3 pushes)"
        )
    }
}
