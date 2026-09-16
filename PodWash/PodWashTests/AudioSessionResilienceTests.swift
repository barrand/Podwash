//
//  AudioSessionResilienceTests.swift
//  PodWashTests
//
//  Audio interruption, route-loss, and session-manager contracts.
//

import AVFoundation
import XCTest
@testable import PodWash

@MainActor
private final class RecordingSystemAudioSession: SystemAudioSessionControlling {
    enum Failure: Error, Equatable { case configure, activate, deactivate }

    var failure: Failure?
    private(set) var calls: [String] = []

    func configurePlayback() throws {
        calls.append("configure")
        if failure == .configure { throw Failure.configure }
    }

    func activate() throws {
        calls.append("activate")
        if failure == .activate { throw Failure.activate }
    }

    func deactivateNotifyingOthers() throws {
        calls.append("deactivate")
        if failure == .deactivate { throw Failure.deactivate }
    }
}

@MainActor
private final class AudioSessionEventRecorder: AudioSessionEventHandling {
    private(set) var events: [AudioSessionEvent] = []
    var onEvent: (() -> Void)?

    func handleAudioSessionEvent(_ event: AudioSessionEvent) {
        events.append(event)
        onEvent?()
    }
}

@MainActor
private final class AudioSessionConfiguratorDouble: AudioSessionConfiguring {
    var activationSucceeds = true
    private(set) var activationCount = 0
    private(set) var deactivationCount = 0

    func activatePlaybackSession() -> Bool {
        activationCount += 1
        return activationSucceeds
    }

    func deactivatePlaybackSession() {
        deactivationCount += 1
    }
}

@MainActor
final class AudioSessionManagerTests: XCTestCase {
    func testActivationConfiguresBeforeActivatingAndDeactivationIsForwarded() {
        let system = RecordingSystemAudioSession()
        let manager = AudioSessionManager(system: system, notificationCenter: NotificationCenter())

        XCTAssertTrue(manager.activatePlaybackSession())
        manager.deactivatePlaybackSession()

        XCTAssertEqual(system.calls, ["configure", "activate", "deactivate"])
    }

    func testActivationFailureDoesNotClaimSuccess() {
        let system = RecordingSystemAudioSession()
        system.failure = .activate
        let manager = AudioSessionManager(system: system, notificationCenter: NotificationCenter())

        XCTAssertFalse(manager.activatePlaybackSession())
        XCTAssertEqual(system.calls, ["configure", "activate"])
    }

    func testNotificationsMapToTypedEvents() {
        let center = NotificationCenter()
        let manager = AudioSessionManager(system: RecordingSystemAudioSession(), notificationCenter: center)
        let recorder = AudioSessionEventRecorder()
        manager.bind(recorder)
        let expectation = expectation(description: "all events")
        expectation.expectedFulfillmentCount = 4
        recorder.onEvent = { expectation.fulfill() }

        center.post(
            name: AVAudioSession.interruptionNotification,
            object: nil,
            userInfo: [AVAudioSessionInterruptionTypeKey: AVAudioSession.InterruptionType.began.rawValue]
        )
        center.post(
            name: AVAudioSession.interruptionNotification,
            object: nil,
            userInfo: [
                AVAudioSessionInterruptionTypeKey: AVAudioSession.InterruptionType.ended.rawValue,
                AVAudioSessionInterruptionOptionKey: AVAudioSession.InterruptionOptions.shouldResume.rawValue,
            ]
        )
        center.post(
            name: AVAudioSession.routeChangeNotification,
            object: nil,
            userInfo: [AVAudioSessionRouteChangeReasonKey: AVAudioSession.RouteChangeReason.oldDeviceUnavailable.rawValue]
        )
        center.post(name: AVAudioSession.mediaServicesWereResetNotification, object: nil)

        wait(for: [expectation], timeout: 1)
        XCTAssertEqual(recorder.events, [
            .interruptionBegan,
            .interruptionEnded(shouldResume: true),
            .outputDisconnected,
            .mediaServicesReset,
        ])
    }

    func testUnbindOnlyClearsTheMatchingHandler() {
        let center = NotificationCenter()
        let manager = AudioSessionManager(system: RecordingSystemAudioSession(), notificationCenter: center)
        let first = AudioSessionEventRecorder()
        let second = AudioSessionEventRecorder()
        manager.bind(first)
        manager.bind(second)
        manager.unbind(first)
        let expectation = expectation(description: "current handler receives event")
        second.onEvent = { expectation.fulfill() }
        center.post(name: AVAudioSession.mediaServicesWereLostNotification, object: nil)
        wait(for: [expectation], timeout: 1)

        // `first` must not detach the current binding.
        XCTAssertEqual(second.events, [.mediaServicesLost])
        XCTAssertTrue(first.events.isEmpty)
    }
}

@MainActor
final class PlaybackInterruptionTests: XCTestCase {
    private func fixtureURL() -> URL {
        let bundle = Bundle(for: type(of: self))
        guard let bundled = bundle.url(forResource: "test-clip", withExtension: "m4a") else {
            XCTFail("Missing test-clip.m4a")
            return URL(fileURLWithPath: "/dev/null")
        }
        let destination = FileManager.default.temporaryDirectory
            .appendingPathComponent("podwash-interruption-\(UUID().uuidString).m4a")
        try? FileManager.default.copyItem(at: bundled, to: destination)
        return destination
    }

    private func makeEngine(
        session: AudioSessionConfiguratorDouble,
        recorder: NowPlayingInfoRecorder? = nil
    ) -> PlaybackEngine {
        PlaybackEngine(
            url: fixtureURL(),
            title: "Interruption QA",
            artist: "PodWash",
            nowPlayingUpdater: recorder ?? NowPlayingInfoRecorder(),
            audioSessionConfigurator: session
        )
    }

    func testResumableInterruptionPausesThenResumesPriorIntent() {
        let session = AudioSessionConfiguratorDouble()
        let engine = makeEngine(session: session)
        var systemPauseCount = 0
        engine.onSystemPause = { systemPauseCount += 1 }

        engine.play()
        XCTAssertTrue(engine.isPlaybackRequested)
        engine.handleAudioSessionEvent(.interruptionBegan)
        XCTAssertFalse(engine.isPlaybackRequested)
        XCTAssertEqual(systemPauseCount, 1)

        engine.handleAudioSessionEvent(.interruptionEnded(shouldResume: true))
        XCTAssertTrue(engine.isPlaybackRequested)
        XCTAssertEqual(session.activationCount, 2)
        engine.pause()
    }

    func testPauseDuringInterruptionCancelsAutomaticResume() {
        let session = AudioSessionConfiguratorDouble()
        let engine = makeEngine(session: session)
        engine.play()
        engine.handleAudioSessionEvent(.interruptionBegan)
        engine.pause()
        engine.handleAudioSessionEvent(.interruptionEnded(shouldResume: true))

        XCTAssertFalse(engine.isPlaybackRequested)
        XCTAssertEqual(session.activationCount, 1)
    }

    func testRouteDisconnectPermanentlyCancelsPendingResume() {
        let session = AudioSessionConfiguratorDouble()
        let engine = makeEngine(session: session)
        engine.play()
        engine.handleAudioSessionEvent(.interruptionBegan)
        engine.handleAudioSessionEvent(.outputDisconnected)
        engine.handleAudioSessionEvent(.interruptionEnded(shouldResume: true))

        XCTAssertFalse(engine.isPlaybackRequested)
        XCTAssertGreaterThanOrEqual(session.deactivationCount, 1)
    }

    func testMediaServicesLossBlocksPlaybackUntilReplacementEngineExists() {
        let session = AudioSessionConfiguratorDouble()
        let engine = makeEngine(session: session)
        var resetCount = 0
        engine.onMediaServicesReset = { resetCount += 1 }
        engine.play()
        engine.handleAudioSessionEvent(.mediaServicesLost)
        engine.play()
        engine.handleAudioSessionEvent(.mediaServicesReset)

        XCTAssertFalse(engine.isPlaybackRequested)
        XCTAssertEqual(session.activationCount, 1)
        XCTAssertEqual(resetCount, 1)
    }
}
