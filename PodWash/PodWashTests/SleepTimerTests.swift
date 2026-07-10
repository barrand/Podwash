//
//  SleepTimerTests.swift
//  PodWashTests
//
//  Slice 12 — Sleep timer with injectable clock (ADR-001 extension). AC3.
//
//  Asserts deadline fire, extend, and cancel via a monotonic TestClock — no
//  wall-clock Task.sleep or XCTestExpectation waits.
//
//  Pause counts use PlaybackPauseSpy conforming to production PlaybackPausing
//  (Engineer adds protocol; PlaybackEngine conforms). Spy provenance: hand-derived
//  from AC3 timeline (60.0 / 120.0 / 300.0 s pinned instants).
//
//  Until SleepTimer, MonotonicClock (slice deliverable "Clock"), and PlaybackPausing
//  exist (Engineer, later effort), this file fails to compile — intended TDD red state.
//
//  Note: the slice names the protocol `Clock`, but Swift's `_Concurrency.Clock`
//  shadows that identifier in test targets — Engineer should export `MonotonicClock`
//  (or an equivalently unambiguous name) in the PodWash module.
//

import XCTest
@testable import PodWash

/// Monotonic test clock: advances `now` and notifies SleepTimer (no wall-clock waits).
final class TestClock: MonotonicClock {
    private(set) var now: TimeInterval = 0
    var onAdvance: (() -> Void)?

    func advance(by delta: TimeInterval) {
        now += delta
        onAdvance?()
    }
}

/// Records pause invocations for AC3 pause-count asserts.
@MainActor
final class PlaybackPauseSpy: PlaybackPausing {
    private(set) var pauseCallCount = 0
    var isPlaying = true

    func pause() {
        pauseCallCount += 1
        isPlaying = false
    }

    func reset(playing: Bool = true) {
        pauseCallCount = 0
        isPlaying = playing
    }
}

@MainActor
final class SleepTimerTests: XCTestCase {

    // MARK: - AC3: fire, extend, cancel with injected TestClock

    func testTimerFireExtendCancel() {
        // --- Scenario 1: arm 60 s at T=0; fire exactly at T=60.0 ---
        let clock1 = TestClock()
        let spy1 = PlaybackPauseSpy()
        let timer1 = SleepTimer(engine: spy1, clock: clock1)
        XCTAssertTrue(spy1.isPlaying, "precondition: engine reports playing when armed")

        timer1.arm(seconds: 60.0)

        clock1.advance(by: 59.9)
        XCTAssertEqual(spy1.pauseCallCount, 0, "No pause before deadline at T=59.9")

        clock1.advance(by: 0.1)
        XCTAssertEqual(spy1.pauseCallCount, 1, "Exactly one pause at T=60.0")

        // --- Scenario 2: extend +120 s at T=30 → deadline T=150 ---
        let clock2 = TestClock()
        let spy2 = PlaybackPauseSpy()
        let timer2 = SleepTimer(engine: spy2, clock: clock2)

        timer2.arm(seconds: 60.0)
        clock2.advance(by: 30.0)
        timer2.extend(by: 120.0)

        clock2.advance(by: 119.9)
        XCTAssertEqual(
            spy2.pauseCallCount, 0,
            "No pause before extended deadline at T=149.9"
        )

        clock2.advance(by: 0.1)
        XCTAssertEqual(
            spy2.pauseCallCount, 1,
            "Exactly one pause at extended deadline T=150.0"
        )

        // --- Scenario 3: cancel at T=30 → no pause through T=300 ---
        let clock3 = TestClock()
        let spy3 = PlaybackPauseSpy()
        let timer3 = SleepTimer(engine: spy3, clock: clock3)

        timer3.arm(seconds: 60.0)
        clock3.advance(by: 30.0)
        timer3.cancel()

        clock3.advance(by: 270.0)
        XCTAssertEqual(
            spy3.pauseCallCount, 0,
            "Cancel at T=30 must prevent pause through T=300.0"
        )
    }
}
