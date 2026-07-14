//
//  HeuristicContentSegmenter.swift
//  PodWash
//
//  span-grow-v1 / heuristic-cue-v5 — precision-first ad detection:
//  anchor openers → grow through ad copy → snap to silence gaps → merge pods.
//

import Foundation

/// Precision-first ad segmenter (span-grow-v1). Deterministic over `[TimedWord]`.
struct HeuristicContentSegmenter: ContentSegmenting {

    var approachIdentifier: String { "heuristic-cue-v5" }

    func segments(in transcript: [TimedWord]) -> [ContentSegment] {
        let tokens = Self.normalizedTokens(from: transcript)
        guard tokens.count >= 3 else { return [] }

        let features = Self.blockFeatures(tokens)
        let anchors = Self.findAnchors(in: tokens)
        var grown: [TimeRange] = anchors.map { Self.growFromAnchor($0, tokens: tokens, features: features) }

        let episodeEnd = tokens[tokens.count - 1].end
        for dens in Self.densityWindows(tokens: tokens, features: features) {
            let nearOpenClose = dens.start < 180.0 || dens.start > episodeEnd - 180.0
            let nearAnchor = grown.contains {
                abs(dens.start - $0.start) < 30
                    || abs(dens.end - $0.end) < 30
                    || dens.start <= $0.end + 5 && dens.end >= $0.start - 5
            }
            if nearOpenClose || nearAnchor {
                grown.append(dens)
            }
        }

        let gaps = Self.silenceGaps(tokens)
        let snapped = Self.applyGapSnapping(grown, gaps: gaps)
        let merged = Self.mergeTimeRanges(snapped, gapSeconds: Constants.mergeGapSeconds)
        return merged
            .filter { $0.end - $0.start >= Constants.minDurationSeconds }
            .map { ContentSegment(start: $0.start, end: $0.end) }
    }

    // MARK: - Constants

    private enum Constants {
        static let blockSeconds: Double = 5.0
        static let growForwardMaxSeconds: Double = 120.0
        static let growBackwardMaxSeconds: Double = 20.0
        static let closerBackwardMaxSeconds: Double = 55.0
        static let gapSnapSeconds: Double = 1.0
        static let gapSnapWindow: Double = 4.0
        static let mergeGapSeconds: Double = 4.0
        static let minDurationSeconds: Double = 5.0
        static let anchorlessMinSeconds: Double = 12.0
        static let densityMaxSeconds: Double = 90.0
        static let padInsideGap: Double = 0.25
        static let minAnchorGrowSeconds: Double = 8.0
        static let stopGapSeconds: Double = 1.2
        static let softStopGapSeconds: Double = 0.75
        static let postCloserGapSeconds: Double = 0.55
    }

    /// Precision-first openers only — no weak single-word cues.
    private static let anchorPhrases: [String] = [
        "this episode is sponsored by",
        "this message comes from",
        "following message come from",
        "following message comes from",
        "segment was brought to you by",
        "this episode is brought to you by",
        "brought to you by",
        "delivered to public radio",
        "equivalent to public radio",
        "become a life partner",
        "sign up for our plus feed",
        "thank you to todays sponsors",
        "thank you to today s sponsors",
        "help support the show",
        "learn more at",
        "discover how at",
        "start building at",
        "apply today at",
        "apply in minutes at",
        "built to back small businesses",
        "play spinquest",
        "support for", // handled with "comes from" scan below
    ].sorted { $0.count > $1.count }

    private static let closerAnchorSubstrings: [String] = [
        "learn more at",
        "discover how at",
        "start building at",
        "apply in minutes",
        "apply today",
    ]

    private static let adForwardCues: [String] = [
        ".com", ".org", ".edu", ".ai", "discount", "promo", "use code",
        "learn more", "sign up", "free shipping", "percent", "sponsor",
        "sponsored", "brought to you", "offer", "coupon", "subscribe",
        "visit", "apply",
    ]

    private static let resumeStarters: Set<String> = [
        "back", "anyway", "meanwhile", "okay", "ok", "alright", "now",
    ]

    // MARK: - Models

    private struct Token {
        let word: String
        let start: Double
        let end: Double
    }

    private struct TokenSpan {
        var startIndex: Int
        var endIndex: Int
    }

    private struct TimeRange {
        var start: Double
        var end: Double
    }

    private struct BlockFeat {
        var url: Double
        var you: Double
        var cta: Double
        var price: Double
        var score: Double
        var n: Double
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
        // Keep punctuation that marks sentence ends / URLs for gap logic.
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.hasSuffix(".") || trimmed.hasSuffix("?") || trimmed.hasSuffix("!") {
            return String(scalars[start..<end]) + String(trimmed.last!)
        }
        return String(scalars[start..<end])
    }

    private static func bareWord(_ word: String) -> String {
        word.lowercased().trimmingCharacters(in: CharacterSet.alphanumerics.inverted)
    }

    // MARK: - Anchors

    private static func findAnchors(in tokens: [Token]) -> [TokenSpan] {
        let words = tokens.map { bareWord($0.word) }
        var occupied = Array(repeating: false, count: tokens.count)
        var hits: [TokenSpan] = []

        // Special: "support for … comes from" with up to 6 tokens between.
        for i in 0..<words.count {
            guard words[i] == "support", i + 1 < words.count, words[i + 1] == "for" else { continue }
            for j in (i + 2)..<min(i + 9, words.count - 1) {
                if words[j] == "comes", j + 1 < words.count, words[j + 1] == "from" {
                    let range = i...(j + 1)
                    if range.contains(where: { occupied[$0] }) { break }
                    for k in range { occupied[k] = true }
                    hits.append(TokenSpan(startIndex: i, endIndex: j + 1))
                    break
                }
            }
        }

        for phrase in anchorPhrases where phrase != "support for" {
            let parts = phrase.split(separator: " ").map(String.init)
            let n = parts.count
            guard n > 0, words.count >= n else { continue }
            for i in 0...(words.count - n) {
                if occupied[i..<(i + n)].contains(true) { continue }
                if Array(words[i..<(i + n)]) == parts {
                    for k in i..<(i + n) { occupied[k] = true }
                    hits.append(TokenSpan(startIndex: i, endIndex: i + n - 1))
                }
            }
        }
        let sorted = hits.sorted { $0.startIndex < $1.startIndex }

        // Drop closer-only seeds inside an opener's forward window — they
        // otherwise grow backward through story and merge pods.
        var filtered: [TokenSpan] = []
        var lastOpenerStart = -1e9
        for span in sorted {
            let text = tokens[span.startIndex...span.endIndex]
                .map { bareWord($0.word) }
                .joined(separator: " ")
            let closerOnly = closerAnchorSubstrings.contains { text.contains($0) }
            if closerOnly {
                if tokens[span.startIndex].start - lastOpenerStart < 90.0 {
                    continue
                }
            } else {
                lastOpenerStart = tokens[span.startIndex].start
            }
            filtered.append(span)
        }
        return filtered
    }

    // MARK: - Block features

    private static func blockId(_ t: Double) -> Int {
        Int(t / Constants.blockSeconds)
    }

    private static func blockFeatures(_ tokens: [Token]) -> [Int: BlockFeat] {
        var buckets: [Int: [String]] = [:]
        for t in tokens {
            buckets[blockId(t.start), default: []].append(t.word.lowercased())
        }
        var out: [Int: BlockFeat] = [:]
        for (bid, words) in buckets {
            let n = max(Double(words.count), 1)
            let text = words.joined(separator: " ")
            let url = Double(countMatches(text, [
                ".com", ".org", ".edu", ".ai", "slash", "dot com",
            ]))
            let you = Double(countWholeWords(text, ["you", "your"]))
            let cta = Double(countWholeWords(text, [
                "visit", "go", "learn", "check", "sign", "try", "book",
                "apply", "play", "start", "claim", "discover",
            ]))
            let price = Double(countMatches(text, ["$", "free", "percent", "%", "discount", "bucks"]))
            out[bid] = BlockFeat(
                url: url / n * 100,
                you: you / n * 100,
                cta: cta / n * 100,
                price: price / n * 100,
                score: (url * 4 + cta * 3 + price * 2 + you * 0.5) / n * 100,
                n: n
            )
        }
        return out
    }

    private static func countMatches(_ text: String, _ needles: [String]) -> Int {
        needles.reduce(0) { $0 + text.components(separatedBy: $1).count - 1 }
    }

    private static func countWholeWords(_ text: String, _ words: [String]) -> Int {
        let parts = text.split(whereSeparator: { !$0.isLetter && !$0.isNumber }).map(String.init)
        let set = Set(words)
        return parts.filter { set.contains($0) }.count
    }

    private static func isAdLike(_ feat: BlockFeat, strict: Bool = false) -> Bool {
        if feat.url >= 1.0 || feat.cta >= 1.5 { return true }
        if feat.score >= (strict ? 8.0 : 4.0) { return true }
        if feat.you >= 5.0 && feat.score >= 3.0 { return true }
        return false
    }

    private static func hasCloser(_ feat: BlockFeat?) -> Bool {
        guard let feat else { return false }
        return feat.url > 0 || feat.cta > 0
    }

    private static func tokenLooksLikeURL(_ word: String) -> Bool {
        let w = word.lowercased()
        return w.contains(".com") || w.contains(".org") || w.contains(".edu")
            || w.contains(".ai") || bareWord(w) == "slash"
    }

    private static func endsSentence(_ word: String) -> Bool {
        word.hasSuffix(".") || word.hasSuffix("?") || word.hasSuffix("!")
    }

    private static func forwardLooksLikeAd(_ tokens: [Token], startIndex: Int, window: Int = 14) -> Bool {
        let end = min(tokens.count, startIndex + window)
        guard startIndex < end else { return false }
        let text = tokens[startIndex..<end].map { $0.word.lowercased() }.joined(separator: " ")
        return adForwardCues.contains { text.contains($0) }
    }

    // MARK: - Grow

    private static func growFromAnchor(
        _ span: TokenSpan,
        tokens: [Token],
        features: [Int: BlockFeat]
    ) -> TimeRange {
        var hi = span.endIndex
        var seenCloser = false
        var closerIdx = span.endIndex
        let anchorText = tokens[span.startIndex...span.endIndex]
            .map { bareWord($0.word) }
            .joined(separator: " ")
        let isCloserAnchor = closerAnchorSubstrings.contains { anchorText.contains($0) }

        while hi < tokens.count - 1 {
            let nxt = hi + 1
            let duration = tokens[nxt].end - tokens[span.startIndex].start
            if duration > Constants.growForwardMaxSeconds { break }
            let gap = tokens[nxt].start - tokens[hi].end
            let feat = features[blockId(tokens[nxt].start)]

            if gap >= Constants.stopGapSeconds && duration >= Constants.minAnchorGrowSeconds {
                break
            }
            if gap >= Constants.softStopGapSeconds
                && duration >= Constants.minAnchorGrowSeconds
                && endsSentence(tokens[hi].word)
            {
                let nextFeat = features[blockId(tokens[nxt].start)]
                let resume = nextFeat == nil
                    || (!isAdLike(nextFeat!) && !hasCloser(nextFeat) && nextFeat!.you < 3.0)
                if seenCloser || (resume && !isCloserAnchor) {
                    break
                }
            }
            if gap >= Constants.softStopGapSeconds
                && duration >= 40.0
                && endsSentence(tokens[hi].word)
            {
                break
            }
            if duration >= Constants.minAnchorGrowSeconds
                && endsSentence(tokens[hi].word)
                && gap >= Constants.softStopGapSeconds
                && !isCloserAnchor
                && !seenCloser
                && resumeStarters.contains(bareWord(tokens[nxt].word))
                && !forwardLooksLikeAd(tokens, startIndex: nxt)
            {
                break
            }

            if tokenLooksLikeURL(tokens[nxt].word)
                && tokens[nxt].start >= tokens[span.endIndex].end
            {
                seenCloser = true
                closerIdx = nxt
                hi = nxt
                continue
            }

            if seenCloser {
                if gap >= Constants.postCloserGapSeconds { break }
                if feat == nil || !(isAdLike(feat!) || tokenLooksLikeURL(tokens[nxt].word)) {
                    break
                }
                if tokens[nxt].end - tokens[closerIdx].end > 10.0 { break }
                hi = nxt
                continue
            }
            hi = nxt
        }

        var lo = span.startIndex
        let backLimit = isCloserAnchor
            ? Constants.closerBackwardMaxSeconds
            : Constants.growBackwardMaxSeconds
        let minStart = max(0.0, tokens[span.startIndex].start - backLimit)
        while lo > 0 {
            let prev = lo - 1
            if tokens[prev].start < minStart { break }
            let gap = tokens[lo].start - tokens[prev].end
            if gap >= Constants.stopGapSeconds { break }
            let feat = features[blockId(tokens[prev].start)]
            if isCloserAnchor {
                guard let feat else { break }
                if isAdLike(feat) || feat.you >= 3.5 || hasCloser(feat) {
                    lo = prev
                    continue
                }
                // Dense continuous speech inside a DAI / native read.
                if feat.n >= 8 && gap < Constants.softStopGapSeconds {
                    lo = prev
                    continue
                }
                break
            }
            if gap >= Constants.softStopGapSeconds && endsSentence(tokens[prev].word) {
                break
            }
            guard let feat, isAdLike(feat) || hasCloser(feat) else { break }
            lo = prev
        }
        return TimeRange(start: tokens[lo].start, end: tokens[hi].end)
    }

    // MARK: - Density

    private static func densityWindows(
        tokens: [Token],
        features: [Int: BlockFeat]
    ) -> [TimeRange] {
        let bids = features.keys.sorted()
        guard !bids.isEmpty else { return [] }
        var spans: [TimeRange] = []
        var i = 0
        while i < bids.count {
            let f = features[bids[i]]!
            if f.url < 1.5 {
                i += 1
                continue
            }
            var j = i
            while j + 1 < bids.count && bids[j + 1] == bids[j] + 1 {
                let nf = features[bids[j + 1]]!
                if isAdLike(nf) || hasCloser(nf) || nf.url > 0 {
                    j += 1
                } else {
                    break
                }
            }
            var back = i
            while back > 0 && bids[back - 1] == bids[back] - 1 {
                let pf = features[bids[back - 1]]!
                if isAdLike(pf) || pf.you >= 5.0 || hasCloser(pf) {
                    back -= 1
                } else {
                    break
                }
            }
            while Double(bids[i] - bids[back]) * Constants.blockSeconds > 60 {
                back += 1
            }
            var start = Double(bids[back]) * Constants.blockSeconds
            var end = Double(bids[j] + 1) * Constants.blockSeconds
            if end - start > Constants.densityMaxSeconds {
                end = start + Constants.densityMaxSeconds
            }
            if end - start >= Constants.anchorlessMinSeconds {
                let tokStart = tokens.first(where: { $0.end > start })?.start ?? start
                let tokEnd = tokens.last(where: { $0.start < end })?.end ?? end
                spans.append(TimeRange(start: tokStart, end: tokEnd))
            }
            i = j + 1
        }
        return spans
    }

    // MARK: - Gaps / merge

    private static func silenceGaps(_ tokens: [Token]) -> [(Double, Double)] {
        var gaps: [(Double, Double)] = []
        for i in 1..<tokens.count {
            let gap = tokens[i].start - tokens[i - 1].end
            if gap >= Constants.gapSnapSeconds {
                gaps.append((tokens[i - 1].end, tokens[i].start))
            }
        }
        return gaps
    }

    private static func snapToGap(
        _ t: Double,
        gaps: [(Double, Double)],
        window: Double = Constants.gapSnapWindow
    ) -> Double {
        var best = t
        var bestDist = window + 1
        for (gs, ge) in gaps {
            let mid = (gs + ge) / 2
            let edges = [
                gs + Constants.padInsideGap,
                ge - Constants.padInsideGap,
                mid,
            ]
            for edge in edges {
                let d = abs(edge - t)
                if d < bestDist && d <= window {
                    bestDist = d
                    best = edge
                }
            }
        }
        return best
    }

    private static func applyGapSnapping(
        _ segs: [TimeRange],
        gaps: [(Double, Double)]
    ) -> [TimeRange] {
        segs.map { s in
            var start = snapToGap(s.start, gaps: gaps)
            var end = snapToGap(s.end, gaps: gaps)
            if end <= start {
                start = s.start
                end = s.end
            }
            if abs(start - s.start) > Constants.gapSnapWindow { start = s.start }
            if abs(end - s.end) > Constants.gapSnapWindow { end = s.end }
            return TimeRange(start: start, end: end)
        }
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
