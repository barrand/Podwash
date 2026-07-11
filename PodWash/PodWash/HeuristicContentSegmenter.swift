//
//  HeuristicContentSegmenter.swift
//  PodWash
//
//  Slice 18 — `heuristic-cue-v1` (ADR-012 §3.1). Deterministic cue lexicon +
//  light topic-drift over `[TimedWord]`. No NaturalLanguage / ML types.
//

import Foundation

/// Deterministic cue + light topic-drift segmenter (ADR-012 §3.1).
struct HeuristicContentSegmenter: ContentSegmenting {

    var approachIdentifier: String { "heuristic-cue-v1" }

    func segments(in transcript: [TimedWord]) -> [ContentSegment] {
        let tokens = Self.normalizedTokens(from: transcript)
        guard tokens.count >= 3 else { return [] }

        let anchor = Self.onTopicAnchor(from: tokens)
        let hits = Self.findCueHits(in: tokens)
        guard !hits.isEmpty else { return [] }

        let positiveCueSpans = Self.positiveCueSpans(
            tokens: tokens,
            hits: hits,
            anchor: anchor
        )
        guard !positiveCueSpans.isEmpty else { return [] }

        let mergedHits = Self.mergeTokenSpans(positiveCueSpans, tokens: tokens, gapSeconds: Constants.mergeGapSeconds)
        let expanded = mergedHits.map { span in
            Self.expandSpan(span, tokens: tokens)
        }
        let mergedTimes = Self.mergeTimeRanges(expanded, gapSeconds: Constants.mergeGapSeconds)

        return mergedTimes
            .filter { $0.end - $0.start >= Constants.minDurationSeconds }
            .map { ContentSegment(start: $0.start, end: $0.end) }
    }

    // MARK: - Constants (ADR-012 §3.1)

    private enum Constants {
        static let anchorMaxSeconds: Double = 20.0
        static let anchorMaxTokens: Int = 80
        static let windowSeconds: Double = 10.0
        static let windowStepSeconds: Double = 2.5
        static let scoreThreshold: Double = 2.0
        static let driftBoostThreshold: Double = 0.5
        static let driftBoost: Double = 0.5
        static let sponsorWeight: Double = 2.0
        static let tangentWeight: Double = 1.5
        static let minDurationSeconds: Double = 5.0
        static let mergeGapSeconds: Double = 1.5
        static let leadInTokens: Int = 3
        static let trailSeconds: Double = 3.0
        static let maxTokenGapSeconds: Double = 0.55
    }

    /// Longer phrases first so multi-word cues claim tokens before substrings.
    private static let sponsorPhrases: [String] = [
        "link in the description",
        "our friends at",
        "brought to you",
        "sponsored by",
        "use code",
        "ad break",
        "advertisement",
        "check out",
        "sponsored",
        "sponsor",
        "promo",
        "discount",
    ].sorted { $0.count > $1.count }

    private static let tangentPhrases: [String] = [
        "before we continue",
        "speaking of",
        "side note",
        "real quick",
        "tangent",
        "unrelated",
        "anyway",
    ].sorted { $0.count > $1.count }

    private static let stopWords: Set<String> = [
        "a", "an", "the", "and", "or", "but", "if", "in", "on", "of", "to", "for",
        "with", "from", "by", "as", "at", "is", "are", "was", "were", "be", "been",
        "being", "this", "that", "these", "those", "it", "its", "i", "we", "you",
        "he", "she", "they", "them", "their", "our", "your", "my", "me", "us",
        "not", "no", "so", "too", "very", "just", "about", "into", "over", "under",
        "again", "then", "than", "also", "can", "could", "would", "should", "will",
        "may", "might", "must", "do", "does", "did", "done", "have", "has", "had",
        "having",
    ]

    private static let cueLexiconWords: Set<String> = {
        var words = Set<String>()
        for phrase in sponsorPhrases + tangentPhrases {
            for part in phrase.split(separator: " ") {
                words.insert(String(part))
            }
        }
        return words
    }()

    // MARK: - Token model

    private struct Token {
        let word: String
        let start: Double
        let end: Double
    }

    private struct CueHit {
        let startIndex: Int
        let endIndex: Int
        let weight: Double
    }

    private struct TokenSpan {
        var startIndex: Int
        var endIndex: Int
    }

    private struct TimeRange {
        var start: Double
        var end: Double
    }

    // MARK: - Normalize

    private static func normalizedTokens(from transcript: [TimedWord]) -> [Token] {
        transcript.compactMap { word in
            let normalized = normalize(word.word)
            guard !normalized.isEmpty else { return nil }
            return Token(word: normalized, start: word.start, end: word.end)
        }
    }

    private static func normalize(_ raw: String) -> String {
        let lower = raw.lowercased()
        let scalars = lower.unicodeScalars
        var start = scalars.startIndex
        var end = scalars.endIndex
        while start < end, !CharacterSet.alphanumerics.contains(scalars[start]) {
            start = scalars.index(after: start)
        }
        while end > start {
            let prev = scalars.index(before: end)
            if CharacterSet.alphanumerics.contains(scalars[prev]) { break }
            end = prev
        }
        return String(scalars[start..<end])
    }

    // MARK: - Anchor (opening window)

    private static func onTopicAnchor(from tokens: [Token]) -> Set<String> {
        var selected: [Token] = []
        for (index, token) in tokens.enumerated() {
            if index >= Constants.anchorMaxTokens { break }
            if token.start >= Constants.anchorMaxSeconds { break }
            selected.append(token)
        }
        var bag = Set<String>()
        for token in selected {
            guard token.word.count > 2 else { continue }
            guard !stopWords.contains(token.word) else { continue }
            guard !cueLexiconWords.contains(token.word) else { continue }
            bag.insert(token.word)
        }
        return bag
    }

    // MARK: - Cue hits

    private static func findCueHits(in tokens: [Token]) -> [CueHit] {
        let words = tokens.map(\.word)
        var occupied = Array(repeating: false, count: tokens.count)
        var hits: [CueHit] = []

        let phrases: [(String, Double)] =
            sponsorPhrases.map { ($0, Constants.sponsorWeight) }
            + tangentPhrases.map { ($0, Constants.tangentWeight) }

        for (phrase, weight) in phrases {
            let parts = phrase.split(separator: " ").map(String.init)
            let n = parts.count
            guard n > 0, words.count >= n else { continue }
            for i in 0...(words.count - n) {
                if occupied[i..<(i + n)].contains(true) { continue }
                if Array(words[i..<(i + n)]) == parts {
                    for k in i..<(i + n) { occupied[k] = true }
                    hits.append(CueHit(startIndex: i, endIndex: i + n - 1, weight: weight))
                }
            }
        }
        return hits.sorted { $0.startIndex < $1.startIndex }
    }

    // MARK: - Sliding windows → positive cue spans

    private static func positiveCueSpans(
        tokens: [Token],
        hits: [CueHit],
        anchor: Set<String>
    ) -> [TokenSpan] {
        var spans: [TokenSpan] = []
        var windowStart = tokens[0].start
        let episodeEnd = tokens[tokens.count - 1].end

        while windowStart < episodeEnd {
            let windowEnd = windowStart + Constants.windowSeconds
            let indices = tokens.indices.filter { i in
                tokens[i].end > windowStart && tokens[i].start < windowEnd
            }
            if indices.count >= 3 {
                let first = indices.first!
                let last = indices.last!
                var score = 0.0
                var local: [TokenSpan] = []
                for hit in hits where hit.startIndex >= first && hit.endIndex <= last {
                    score += hit.weight
                    local.append(TokenSpan(startIndex: hit.startIndex, endIndex: hit.endIndex))
                }
                if score > 0, !anchor.isEmpty {
                    let content = Set(
                        indices
                            .map { tokens[$0].word }
                            .filter { $0.count > 2 && !stopWords.contains($0) }
                    )
                    if !content.isEmpty {
                        let overlap = Double(content.intersection(anchor).count) / Double(content.count)
                        let drift = 1.0 - overlap
                        if drift > Constants.driftBoostThreshold {
                            score += Constants.driftBoost
                        }
                    }
                }
                if score >= Constants.scoreThreshold {
                    spans.append(contentsOf: local)
                }
            }
            windowStart += Constants.windowStepSeconds
        }

        // Deduplicate identical spans.
        var seen = Set<String>()
        return spans.filter { span in
            let key = "\(span.startIndex)-\(span.endIndex)"
            if seen.contains(key) { return false }
            seen.insert(key)
            return true
        }
        .sorted { $0.startIndex < $1.startIndex }
    }

    // MARK: - Merge / expand

    private static func mergeTokenSpans(
        _ spans: [TokenSpan],
        tokens: [Token],
        gapSeconds: Double
    ) -> [TokenSpan] {
        guard var current = spans.first else { return [] }
        var merged: [TokenSpan] = []
        for span in spans.dropFirst() {
            let gap = tokens[span.startIndex].start - tokens[current.endIndex].end
            if gap > gapSeconds {
                merged.append(current)
                current = span
            } else {
                current.endIndex = max(current.endIndex, span.endIndex)
            }
        }
        merged.append(current)
        return merged
    }

    private static func expandSpan(_ span: TokenSpan, tokens: [Token]) -> TimeRange {
        let leadIn = max(0, span.startIndex - Constants.leadInTokens)
        let cueEnd = tokens[span.endIndex].end
        var hi = span.endIndex
        while hi < tokens.count - 1 {
            let next = tokens[hi + 1]
            if next.start - tokens[hi].end > Constants.maxTokenGapSeconds { break }
            if next.end - cueEnd > Constants.trailSeconds { break }
            // Stop before an explicit return-to-topic cue ("back to …").
            if next.word == "back" { break }
            hi += 1
        }
        return TimeRange(start: tokens[leadIn].start, end: tokens[hi].end)
    }

    private static func mergeTimeRanges(
        _ ranges: [TimeRange],
        gapSeconds: Double
    ) -> [TimeRange] {
        let sorted = ranges.sorted { $0.start < $1.start }
        guard var current = sorted.first else { return [] }
        var merged: [TimeRange] = []
        for range in sorted.dropFirst() {
            if range.start > current.end + gapSeconds {
                merged.append(current)
                current = range
            } else {
                current.end = max(current.end, range.end)
            }
        }
        merged.append(current)
        return merged
    }
}
