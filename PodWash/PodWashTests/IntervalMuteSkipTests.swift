//
//  IntervalMuteSkipTests.swift
//  PodWashTests
//
//  Slice 04 — Interval mute/skip. Typed consumption (AC1), skip seek-past (AC4),
//  and seek-into-mute re-render (AC5) per ADR-002 §2/§5/§6.
//
//  AC4 drives the real PlaybackEngine on a local fixture using an
//  expectation + periodic time observer (no sleep polling). AC5 re-renders the
//  fixture through the SAME mix with the reader starting inside a mute interval.
//
//  Until IntervalScheduler / PlaybackEngine.applySchedule exist (Engineer, later
//  effort), this file will fail to compile on those missing symbols. That is the
//  intended TDD red state.
//

import AVFoundation
import XCTest
@testable import PodWash

@MainActor
final class IntervalMuteSkipTests: XCTestCase {

    private let fixtureName = "sine-300hz-5s"
    private let fixtureExt = "wav"

    /// Copies the bundled WAV fixture to a temp URL (mirrors PlaybackEngineTests):
    /// the engine plays from a file URL. Fails (never skips) if the fixture is
    /// missing so a setup gap surfaces as a red test, not a skip.
    private func fixtureURL(file: StaticString = #filePath, line: UInt = #line) -> URL {
        let bundle = Bundle(for: type(of: self))
        guard let bundledURL = bundle.url(forResource: fixtureName, withExtension: fixtureExt, subdirectory: "Fixtures/audio")
            ?? bundle.url(forResource: fixtureName, withExtension: fixtureExt) else {
            XCTFail("Missing \(fixtureName).\(fixtureExt) in \(bundle.bundlePath)", file: file, line: line)
            return URL(fileURLWithPath: "/dev/null")
        }
        let tempURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("podwash-\(fixtureName).\(fixtureExt)")
        try? FileManager.default.removeItem(at: tempURL)
        do {
            try FileManager.default.copyItem(at: bundledURL, to: tempURL)
        } catch {
            XCTFail("Could not copy fixture to temp: \(error)", file: file, line: line)
            return bundledURL
        }
        return tempURL
    }

    // MARK: - AC1: scheduler consumes IntervalBuilder output directly

    func testSchedulerConsumesIntervalBuilderOutput() {
        // Slice 02 IntervalBuilder produces the merged, padded [CensorInterval].
        let transcript = [
            TimedWord(word: "damn", start: 1.00, end: 1.30),
            TimedWord(word: "clean", start: 2.00, end: 2.20),
            TimedWord(word: "shit", start: 3.00, end: 3.10),
        ]
        let built = IntervalBuilder.buildIntervals(from: transcript, targetSet: ["damn", "shit"])
        XCTAssertFalse(built.isEmpty, "precondition: IntervalBuilder should produce intervals")

        // Typed interface: IntervalSchedule's initializer parameter is
        // [CensorInterval], so it accepts IntervalBuilder output directly. This is a
        // compile-time proof of the module dependency (AC1) — no adapter/conversion,
        // no re-derivation of interval math inside the scheduler.
        let schedule = IntervalSchedule(intervals: built)

        // Structural AC1: the scheduler stores the builder output verbatim (same
        // count, same elements, same order), so it does NOT re-pad or re-merge.
        XCTAssertEqual(
            schedule.intervals, built,
            "IntervalSchedule must store IntervalBuilder output unchanged (no re-pad/re-merge)"
        )
        XCTAssertEqual(schedule.intervals.count, built.count)

        // The default fade comes from IntervalScheduler (single source of truth).
        XCTAssertEqual(
            schedule.fadeDuration, IntervalScheduler.defaultFadeDuration, accuracy: 1e-12,
            "default fade should come from IntervalScheduler.defaultFadeDuration"
        )
    }

    // MARK: - AC4: skip advances currentTime past interval end (+0 / −0.1 s)

    func testSkipAdvancesPastInterval() async {
        let engine = PlaybackEngine(
            url: fixtureURL(),
            title: "Skip Test",
            artist: "PodWash QA"
        )
        let skip = CensorInterval(start: 2.0, end: 2.5, action: .skip)
        await engine.applySchedule(IntervalSchedule(intervals: [skip]))

        // Position just before the skip start, then play across the boundary.
        await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
            engine.seek(to: 1.9) { continuation.resume() }
        }

        // Wait (event-driven, no sleep) until the playhead is clearly past the skip
        // end — proof the boundary observer fired and the skip seek completed.
        let reached = expectation(description: "playhead advances past skip end")
        var didFulfill = false
        var token: Any?
        token = engine.avPlayer.addPeriodicTimeObserver(
            forInterval: CMTime(seconds: 0.02, preferredTimescale: 600),
            queue: .main
        ) { time in
            if time.seconds >= skip.end + 0.1 && !didFulfill {
                didFulfill = true
                reached.fulfill()
            }
        }
        addTeardownBlock { [engine] in
            if let token { engine.avPlayer.removeTimeObserver(token) }
            engine.pause()
        }

        engine.play()
        await fulfillment(of: [reached], timeout: 10)

        // `currentTime` is frozen at the skip seek's landing value (the seek
        // completion is the only writer between play() and here), so it reflects
        // where the skip landed without ongoing-playback drift.
        XCTAssertGreaterThanOrEqual(
            engine.currentTime, skip.end - 0.1,
            "skip should land at ≥ end − 0.1 (\(skip.end - 0.1)); got \(engine.currentTime)"
        )
        XCTAssertLessThanOrEqual(
            engine.currentTime, skip.end,
            "skip must not overshoot past end (\(skip.end)); got \(engine.currentTime)"
        )
        XCTAssertEqual(
            engine.avPlayer.timeControlStatus, .playing,
            "timeControlStatus must remain .playing across the skip"
        )
    }

    // MARK: - AC5: seek into an active mute window retains the schedule (two-part)

    func testSeekReappliesScheduleRMS() async throws {
        let mutes: [CensorInterval] = [
            CensorInterval(start: 1.0, end: 1.5, action: .mute),
            CensorInterval(start: 3.0, end: 3.4, action: .mute),
        ]

        // Part 1 — engine-level retention. Applying the schedule attaches a mute mix
        // to the item; seeking into the window must NOT lose it. The mix is
        // playhead-independent (absolute asset time), so the same instance stays on
        // the item across the seek (ADR-002 §6 "Revision", point 1).
        let engine = PlaybackEngine(
            url: fixtureURL(),
            title: "Seek Test",
            artist: "PodWash QA"
        )
        await engine.applySchedule(IntervalSchedule(intervals: mutes))

        let appliedMix = engine.avPlayer.currentItem?.audioMix
        XCTAssertNotNil(
            appliedMix,
            "applySchedule must attach a non-nil audioMix for a schedule with .mute intervals"
        )

        await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
            engine.seek(to: 1.2) { continuation.resume() }
        }

        XCTAssertTrue(
            engine.avPlayer.currentItem?.audioMix === appliedMix,
            "seeking into a mute window must retain the applied audioMix (schedule not lost)"
        )

        // Part 2 — offline re-render. The offline reader CANNOT be started inside a
        // mute interval (it drops the pre-start ramp state and renders base volume;
        // ADR-002 §6), so render the full context from t = 0 and assert the interior
        // window at the 1.2 s seek target is silent. [1.2, 1.3] ⊆ [s + M, e − M] =
        // [1.03, 1.47], so it is in the provably-muted interior.
        let render = try await OfflineRenderRMS.render(
            fixtureNamed: fixtureName,
            fixtureExtension: fixtureExt,
            intervals: mutes,
            fadeDuration: IntervalScheduler.defaultFadeDuration,
            loadedBy: type(of: self)         // no startTime → reader from t = 0
        )

        let seekTargetWindows = render.windows(fullyWithin: 1.2...1.3)
        XCTAssertFalse(
            seekTargetWindows.isEmpty,
            "Expected interior windows in the [1.2, 1.3] seek-target region"
        )
        for window in seekTargetWindows {
            XCTAssertLessThan(
                window.rms, 0.01,
                "Interior window at seek target [\(window.startTime), \(window.endTime)] "
                    + "RMS \(window.rms) must be < 0.01 (mute holds at the seek point)"
            )
        }
    }
}
