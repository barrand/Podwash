//
//  IntervalBuilder.swift
//  PodWash
//
//  Slice 02 — Matching engine. Swift port of docs/specs/matching-spec.md
//  §5 (padding + midpoint expansion, including the t=0 clamp quirk) and
//  §6 (sort-and-merge). Ported from the normative spec.
//

import Foundation

/// The action applied over a censor interval. The sort-and-merge step is
/// action-agnostic (spec §6): the builder merges within one action list.
enum CensorAction: String, Codable, Equatable {
    case mute
    case skip
}

/// A padded, mergeable censor interval in seconds from episode start.
struct CensorInterval: Codable, Equatable {
    var start: Double
    var end: Double
    var action: CensorAction

    init(start: Double, end: Double, action: CensorAction = .mute) {
        self.start = start
        self.end = end
        self.action = action
    }
}

/// Padding, midpoint expansion, and sort-and-merge per matching-spec §5–6.
enum IntervalBuilder {

    // MARK: - Constants (matching-spec §1, normative)

    static let startPaddingSeconds: Double = 0.080
    static let endPaddingSeconds: Double = 0.120
    static let minCensorSeconds: Double = 0.180

    // MARK: - Padding + midpoint expansion (spec §5)

    /// Pad a single matched word's `[start, end]` per spec §5, applying the
    /// midpoint-expansion branch (and its t=0 clamp quirk) exactly as written.
    static func paddedInterval(
        wordStart start: Double,
        wordEnd end: Double,
        action: CensorAction = .mute
    ) -> CensorInterval {
        var paddedStart = max(0.0, start - startPaddingSeconds)
        var paddedEnd = end + endPaddingSeconds

        if (paddedEnd - paddedStart) < minCensorSeconds {
            let midpoint = (paddedStart + paddedEnd) / 2.0
            let halfDuration = minCensorSeconds / 2.0
            // Quirk (spec §5): new start is re-clamped at 0.0 but end is NOT
            // re-extended to compensate, so an interval hugging t=0 may still
            // be shorter than MIN_CENSOR_SECONDS.
            paddedStart = max(0.0, midpoint - halfDuration)
            paddedEnd = midpoint + halfDuration
        }

        return CensorInterval(start: paddedStart, end: paddedEnd, action: action)
    }

    // MARK: - Sort-and-merge (spec §6)

    /// Sort ascending by start and merge overlapping/touching intervals.
    /// Merge condition is `<=` (touching intervals merge); merged end is
    /// `max(previous.end, interval.end)` so a contained interval never shortens
    /// its container. Merge is action-agnostic; the surviving interval keeps the
    /// earliest interval's action.
    static func merge(_ intervals: [CensorInterval]) -> [CensorInterval] {
        let sorted = intervals.sorted { $0.start < $1.start }
        var merged: [CensorInterval] = []
        for interval in sorted {
            if var last = merged.last, interval.start <= last.end {
                last.end = max(last.end, interval.end)
                merged[merged.count - 1] = last
            } else {
                merged.append(interval)
            }
        }
        return merged
    }

    // MARK: - Pipeline entry point

    /// Full transcript → merged censor intervals pipeline (spec §3–6):
    /// drop words with non-finite offsets, normalize + exact-match each token
    /// against the (re-normalized) target set, pad each match, then sort-merge.
    static func buildIntervals(
        from transcript: [TimedWord],
        targetSet: Set<String>,
        action: CensorAction = .mute
    ) -> [CensorInterval] {
        let normalizedTargets = WordMatcher.normalizedTargetSet(targetSet)
        let padded = transcript.compactMap { word -> CensorInterval? in
            guard word.start.isFinite, word.end.isFinite else { return nil }
            guard WordMatcher.matches(WordMatcher.normalize(word.word), in: normalizedTargets) else {
                return nil
            }
            return paddedInterval(wordStart: word.start, wordEnd: word.end, action: action)
        }
        return merge(padded)
    }
}
