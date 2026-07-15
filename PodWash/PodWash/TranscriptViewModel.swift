//
//  TranscriptViewModel.swift
//  PodWash
//
//  Slice 26 — Pure listened / skipped-ad classification (ADR-022 §2).
//

import Foundation

struct TranscriptWordDisplay: Equatable, Sendable {
    var index: Int
    var word: TimedWord
    var listened: Bool
    var skippedAd: Bool
}

/// Pure classification over transcript + intervals + resume position.
struct TranscriptViewModel: Equatable, Sendable {
    var words: [TranscriptWordDisplay]
    var wordCount: Int { words.count }
    var listenedCount: Int
    var skippedAdCount: Int
    /// Whole seconds for `transcript.scrollAnchor` (nearest scroll target time).
    var scrollAnchorSeconds: Int
    /// Word index used for ScrollViewReader.scrollTo on open.
    var scrollAnchorIndex: Int

    /// Builds display rows. `playbackPosition` from `ResumePositionStore` /
    /// `CDEpisode.playbackPosition` (0 when unknown).
    static func make(
        transcript: [TimedWord],
        intervals: [CensorInterval],
        playbackPosition: TimeInterval
    ) -> TranscriptViewModel {
        let skipIntervals = intervals.filter {
            $0.source == .unrelatedContent && $0.action == .skip
        }

        var listenedCount = 0
        var skippedAdCount = 0
        let displays: [TranscriptWordDisplay] = transcript.enumerated().map { index, word in
            let overlapsSkip = skipIntervals.contains { interval in
                word.start < interval.end && word.end > interval.start
            }
            let skippedAd = overlapsSkip
            let listened = !skippedAd && word.end <= playbackPosition
            if skippedAd { skippedAdCount += 1 }
            if listened { listenedCount += 1 }
            return TranscriptWordDisplay(
                index: index,
                word: word,
                listened: listened,
                skippedAd: skippedAd
            )
        }

        let (anchorIndex, anchorSeconds) = scrollAnchor(
            transcript: transcript,
            playbackPosition: playbackPosition
        )

        return TranscriptViewModel(
            words: displays,
            listenedCount: listenedCount,
            skippedAdCount: skippedAdCount,
            scrollAnchorSeconds: anchorSeconds,
            scrollAnchorIndex: anchorIndex
        )
    }

    private static func scrollAnchor(
        transcript: [TimedWord],
        playbackPosition: TimeInterval
    ) -> (index: Int, seconds: Int) {
        guard playbackPosition > 0 else {
            return (0, 0)
        }
        guard !transcript.isEmpty else {
            return (0, Int(round(playbackPosition)))
        }

        if let containing = transcript.enumerated().first(where: {
            $0.element.start <= playbackPosition && playbackPosition < $0.element.end
        }) {
            return (containing.offset, Int(round(containing.element.start)))
        }

        if let lastListened = transcript.enumerated().last(where: { $0.element.end <= playbackPosition }) {
            return (lastListened.offset, Int(round(lastListened.element.start)))
        }

        return (0, Int(round(transcript[0].start)))
    }
}
