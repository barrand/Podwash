//
//  AnalysisProgressPacing.swift
//  PodWash
//
//  Slice 20 — Injectable wait between stepped analysis snapshots (ADR-018).
//

import Foundation

protocol AnalysisProgressPacing: Sendable {
    func waitBetweenSnapshots() async
}

struct ImmediateAnalysisProgressPacing: AnalysisProgressPacing {
    func waitBetweenSnapshots() async {}
}

/// Short yields so XCTest can observe mid-run AX values; total analyze wall
/// time stays under AC4/AC5 budgets (≤ 5.0 s from toggle).
/// Budget with VM holds: ~2.5 s first-snapshot hold + 2×0.6 s inter-step pacing
/// + ~0.5 s terminal hold ≈ 4.2 s (under the 5.0 s AC4/AC5 ceiling).
struct FixtureAnalysisProgressPacing: AnalysisProgressPacing {
    var delayNanoseconds: UInt64 = 600_000_000

    func waitBetweenSnapshots() async {
        try? await Task.sleep(nanoseconds: delayNanoseconds)
    }
}
