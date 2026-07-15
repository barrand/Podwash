//
//  SuperSeekBarModelTests.swift
//  PodWashTests
//
//  Slice 25 — Super seek bar pure math (ADR-021 §2, AC7).
//  Golden values hand-computed from slice-25 fixture pins (120.0 s duration,
//  15.0 s elapsed → 15/120 = 0.125; frontier clamp 90 → 60) — not from
//  implementation under test.
//
//  Until SuperSeekBarModel exists (Engineer, slice-25 implement), this file
//  fails to compile — intended TDD red state.
//

import XCTest
@testable import PodWash

final class SuperSeekBarModelTests: XCTestCase {

    private let episodeDuration = 120.0
    private let playheadTolerance = 0.02
    private let clampTolerance = 0.5

    // MARK: - AC7: playhead normalization + frontier clamp

    func testPlayheadPositionAndFrontierClamp() {
        let normalized = SuperSeekBarModel.normalizedPlayhead(elapsed: 15.0, duration: episodeDuration)
        XCTAssertEqual(
            normalized,
            0.125,
            accuracy: playheadTolerance,
            "15.0 s on 120.0 s duration must normalize to 0.125 ± 0.02"
        )

        let clamped = SuperSeekBarModel.clampedSeek(requested: 90.0, processedEnd: 60.0)
        XCTAssertEqual(
            clamped,
            60.0,
            accuracy: clampTolerance,
            "Seek to 90.0 s with processedEnd 60.0 must clamp to 60.0 ± 0.5 s"
        )
    }
}
