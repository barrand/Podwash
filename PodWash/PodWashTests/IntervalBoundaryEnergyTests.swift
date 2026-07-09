//
//  IntervalBoundaryEnergyTests.swift
//  PodWashTests
//
//  Slice 04 — Interval mute/skip. Offline-render RMS + boundary-continuity
//  assertions (AC2, AC3) per ADR-002 §4/§7 on the pinned 300 Hz / amplitude-0.9
//  lossless fixture (see Fixtures/audio/sine-300hz-5s.provenance.md).
//
//  These tests render the fixture through the SAME AVMutableAudioMix that
//  IntervalScheduler builds (ADR-000 §2) and assert numeric energy thresholds.
//  Expected inputs (silent vs. full windows, fade width, boundary continuity) are
//  derived from the interval list and ADR-002 §4 ramp placement — never from
//  IntervalScheduler output — so the golden is non-circular.
//
//  Until IntervalScheduler exists (Engineer, later effort), this file will fail to
//  compile on the missing symbol. That is the intended TDD red state.
//

import AVFoundation
import XCTest
@testable import PodWash

final class IntervalBoundaryEnergyTests: XCTestCase {

    // MARK: - Fixture / interval constants (ADR-002 §7/§8)

    private let fixtureName = "sine-300hz-5s"
    private let fixtureExt = "wav"

    /// The AC2 interval list: two disjoint mute intervals.
    private let muteIntervals: [CensorInterval] = [
        CensorInterval(start: 1.0, end: 1.5, action: .mute),
        CensorInterval(start: 3.0, end: 3.4, action: .mute),
    ]

    // MARK: - AC2: windowed RMS inside vs. outside intervals

    func testOfflineRenderRMSInsideAndOutsideIntervals() async throws {
        let fade = IntervalScheduler.defaultFadeDuration
        let render = try await OfflineRenderRMS.render(
            fixtureNamed: fixtureName,
            fixtureExtension: fixtureExt,
            intervals: muteIntervals,
            fadeDuration: fade,
            loadedBy: type(of: self)
        )

        // Interior of each interval: the renderer smooths the outside-placed fade
        // ~20 ms into the interval (ADR-002 §4 "Revision"), so only the settle-inset
        // region [s + M, e − M] (M = 30 ms) is provably silent → RMS < 0.01.
        // `windowsFullyInside` applies the inset; the ±M transition bands are
        // don't-care and are intentionally not asserted.
        for interval in muteIntervals {
            let inside = render.windowsFullyInside(interval)
            XCTAssertFalse(
                inside.isEmpty,
                "Expected ≥1 interior window in [\(interval.start + OfflineRenderRMS.settleMargin), "
                    + "\(interval.end - OfflineRenderRMS.settleMargin)]"
            )
            for window in inside {
                XCTAssertLessThan(
                    window.rms, 0.01,
                    "Interior window [\(window.startTime), \(window.endTime)] "
                        + "(idx \(window.index)) RMS \(window.rms) must be < 0.01 (muted)"
                )
            }
        }

        // Outside every interval by ≥ M (clear of the transition band): full-scale
        // sine → RMS ≈ 0.9/√2 ≈ 0.636 > 0.25 full scale.
        let outside = render.windowsOutside(by: OfflineRenderRMS.settleMargin)
        XCTAssertFalse(outside.isEmpty, "Expected ≥1 outside-by-margin window")
        for window in outside {
            XCTAssertGreaterThan(
                window.rms, 0.25,
                "Outside-by-margin window [\(window.startTime), \(window.endTime)] "
                    + "(idx \(window.index)) RMS \(window.rms) must be > 0.25 (full volume)"
            )
        }
    }

    // MARK: - AC3: fade ramp duration + boundary continuity

    func testFadeRampAndBoundaryContinuity() async throws {
        let fade = IntervalScheduler.defaultFadeDuration
        let render = try await OfflineRenderRMS.render(
            fixtureNamed: fixtureName,
            fixtureExtension: fixtureExt,
            intervals: muteIntervals,
            fadeDuration: fade,
            loadedBy: type(of: self)
        )

        // Measured RENDERED fade width at each boundary matches the configured
        // value ±10 ms. `defaultFadeDuration` (0.020 s) is matched to the renderer's
        // ~20 ms smoothing floor, so the rendered width ≈ commanded (ADR-002 §4/§7).
        for interval in muteIntervals {
            let onset = try XCTUnwrap(
                render.measuredFadeWidth(boundary: interval.start, kind: .muteOnset),
                "Could not locate down-ramp transition before start \(interval.start)"
            )
            XCTAssertEqual(
                onset, fade, accuracy: 0.010,
                "Down-ramp width at start \(interval.start) = \(onset) s; expected \(fade) s ±10 ms"
            )

            let release = try XCTUnwrap(
                render.measuredFadeWidth(boundary: interval.end, kind: .muteRelease),
                "Could not locate up-ramp transition after end \(interval.end)"
            )
            XCTAssertEqual(
                release, fade, accuracy: 0.010,
                "Up-ramp width at end \(interval.end) = \(release) s; expected \(fade) s ±10 ms"
            )
        }

        // No sample-to-sample discontinuity > 0.05 full scale within ±1 window of
        // any boundary. On the 300 Hz / 0.9 fixture inherent slew ≈ 0.0385; a
        // mix-induced click (e.g. hard cut) would exceed 0.05.
        for interval in muteIntervals {
            for boundary in [interval.start, interval.end] {
                let maxDelta = render.maxAdjacentDelta(aroundTime: boundary, windowRadius: 1)
                XCTAssertLessThanOrEqual(
                    maxDelta, 0.05,
                    "Max adjacent raw-sample |Δ| \(maxDelta) near boundary \(boundary) "
                        + "must be ≤ 0.05 (no click)"
                )
            }
        }
    }
}
