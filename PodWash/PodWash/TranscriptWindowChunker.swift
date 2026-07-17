//
//  TranscriptWindowChunker.swift
//  PodWash
//
//  topic-llm-v1 — pack TimedWords into ~20 s sentence windows for LLM labeling.
//

import Foundation

/// One timed window of transcript text for ad/content labeling.
nonisolated struct TranscriptWindow: Equatable, Sendable {
    let id: Int
    let start: Double
    let end: Double
    let text: String
    /// Underlying timed words (for mixed → sentence split).
    let words: [TimedWord]
}

/// Deterministic sentence → ~20 s window packer (no silence requirement).
enum TranscriptWindowChunker {
    private static let gapBoundarySeconds: Double = 0.60
    private static let targetWindowSeconds: Double = 20.0
    private static let minWindowSeconds: Double = 12.0
    private static let maxWindowSeconds: Double = 28.0
    private static let maxWordsInText: Int = 100

    static func windows(from transcript: [TimedWord]) -> [TranscriptWindow] {
        let sentences = groupSentences(transcript)
        guard !sentences.isEmpty else { return [] }

        var out: [TranscriptWindow] = []
        var bucket: [[TimedWord]] = []
        var bucketStart: Double?
        var nextID = 1

        func flush() {
            guard let start = bucketStart, !bucket.isEmpty else { return }
            let flat = bucket.flatMap { $0 }
            guard let end = flat.last?.end else { return }
            let text = renderText(flat)
            out.append(TranscriptWindow(id: nextID, start: start, end: end, text: text, words: flat))
            nextID += 1
            bucket = []
            bucketStart = nil
        }

        for sentence in sentences {
            guard let sFirst = sentence.first, let sLast = sentence.last else { continue }
            let sentenceDur = sLast.end - sFirst.start
            if bucket.isEmpty {
                bucket = [sentence]
                bucketStart = sFirst.start
                if sentenceDur >= maxWindowSeconds {
                    flush()
                }
                continue
            }
            let proposedEnd = sLast.end
            let proposedDur = proposedEnd - (bucketStart ?? sFirst.start)
            if proposedDur <= maxWindowSeconds {
                bucket.append(sentence)
                if proposedDur >= targetWindowSeconds, proposedDur >= minWindowSeconds {
                    flush()
                }
            } else if !bucket.isEmpty {
                flush()
                bucket = [sentence]
                bucketStart = sFirst.start
                if sentenceDur >= maxWindowSeconds {
                    flush()
                }
            }
        }
        flush()
        return out
    }

    /// Split a window into sentence-sized subwindows (mixed refinement).
    static func sentenceWindows(from window: TranscriptWindow, startingID: Int) -> [TranscriptWindow] {
        let sentences = groupSentences(window.words)
        var out: [TranscriptWindow] = []
        var id = startingID
        for sentence in sentences {
            guard let first = sentence.first, let last = sentence.last else { continue }
            out.append(
                TranscriptWindow(
                    id: id,
                    start: first.start,
                    end: last.end,
                    text: renderText(sentence),
                    words: sentence
                )
            )
            id += 1
        }
        return out
    }

    // MARK: - Sentences

    private static func groupSentences(_ tokens: [TimedWord]) -> [[TimedWord]] {
        var sentences: [[TimedWord]] = []
        var current: [TimedWord] = []
        for i in 0..<tokens.count {
            current.append(tokens[i])
            let gap: Double
            if i + 1 < tokens.count {
                gap = tokens[i + 1].start - tokens[i].end
            } else {
                gap = gapBoundarySeconds
            }
            let cut =
                endsSentence(tokens[i].word)
                || gap >= gapBoundarySeconds
                || i == tokens.count - 1
            if cut, !current.isEmpty {
                sentences.append(current)
                current = []
            }
        }
        return sentences
    }

    private static func endsSentence(_ word: String) -> Bool {
        word.hasSuffix(".") || word.hasSuffix("?") || word.hasSuffix("!")
    }

    private static func renderText(_ words: [TimedWord]) -> String {
        let joined = words.map(\.word).joined(separator: " ")
        if words.count <= maxWordsInText { return joined }
        let head = words.prefix(40).map(\.word).joined(separator: " ")
        let tail = words.suffix(40).map(\.word).joined(separator: " ")
        return head + " … " + tail
    }
}
