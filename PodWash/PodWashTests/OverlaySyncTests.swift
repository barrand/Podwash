//
//  OverlaySyncTests.swift
//  PodWashTests
//
//  Slice 16 — Beep/quack overlay sync + offline energy (ADR-017). AC1–AC5.
//  Task-004 — overlay AVAudioPlayer silent under XCTest (volume 0).
//
//  Fixture provenance:
//  - Episode: `sine-300hz-5s.wav` (Slice 04; see Fixtures/audio/sine-300hz-5s.provenance.md).
//  - Mute intervals: pinned `[(1.0, 1.5), (3.0, 3.4)]` (slice AC; hand-specified).
//  - Beep/quack assets: ffmpeg-generated (beep-1khz.provenance.md, quack.provenance.md).
//  - Sync tolerance ±0.050 s and interior RMS thresholds from slice AC / ADR-017 §5.
//
//  Until MuteOverlayMode, OverlayEventRecording, OverlayEngine, SettingsStore.muteOverlayMode,
//  and PlaybackCoordinator overlay wiring exist (Engineer), this file fails to compile —
//  intended TDD red state.
//

import AVFoundation
import XCTest
@testable import PodWash

@MainActor
final class OverlaySyncTests: XCTestCase {

    // MARK: - Pinned fixture constants (slice / ADR-017 §6)

    private let fixtureName = "sine-300hz-5s"
    private let fixtureExt = "wav"
    private let syncTolerance: TimeInterval = 0.050
    private let seekResyncDeadline: TimeInterval = 0.200

    private let pinnedMuteIntervals: [(start: TimeInterval, end: TimeInterval)] = [
        (1.0, 1.5),
        (3.0, 3.4),
    ]

    private var pinnedCensorIntervals: [CensorInterval] {
        pinnedMuteIntervals.map {
            CensorInterval(start: $0.start, end: $0.end, action: .mute)
        }
    }

    // MARK: - Helpers

    private func fixtureURL(file: StaticString = #filePath, line: UInt = #line) -> URL {
        let bundle = Bundle(for: type(of: self))
        guard let bundledURL = bundle.url(
            forResource: fixtureName,
            withExtension: fixtureExt,
            subdirectory: "Fixtures/audio"
        ) ?? bundle.url(forResource: fixtureName, withExtension: fixtureExt) else {
            XCTFail("Missing \(fixtureName).\(fixtureExt)", file: file, line: line)
            return URL(fileURLWithPath: "/dev/null")
        }
        let tempURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("podwash-overlay-\(UUID().uuidString)-\(fixtureName).\(fixtureExt)")
        do {
            try FileManager.default.copyItem(at: bundledURL, to: tempURL)
        } catch {
            XCTFail("Could not copy fixture: \(error)", file: file, line: line)
            return bundledURL
        }
        addTeardownBlock {
            try? FileManager.default.removeItem(at: tempURL)
        }
        return tempURL
    }

    private func testAssetBundle() -> Bundle {
        Bundle(for: type(of: self))
    }

    private func waitForEngineReady(_ engine: PlaybackEngine, timeout: TimeInterval = 10) async {
        let ready = expectation(description: "engine duration loaded")
        let deadline = Date().addingTimeInterval(timeout)
        func poll() {
            engine.refreshCurrentTime()
            if engine.duration > 0 {
                ready.fulfill()
            } else if Date() < deadline {
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.05, execute: poll)
            }
        }
        poll()
        await fulfillment(of: [ready], timeout: timeout)
    }

    private func waitUntilPlayhead(
        _ target: TimeInterval,
        engine: PlaybackEngine,
        timeout: TimeInterval = 12
    ) async {
        let reached = expectation(description: "playhead >= \(target)")
        // Guard once on the main queue — do NOT removeTimeObserver inside the
        // callback (that retained [engine] and triggered PlaybackEngine /
        // MPNowPlayingInfoCenterUpdater deinit SIGABRT mid-wait). Match
        // IntervalMuteSkipTests: fulfill once, remove after await / teardown.
        var didFulfill = false
        var token: Any?
        token = engine.avPlayer.addPeriodicTimeObserver(
            forInterval: CMTime(seconds: 0.02, preferredTimescale: 600),
            queue: .main
        ) { time in
            guard time.seconds >= target, !didFulfill else { return }
            didFulfill = true
            reached.fulfill()
        }
        addTeardownBlock { [engine] in
            if let observer = token {
                token = nil
                engine.avPlayer.removeTimeObserver(observer)
            }
        }
        await fulfillment(of: [reached], timeout: timeout)
        if let observer = token {
            token = nil
            engine.avPlayer.removeTimeObserver(observer)
        }
    }

    private func waitUntilPastLastBoundary(
        engine: PlaybackEngine,
        lastEnd: TimeInterval,
        timeout: TimeInterval = 12
    ) async {
        await waitUntilPlayhead(lastEnd + 0.3, engine: engine, timeout: timeout)
    }

    private func makeOverlayEngine(
        on engine: PlaybackEngine,
        recorder: OverlayEventRecorder
    ) -> OverlayEngine {
        OverlayEngine(
            player: engine.avPlayer,
            eventRecorder: recorder,
            assetBundle: testAssetBundle()
        )
    }

    private func makeTestEngine(title: String) -> PlaybackEngine {
        // Inject recorder so teardown never hits MPNowPlayingInfoCenterUpdater
        // MainActor deinit (crash class seen mid OverlaySync wait).
        PlaybackEngine(
            url: fixtureURL(),
            title: title,
            artist: "PodWash QA",
            nowPlayingUpdater: NowPlayingInfoRecorder()
        )
    }

    private func runOverlayPlayback(
        muteIntervals: [(start: TimeInterval, end: TimeInterval)],
        mode: MuteOverlayMode,
        recorder: OverlayEventRecorder
    ) async throws -> PlaybackEngine {
        let engine = makeTestEngine(title: "Overlay")
        await waitForEngineReady(engine)

        let censor = muteIntervals.map {
            CensorInterval(start: $0.start, end: $0.end, action: .mute)
        }
        await engine.applySchedule(IntervalSchedule(intervals: censor))

        let overlay = makeOverlayEngine(on: engine, recorder: recorder)
        overlay.apply(muteIntervals: muteIntervals, mode: mode)

        addTeardownBlock {
            overlay.reset()
            engine.pause()
        }

        engine.play()
        let lastEnd = muteIntervals.map(\.end).max() ?? 0
        await waitUntilPastLastBoundary(engine: engine, lastEnd: lastEnd)
        engine.pause()
        return engine
    }

    private func isolatedUserDefaults() -> UserDefaults {
        let suiteName = "podwash.overlay.tests.\(UUID().uuidString)"
        guard let defaults = UserDefaults(suiteName: suiteName) else {
            XCTFail("Could not create isolated UserDefaults suite")
            return .standard
        }
        defaults.removePersistentDomain(forName: suiteName)
        addTeardownBlock {
            defaults.removePersistentDomain(forName: suiteName)
        }
        return defaults
    }

    /// Drives overlay from `store.muteOverlayMode` (ADR-017 §3 SettingsStore contract).
    private func runOverlayPlayback(
        store: SettingsStore,
        recorder: OverlayEventRecorder
    ) async throws {
        let engine = makeTestEngine(title: "Settings Overlay")
        await waitForEngineReady(engine)
        await engine.applySchedule(IntervalSchedule(intervals: pinnedCensorIntervals))

        let overlay = makeOverlayEngine(on: engine, recorder: recorder)
        overlay.apply(muteIntervals: pinnedMuteIntervals, mode: store.muteOverlayMode)

        addTeardownBlock {
            overlay.reset()
            engine.pause()
        }

        engine.play()
        await waitUntilPastLastBoundary(engine: engine, lastEnd: 3.4)
        engine.pause()
    }

    /// Task-004 AC1: while overlay is active under XCTest, `AVAudioPlayer.volume` is 0
    /// (or a silent injectable double with no audible output).
    private func assertOverlayPlayerSilentWhenActive(
        mode: MuteOverlayMode,
        file: StaticString = #filePath,
        line: UInt = #line
    ) async throws {
        let recorder = OverlayEventRecorder()
        let singleInterval: [(start: TimeInterval, end: TimeInterval)] = [
            (pinnedMuteIntervals[0].start, pinnedMuteIntervals[0].end),
        ]
        let engine = makeTestEngine(title: "Silent \(mode.rawValue)")
        await waitForEngineReady(engine)

        let censor = singleInterval.map {
            CensorInterval(start: $0.start, end: $0.end, action: .mute)
        }
        await engine.applySchedule(IntervalSchedule(intervals: censor))

        let overlay = makeOverlayEngine(on: engine, recorder: recorder)
        overlay.apply(muteIntervals: singleInterval, mode: mode)

        addTeardownBlock {
            overlay.reset()
            engine.pause()
        }

        engine.play()
        await waitUntilPlayhead(singleInterval[0].start + 0.05, engine: engine)

        XCTAssertGreaterThan(
            recorder.startEvents.count, 0,
            "\(mode.rawValue): overlay must start before volume assert",
            file: file, line: line
        )
        XCTAssertEqual(
            overlay.overlayPlayerVolumeForTesting, 0.0, accuracy: 0.0001,
            "\(mode.rawValue): overlay AVAudioPlayer.volume must be 0 under XCTest",
            file: file, line: line
        )
        engine.pause()
    }

    // MARK: - Task-004 AC1: overlay player silent under XCTest

    func testOverlayPlayerSilentUnderXCTest() async throws {
        try await assertOverlayPlayerSilentWhenActive(mode: .beep)
        try await assertOverlayPlayerSilentWhenActive(mode: .quack)
    }

    // MARK: - AC1: overlay start sync

    func testOverlayStartSync() async throws {
        let recorder = OverlayEventRecorder()
        _ = try await runOverlayPlayback(
            muteIntervals: pinnedMuteIntervals,
            mode: .beep,
            recorder: recorder
        )

        XCTAssertEqual(
            recorder.startEvents.count, 2,
            "Expected exactly 2 overlayStart events for pinned schedule; got \(recorder.startEvents.count)"
        )

        for (index, pair) in zip(pinnedMuteIntervals, recorder.startEvents).enumerated() {
            XCTAssertEqual(
                pair.1.assetID, "beep",
                "Start event \(index) must use beep asset ID"
            )
            XCTAssertEqual(
                pair.1.time, pair.0.start, accuracy: syncTolerance,
                "Start \(index): observed \(pair.1.time) must be within ±\(syncTolerance)s of interval start \(pair.0.start)"
            )
        }
    }

    // MARK: - AC2: overlay stop sync + exterior silence

    func testOverlayEndAndExteriorSilence() async throws {
        let recorder = OverlayEventRecorder()
        _ = try await runOverlayPlayback(
            muteIntervals: pinnedMuteIntervals,
            mode: .beep,
            recorder: recorder
        )

        XCTAssertEqual(
            recorder.stopEvents.count, 2,
            "Expected exactly 2 overlayStop events; got \(recorder.stopEvents.count)"
        )

        for (index, pair) in zip(pinnedMuteIntervals, recorder.stopEvents).enumerated() {
            XCTAssertEqual(
                pair.1.time, pair.0.end, accuracy: syncTolerance,
                "Stop \(index): observed \(pair.1.time) must be within ±\(syncTolerance)s of interval end \(pair.0.end)"
            )
        }

        let muted = try await OfflineRenderRMS.render(
            fixtureNamed: fixtureName,
            fixtureExtension: fixtureExt,
            intervals: pinnedCensorIntervals,
            fadeDuration: IntervalScheduler.defaultFadeDuration,
            loadedBy: type(of: self)
        )

        let exterior = muted.windowsOutside(by: OfflineRenderRMS.settleMargin)
        XCTAssertFalse(exterior.isEmpty, "Expected ≥1 exterior window for silence check")
        for window in exterior {
            let range = window.startTime...window.endTime
            XCTAssertEqual(
                recorder.overlayActiveSampleCount(inWindow: range), 0,
                "Exterior window [\(window.startTime), \(window.endTime)] must have 0 overlay-active samples"
            )
        }
    }

    // MARK: - AC3: offline interior RMS beep vs off

    func testOfflineRenderOverlayEnergy() async throws {
        let fade = IntervalScheduler.defaultFadeDuration

        let beepRender = try await OverlayOfflineComposite.render(
            fixtureNamed: fixtureName,
            fixtureExtension: fixtureExt,
            intervals: pinnedCensorIntervals,
            mode: .beep,
            fadeDuration: fade,
            loadedBy: type(of: self)
        )

        for interval in pinnedCensorIntervals {
            let interior = beepRender.windowsFullyInside(interval)
            XCTAssertFalse(
                interior.isEmpty,
                "Expected interior windows in [\(interval.start + OfflineRenderRMS.settleMargin), "
                    + "\(interval.end - OfflineRenderRMS.settleMargin)] for beep mode"
            )
            for window in interior {
                XCTAssertGreaterThan(
                    window.rms, 0.10,
                    "Beep interior [\(window.startTime), \(window.endTime)] RMS \(window.rms) must be > 0.10"
                )
            }
        }

        let offRender = try await OverlayOfflineComposite.render(
            fixtureNamed: fixtureName,
            fixtureExtension: fixtureExt,
            intervals: pinnedCensorIntervals,
            mode: .off,
            fadeDuration: fade,
            loadedBy: type(of: self)
        )

        for interval in pinnedCensorIntervals {
            let interior = offRender.windowsFullyInside(interval)
            XCTAssertFalse(interior.isEmpty, "Expected interior windows for off mode")
            for window in interior {
                XCTAssertLessThan(
                    window.rms, 0.01,
                    "Off interior [\(window.startTime), \(window.endTime)] RMS \(window.rms) must be < 0.01"
                )
            }
        }
    }

    // MARK: - AC4: SettingsStore mode → asset ID / event counts

    func testOverlaySettingRespected() async throws {
        let defaults = isolatedUserDefaults()
        let freshStore = SettingsStore(userDefaults: defaults)
        XCTAssertEqual(freshStore.muteOverlayMode, .off, "Fresh store must default to .off")

        let recorder = OverlayEventRecorder()

        var store = SettingsStore(userDefaults: defaults)
        store.muteOverlayMode = .beep
        try await runOverlayPlayback(store: store, recorder: recorder)

        XCTAssertEqual(recorder.startEvents.count, 2, "Beep mode: expected 2 starts")
        XCTAssertTrue(
            recorder.startEvents.allSatisfy { $0.assetID == "beep" },
            "Beep mode must emit assetID beep for every start"
        )

        recorder.reset()
        store = SettingsStore(userDefaults: defaults)
        store.muteOverlayMode = .quack
        try await runOverlayPlayback(store: store, recorder: recorder)

        XCTAssertEqual(recorder.startEvents.count, 2, "Quack mode: expected 2 starts")
        XCTAssertTrue(
            recorder.startEvents.allSatisfy { $0.assetID == "quack" },
            "Quack mode must emit assetID quack for every start"
        )

        recorder.reset()
        store.muteOverlayMode = .off
        try await runOverlayPlayback(store: store, recorder: recorder)

        XCTAssertEqual(
            recorder.startEvents.count, 0,
            "Off mode: expected 0 overlay starts across full fixture"
        )
    }

    // MARK: - AC5: seek resync — no orphan overlay outside intervals

    func testSeekResync() async throws {
        let singleInterval: [(start: TimeInterval, end: TimeInterval)] = [(1.0, 1.5)]
        let recorder = OverlayEventRecorder()
        let engine = makeTestEngine(title: "Seek Overlay")
        await waitForEngineReady(engine)

        let censor = singleInterval.map {
            CensorInterval(start: $0.start, end: $0.end, action: .mute)
        }
        await engine.applySchedule(IntervalSchedule(intervals: censor))

        let overlay = makeOverlayEngine(on: engine, recorder: recorder)
        overlay.apply(muteIntervals: singleInterval, mode: .beep)

        addTeardownBlock {
            overlay.reset()
            engine.pause()
        }

        engine.play()
        await waitUntilPlayhead(1.20, engine: engine)

        await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
            engine.seek(to: 2.5) {
                overlay.handleSeekCompleted(currentTime: engine.currentTime)
                continuation.resume()
            }
        }

        let deadline = Date().addingTimeInterval(seekResyncDeadline)
        while Date() < deadline {
            if recorder.activeOverlayCount == 0 {
                break
            }
            try await Task.sleep(nanoseconds: 10_000_000)
        }

        XCTAssertEqual(
            recorder.activeOverlayCount, 0,
            "activeOverlayCount must be 0 within \(seekResyncDeadline)s of seek completion"
        )

        // Snapshot AFTER seek resync. Clearing an orphan overlay may emit one
        // overlayStop (recorder only drops activeOverlayCount via stop events).
        // AC5 "no additional events" means none after resync until the next
        // scheduled interval — not "zero events during the seek itself."
        let eventsAfterResync = recorder.startEvents.count + recorder.stopEvents.count

        engine.play()
        // Advance past the seek land so any stale boundary would have a chance
        // to fire; fixture has no further mute intervals after 1.5.
        await waitUntilPlayhead(2.7, engine: engine)
        engine.pause()

        let totalEvents = recorder.startEvents.count + recorder.stopEvents.count
        XCTAssertEqual(
            totalEvents, eventsAfterResync,
            "No additional overlay events after seek to 2.5 s (outside interval); "
                + "got \(totalEvents) total vs \(eventsAfterResync) after resync"
        )
    }
}
