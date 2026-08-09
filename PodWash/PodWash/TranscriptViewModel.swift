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

/// A bounded, lazily-rendered piece of a paragraph. Blocks are a rendering and
/// scroll-target detail only; they never add a visible timestamp or paragraph gap.
struct TranscriptRenderBlock: Equatable, Sendable, Identifiable {
    let paragraphIndex: Int
    let firstWordIndex: Int
    let lastWordIndex: Int
    let showsParagraphHeader: Bool
    let endsParagraph: Bool

    var id: String { "transcript.renderBlock.\(firstWordIndex)" }
}

/// Pure classification over transcript + intervals + resume position.
struct TranscriptViewModel: Equatable, Sendable {
    static let maximumWordsPerRenderBlock = 24

    /// Source timing retained for live active-word lookup without rebuilding it
    /// from display rows on every playback tick.
    var timedWords: [TimedWord]
    var words: [TranscriptWordDisplay]
    /// Computed once at presentation time; never rebuild this on playback ticks.
    var paragraphs: [TranscriptParagraph]
    /// Direct lazy scroll targets that bound even an unpunctuated ASR paragraph.
    var renderBlocks: [TranscriptRenderBlock]
    private var renderBlockIndexByWordIndex: [Int]
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
            let listened = isListened(
                word: word,
                skippedAd: skippedAd,
                playhead: playbackPosition
            )
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
        let paragraphs = paragraphs(from: transcript)
        let renderBlocks = renderBlocks(from: paragraphs)
        let renderBlockIndexByWordIndex = renderBlockIndexMap(
            wordCount: transcript.count,
            renderBlocks: renderBlocks
        )

        return TranscriptViewModel(
            timedWords: transcript,
            words: displays,
            paragraphs: paragraphs,
            renderBlocks: renderBlocks,
            renderBlockIndexByWordIndex: renderBlockIndexByWordIndex,
            listenedCount: listenedCount,
            skippedAdCount: skippedAdCount,
            scrollAnchorSeconds: anchorSeconds,
            scrollAnchorIndex: anchorIndex
        )
    }

    /// The stable lazy target containing `wordIndex`, if the transcript has one.
    func renderBlockIndex(containingWordAt wordIndex: Int) -> Int? {
        guard renderBlockIndexByWordIndex.indices.contains(wordIndex) else { return nil }
        let blockIndex = renderBlockIndexByWordIndex[wordIndex]
        return renderBlocks.indices.contains(blockIndex) ? blockIndex : nil
    }

    /// Index of the word that should be “current” for playhead `t` (ADR-028 §3).
    /// Half-open contain first; else last word with `end <= t`; else `0`.
    static func activeWordIndex(
        transcript: [TimedWord],
        playhead: TimeInterval
    ) -> Int {
        guard !transcript.isEmpty else { return 0 }

        if let containing = transcript.enumerated().first(where: {
            $0.element.start <= playhead && playhead < $0.element.end
        }) {
            return containing.offset
        }

        if let lastEnded = transcript.enumerated().last(where: { $0.element.end <= playhead }) {
            return lastEnded.offset
        }

        return 0
    }

    /// A word becomes listened when playback reaches its exclusive end. This is
    /// shared by the open-time snapshot and the live transcript renderer so the
    /// grey history stays aligned with the current playhead.
    static func isListened(
        word: TimedWord,
        skippedAd: Bool,
        playhead: TimeInterval
    ) -> Bool {
        !skippedAd && word.end <= playhead
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

        let index = activeWordIndex(transcript: transcript, playhead: playbackPosition)
        return (index, Int(round(transcript[index].start)))
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

    /// Splits semantic paragraphs into small, direct lazy children. A sentence
    /// remains visually continuous; only long sentences gain invisible block seams
    /// so a distant word can always be scrolled into a lazily-rendered view.
    static func renderBlocks(
        from paragraphs: [TranscriptParagraph],
        maximumWordsPerBlock: Int = maximumWordsPerRenderBlock
    ) -> [TranscriptRenderBlock] {
        let limit = max(1, maximumWordsPerBlock)
        var result: [TranscriptRenderBlock] = []

        for (paragraphIndex, paragraph) in paragraphs.enumerated() {
            var first = paragraph.firstWordIndex
            while first <= paragraph.lastWordIndex {
                let last = min(paragraph.lastWordIndex, first + limit - 1)
                result.append(
                    TranscriptRenderBlock(
                        paragraphIndex: paragraphIndex,
                        firstWordIndex: first,
                        lastWordIndex: last,
                        showsParagraphHeader: first == paragraph.firstWordIndex,
                        endsParagraph: last == paragraph.lastWordIndex
                    )
                )
                first = last + 1
            }
        }
        return result
    }

    private static func renderBlockIndexMap(
        wordCount: Int,
        renderBlocks: [TranscriptRenderBlock]
    ) -> [Int] {
        var result = Array(repeating: -1, count: wordCount)
        for (blockIndex, block) in renderBlocks.enumerated() {
            guard block.firstWordIndex <= block.lastWordIndex else { continue }
            for wordIndex in block.firstWordIndex ... block.lastWordIndex where result.indices.contains(wordIndex) {
                result[wordIndex] = blockIndex
            }
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
