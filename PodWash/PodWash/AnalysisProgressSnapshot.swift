//
//  AnalysisProgressSnapshot.swift
//  PodWash
//
//  Slice 20 — Progress seam for analysis timeline (ADR-018).
//

import Foundation

struct AdTimeRange: Equatable, Sendable {
    var start: Double
    var end: Double
}

/// Progress published while analysis runs (Slice 20 seam).
struct AnalysisProgressSnapshot: Equatable, Sendable {
    var episodeDuration: Double
    var processedEnd: Double
    var processingStart: Double
    var processingEnd: Double
    var adRanges: [AdTimeRange]
}
