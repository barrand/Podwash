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

/// Sentence-bounded span of transcript words with a display start time.
struct TranscriptParagraph: Equatable, Sendable {
    var firstWordIndex: Int
    var lastWordIndex: Int
    var startSeconds: Int
    var formattedStartTimestamp: String
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

    /// Groups words into paragraphs ending after `.`, `?`, or `!` (trimmed word text).
    static func paragraphs(from transcript: [TimedWord]) -> [TranscriptParagraph] {
        guard !transcript.isEmpty else { return [] }

        var result: [TranscriptParagraph] = []
        var paragraphStart = 0

        for (index, timedWord) in transcript.enumerated() {
            guard endsSentence(timedWord.word) else { continue }
            result.append(makeParagraph(transcript: transcript, startIndex: paragraphStart, endIndex: index))
            paragraphStart = index + 1
        }

        if paragraphStart < transcript.count {
            result.append(
                makeParagraph(
                    transcript: transcript,
                    startIndex: paragraphStart,
                    endIndex: transcript.count - 1
                )
            )
        }

        return result
    }

    private static func endsSentence(_ word: String) -> Bool {
        let trimmed = word.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let last = trimmed.last else { return false }
        return last == "." || last == "?" || last == "!"
    }

    private static func makeParagraph(
        transcript: [TimedWord],
        startIndex: Int,
        endIndex: Int
    ) -> TranscriptParagraph {
        let startSeconds = Int(transcript[startIndex].start.rounded(.down))
        return TranscriptParagraph(
            firstWordIndex: startIndex,
            lastWordIndex: endIndex,
            startSeconds: startSeconds,
            formattedStartTimestamp: formatStartTimestamp(seconds: startSeconds)
        )
    }

    /// `m:ss` under 10 minutes, `mm:ss` from 10 minutes, `h:mm:ss` from one hour.
    static func formatStartTimestamp(seconds: Int) -> String {
        let total = max(0, seconds)
        if total >= 3600 {
            let hours = total / 3600
            let minutes = (total % 3600) / 60
            let remainder = total % 60
            return String(format: "%d:%02d:%02d", hours, minutes, remainder)
        }
        let minutes = total / 60
        let remainder = total % 60
        return String(format: "%d:%02d", minutes, remainder)
    }
}
