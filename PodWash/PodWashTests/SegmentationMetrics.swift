//
//  SegmentationMetrics.swift
//  PodWashTests
//
//  Slice 18 — IoU-based precision/recall helpers for segmentation spike fixtures.
//  Test-target only; production segmenters do not score themselves (ADR-012 §3.4).
//

import Foundation

/// Hand-labeled positive range from `golden_segments.json`.
struct GoldenSegment: Codable, Equatable {
    let start: Double
    let end: Double

    var duration: Double { end - start }
}

/// Greedy one-to-one IoU matching result (ADR-012 §3.4).
struct SegmentationScore: Equatable {
    let truePositives: Int
    let falsePositives: Int
    let falseNegatives: Int

    var precision: Double {
        let denom = truePositives + falsePositives
        return denom > 0 ? Double(truePositives) / Double(denom) : 0
    }

    var recall: Double {
        let denom = truePositives + falseNegatives
        return denom > 0 ? Double(truePositives) / Double(denom) : 0
    }
}

enum SegmentationMetrics {
    /// Temporal intersection-over-union for half-open intervals `[start, end)`.
    static func iou(_ a: (start: Double, end: Double), _ b: (start: Double, end: Double)) -> Double {
        let intersectionStart = max(a.start, b.start)
        let intersectionEnd = min(a.end, b.end)
        let intersection = max(0, intersectionEnd - intersectionStart)
        let union = (a.end - a.start) + (b.end - b.start) - intersection
        guard union > 0 else { return 0 }
        return intersection / union
    }

    /// Greedy one-to-one assignment by highest IoU; pair accepted iff IoU ≥ `iouThreshold`.
    static func score(
        predictions: [(start: Double, end: Double)],
        goldens: [(start: Double, end: Double)],
        iouThreshold: Double = 0.5
    ) -> SegmentationScore {
        var unmatchedGoldens = Array(goldens.indices)
        var truePositives = 0

        let sortedPairs: [(pred: Int, golden: Int, iou: Double)] = predictions.indices.flatMap { p in
            goldens.indices.map { g in
                (pred: p, golden: g, iou: iou(predictions[p], goldens[g]))
            }
        }
        .filter { $0.iou >= iouThreshold }
        .sorted { $0.iou > $1.iou }

        var matchedPredictions = Set<Int>()
        var matchedGoldens = Set<Int>()

        for pair in sortedPairs {
            guard !matchedPredictions.contains(pair.pred), !matchedGoldens.contains(pair.golden) else { continue }
            matchedPredictions.insert(pair.pred)
            matchedGoldens.insert(pair.golden)
            truePositives += 1
        }

        let falsePositives = predictions.count - truePositives
        let falseNegatives = goldens.count - truePositives
        return SegmentationScore(
            truePositives: truePositives,
            falsePositives: falsePositives,
            falseNegatives: falseNegatives
        )
    }
}
