//
//  ContentSegmenting.swift
//  PodWash
//
//  Slice 18 — Unrelated-content segmentation spike (ADR-012).
//  Public surface for on-device transcript segmentation. Slice 19 maps
//  `ContentSegment` ranges → `CensorInterval` with the user-selected action.
//

import Foundation

/// Positive-class superfluous / tangential span (seconds from episode start).
/// Slice 19 maps these to `CensorInterval` with the user-selected action.
nonisolated struct ContentSegment: Codable, Equatable, Sendable {
    let start: Double
    let end: Double
}

/// On-device segmenter over an ASR transcript. Implementations must be
/// deterministic for a given `[TimedWord]` input (required for committed
/// execution evidence).
protocol ContentSegmenting: Sendable {
    /// Stable approach id written into `SegmentationBenchmark.approach`
    /// (e.g. `"heuristic-cue-v1"`).
    var approachIdentifier: String { get }

    /// Returns disjoint positive segments with `end > start`. Empty array is a
    /// valid algorithmic outcome but fails AC2 if written as the committed
    /// artifact (`segmentCount == 0`).
    func segments(in transcript: [TimedWord]) -> [ContentSegment]
}

/// Execution-evidence record for one benchmark run. Codable →
/// `Fixtures/segmentation/benchmark-results.json`.
nonisolated struct SegmentationBenchmark: Codable, Equatable, Sendable {
    let approach: String
    let precision: Double
    let recall: Double
    let segmentCount: Int
    let segments: [ContentSegment]
    let durationSeconds: Double
    let inferenceSeconds: Double
}
