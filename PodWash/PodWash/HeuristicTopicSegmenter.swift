//
//  HeuristicTopicSegmenter.swift
//  PodWash
//
//  Deterministic TopicSegmenting wrapper around HeuristicContentSegmenter
//  (tests + AI-unavailable fallback path without Foundation Models).
//

import Foundation

/// Always runs `HeuristicContentSegmenter` (never calls Foundation Models).
nonisolated struct HeuristicTopicSegmenter: TopicSegmenting {
    var approachIdentifier: String { HeuristicContentSegmenter().approachIdentifier }
    var isModelAvailable: Bool { false }

    func segments(in transcript: [TimedWord], context: SegmentationContext) async -> [ContentSegment] {
        _ = context
        return HeuristicContentSegmenter().segments(in: transcript)
    }
}
