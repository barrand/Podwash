//
//  HeuristicContentSegmenter.swift
//  PodWash
//
//  heuristic-cue-v6.1 — sentence-scored ad blocks with brand-carry veto +
//  show-open hard exits. Soft interior sentences no longer punch holes in
//  contiguous midrolls (30–120 s).
//

import Foundation

/// Sentence-first ad segmenter (heuristic-cue-v6.1). Deterministic over `[TimedWord]`.
struct HeuristicContentSegmenter: ContentSegmenting {

    var approachIdentifier: String { "heuristic-cue-v6.1" }

    func segments(in transcript: [TimedWord]) -> [ContentSegment] {
        let tokens = Self.normalizedTokens(from: transcript)
        guard tokens.count >= 3 else { return [] }

        let sentences = Self.groupSentences(tokens)
        guard !sentences.isEmpty else { return [] }

        var brandCarry: Set<String> = []
        var scores: [Double] = []
        var openerHits: [Bool] = []
        var closerHits: [Bool] = []
        var resumeHits: [Bool] = []
        var showOpenHits: [Bool] = []
        var brandHits: [Bool] = []
        var postCloserResumeHits: [Bool] = []

        for sentence in sentences {
            let text = Self.joinedBare(sentence)
            let opener = Self.containsFuzzyOpener(text)
            let closer = Self.containsFuzzyCloser(text)
            if opener {
                for name in Self.extractBrandAfterOpener(sentence) {
                    brandCarry.insert(name)
                }
            }
            let mentionsBrand = Self.sentenceMentionsBrand(text, brandCarry: brandCarry)
            let score = Self.scoreSentence(
                sentence,
                text: text,
                brandCarry: brandCarry,
                hasOpener: opener,
                hasCloser: closer,
                mentionsBrand: mentionsBrand
            )
            scores.append(score)
            openerHits.append(opener)
            closerHits.append(closer)
            brandHits.append(mentionsBrand)
            showOpenHits.append(Self.containsShowOpen(text))
            postCloserResumeHits.append(Self.isPostCloserShowResume(text) && !opener)
            let firstBare = sentence.tokens.first.map(\.bare) ?? ""
            // "now" is common inside ads ("Now, this is your time…") — not a resume.
            resumeHits.append(
                (Self.resumeStarters.contains(firstBare) || text.contains("back to"))
                    && !opener && !closer
            )
        }

        let states = Self.smoothStates(
            scores: scores,
            openers: openerHits,
            closers: closerHits,
            resumes: resumeHits,
            showOpens: showOpenHits,
            brandHits: brandHits,
            postCloserResumes: postCloserResumeHits
        )
        let pods = Self.mergeNearbyPods(
            Self.podsFromStates(sentences: sentences, states: states),
            gapSeconds: Constants.mergeGapSeconds
        )
        return pods
            .filter { $0.end - $0.start >= Constants.minDurationSeconds }
            .map { ContentSegment(start: $0.start, end: $0.end) }
    }

    // MARK: - Constants

    private enum Constants {
        static let gapBoundarySeconds: Double = 0.60
        static let maxSentenceSeconds: Double = 18.0
        static let enterScore: Double = 4.0
        static let stayScore: Double = 1.5
        /// Soft sentences after last brand mention before forcing exit (pre-closer).
        static let brandSilenceExit: Int = 4
        /// After a closer, the next non-brand sentence ends the block (0 = exit on first soft).
        static let postCloserExitRun: Int = 0
        static let minDurationSeconds: Double = 5.0
        static let brandBoost: Double = 3.0
        static let openerBoost: Double = 6.0
        static let closerBoost: Double = 4.0
        static let mergeGapSeconds: Double = 3.0
    }

    /// Precision-first openers (fuzzy: come/comes, optional leading dash noise).
    private static let openerPhrases: [String] = [
        "this episode is sponsored by",
        "this message comes from",
        "this message come from",
        "following message comes from",
        "following message come from",
        "the following message comes from",
        "the following message come from",
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
        "support for this podcast",
        "support for this american life",
    ].sorted { $0.count > $1.count }

    private static let closerPhrases: [String] = [
        "learn more at",
        "discover how at",
        "start building at",
        "apply in minutes",
        "apply today",
        "member fdic",
        "equal housing",
        "terms apply",
        "see details",
        "for details",
        "whats in your wallet",
        "what's in your wallet",
    ]

    private static let ctaWords: Set<String> = [
        "visit", "go", "learn", "check", "sign", "try", "book",
        "apply", "play", "start", "claim", "discover", "save", "shop",
    ]

    private static let priceNeedles: [String] = [
        "free", "percent", "discount", "off", "promo", "coupon", "code",
    ]

    /// Host handoff words — excludes "now" (ubiquitous inside ad copy).
    private static let resumeStarters: Set<String> = [
        "back", "anyway", "meanwhile", "okay", "ok", "alright",
    ]

    private static let brandStop: Set<String> = [
        "the", "a", "an", "our", "your", "this", "that", "and", "or",
        "for", "from", "with", "by", "to", "of", "in", "on", "at",
        "message", "comes", "come", "sponsored", "sponsor", "podcast",
        "episode", "show", "following", "support",
    ]

    // MARK: - Models

    private struct Token {
        let word: String
        let bare: String
        let start: Double
        let end: Double
    }

    private struct Sentence {
        let tokens: [Token]
        var start: Double { tokens.first!.start }
        var end: Double { tokens.last!.end }
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
            return Token(
                word: normalized,
                bare: bareWord(normalized),
                start: word.start,
                end: word.end
            )
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
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.hasSuffix(".") || trimmed.hasSuffix("?") || trimmed.hasSuffix("!") {
            return String(scalars[start..<end]) + String(trimmed.last!)
        }
        return String(scalars[start..<end])
    }

    private static func bareWord(_ word: String) -> String {
        word.lowercased().trimmingCharacters(in: CharacterSet.alphanumerics.inverted)
    }

    private static func endsSentence(_ word: String) -> Bool {
        word.hasSuffix(".") || word.hasSuffix("?") || word.hasSuffix("!")
    }

    private static func joinedBare(_ sentence: Sentence) -> String {
        sentence.tokens.map(\.bare).filter { !$0.isEmpty }.joined(separator: " ")
    }

    // MARK: - Sentences

    private static func groupSentences(_ tokens: [Token]) -> [Sentence] {
        var sentences: [Sentence] = []
        var current: [Token] = []
        for i in 0..<tokens.count {
            current.append(tokens[i])
            let gap: Double
            if i + 1 < tokens.count {
                gap = tokens[i + 1].start - tokens[i].end
            } else {
                gap = Constants.gapBoundarySeconds
            }
            let duration = (current.last!.end - current.first!.start)
            let cut =
                endsSentence(tokens[i].word)
                || gap >= Constants.gapBoundarySeconds
                || duration >= Constants.maxSentenceSeconds
                || i == tokens.count - 1
            if cut, !current.isEmpty {
                sentences.append(Sentence(tokens: current))
                current = []
            }
        }
        return sentences
    }

    // MARK: - Openers / closers / brand / show-open

    private static func containsFuzzyOpener(_ text: String) -> Bool {
        if openerPhrases.contains(where: { text.contains($0) }) { return true }
        if text.range(of: #"support for (?:[\w']+\s+){0,6}comes? from"#, options: .regularExpression) != nil {
            return true
        }
        return false
    }

    private static func containsFuzzyCloser(_ text: String) -> Bool {
        if closerPhrases.contains(where: { text.contains($0) }) { return true }
        if text.contains(".com") || text.contains(".org") || text.contains(".edu")
            || text.contains(".ai") || text.contains("dot com") || text.contains(" slash ")
        {
            return true
        }
        return false
    }

    /// Host / act / station open — hard exit from an ad block (general, not show-titled).
    private static func containsShowOpen(_ text: String) -> Bool {
        if text.range(of: #"\bact (one|two|three|four|1|2|3|4)\b"#, options: .regularExpression) != nil {
            return true
        }
        if text.range(of: #"today'?s (program|show|episode)\b"#, options: .regularExpression) != nil {
            return true
        }
        // "From WBEZ Chicago … I'm Ira Glass" / "From … I'm Host"
        if text.hasPrefix("from ") || text.contains(" from ") {
            if text.range(of: #"\bi'?m \w+"#, options: .regularExpression) != nil {
                return true
            }
        }
        if text.range(of: #"\bi'?m [a-z]+ [a-z]+\b"#, options: .regularExpression) != nil
            && (text.contains("chicago") || text.contains("radio") || text.contains("public"))
        {
            return true
        }
        return false
    }

    /// Soft post-closer show resume ("It's [Show]…") — only applied after a closer.
    private static func isPostCloserShowResume(_ text: String) -> Bool {
        let prefixes = ["its ", "it's ", "it s ", "it\u{2019}s "]
        if prefixes.contains(where: { text.hasPrefix($0) }) {
            return true
        }
        if text.contains("back to") {
            return true
        }
        return false
    }

    private static func sentenceMentionsBrand(_ text: String, brandCarry: Set<String>) -> Bool {
        for brand in brandCarry where brand.count >= 3 && text.contains(brand) {
            return true
        }
        return false
    }

    private static func extractBrandAfterOpener(_ sentence: Sentence) -> [String] {
        let bares = sentence.tokens.map(\.bare).filter { !$0.isEmpty }
        let joined = bares.joined(separator: " ")
        var brands: [String] = []

        let markers = ["comes from", "come from", "sponsored by", "brought to you by"]
        for marker in markers {
            guard let range = joined.range(of: marker) else { continue }
            let after = String(joined[range.upperBound...])
                .trimmingCharacters(in: .whitespaces)
            let parts = after.split(separator: " ").prefix(4).map(String.init)
            var collected: [String] = []
            for p in parts {
                if brandStop.contains(p) { break }
                if p.count < 2 { continue }
                collected.append(p)
                if collected.count >= 3 { break }
            }
            if let first = collected.first {
                brands.append(first)
            }
            if collected.count >= 2 {
                brands.append(collected.prefix(2).joined(separator: " "))
            }
        }

        for t in sentence.tokens {
            let w = t.word.lowercased()
            if w.contains(".com") || w.contains(".org") || w.contains(".me") || w.contains(".ai")
                || w.contains(".edu")
            {
                let host = bareWord(w.replacingOccurrences(of: ".", with: " "))
                if host.count >= 3 { brands.append(host) }
            }
        }
        return brands
    }

    private static func scoreSentence(
        _ sentence: Sentence,
        text: String,
        brandCarry: Set<String>,
        hasOpener: Bool,
        hasCloser: Bool,
        mentionsBrand: Bool
    ) -> Double {
        var score = 0.0
        if hasOpener { score += Constants.openerBoost }

        let words = sentence.tokens.map(\.bare).filter { !$0.isEmpty }
        let n = max(Double(words.count), 1)

        let you = Double(words.filter { $0 == "you" || $0 == "your" }.count)
        score += min(3.0, you / n * 20)

        let cta = Double(words.filter { ctaWords.contains($0) }.count)
        score += min(3.0, cta * 1.2)

        for needle in priceNeedles where text.contains(needle) {
            score += 1.0
        }

        var stayBoost = 0.0
        if hasCloser { stayBoost += Constants.closerBoost }
        if text.contains(".com") || text.contains("dot com") || text.contains("slash") {
            stayBoost += 2.5
        }
        if mentionsBrand { stayBoost += Constants.brandBoost }
        if text.contains("?") && you >= 1 {
            stayBoost += 1.5
        }

        if hasOpener || !brandCarry.isEmpty || score >= Constants.enterScore * 0.6 {
            score += stayBoost
        }

        return score
    }

    // MARK: - Hysteresis (block stay)

    private static func smoothStates(
        scores: [Double],
        openers: [Bool],
        closers: [Bool],
        resumes: [Bool],
        showOpens: [Bool],
        brandHits: [Bool],
        postCloserResumes: [Bool]
    ) -> [Bool] {
        var inAd = false
        var sawCloser = false
        var brandSilence = 0
        var states = Array(repeating: false, count: scores.count)

        for i in 0..<scores.count {
            if !inAd {
                // Show-open lines are content — unless they are also sponsor openers
                // ("Support for today's show comes from …").
                if showOpens[i] && !openers[i] {
                    continue
                }
                // Enter only on opener (or opener+score). Score-alone
                // (second-person dens) caused story false positives.
                if openers[i] {
                    inAd = true
                    brandSilence = brandHits[i] ? 0 : 1
                    sawCloser = closers[i]
                    states[i] = true
                }
                continue
            }

            // Hard exit: show / act / host open.
            if showOpens[i] && !openers[i] {
                inAd = false
                sawCloser = false
                brandSilence = 0
                states[i] = false
                continue
            }

            if brandHits[i] {
                brandSilence = 0
            } else {
                brandSilence += 1
            }

            if closers[i] {
                sawCloser = true
                // Closer sentence is always part of the ad (URL / FDIC / CTA).
                states[i] = true
                continue
            }

            // Post-closer "It's [show]…" / "back to…" — hard content.
            if sawCloser, postCloserResumes[i], !brandHits[i] {
                inAd = false
                sawCloser = false
                brandSilence = 0
                states[i] = false
                continue
            }

            // Brand-carry: stay while sponsor name is recent.
            if brandHits[i] || openers[i] {
                states[i] = true
                continue
            }

            // After a closer, do not let second-person / CTA scores pull story
            // sentences back into the block — exit on first soft non-brand.
            if sawCloser {
                let silenceLimit = Constants.postCloserExitRun
                if brandSilence > silenceLimit {
                    inAd = false
                    sawCloser = false
                    brandSilence = 0
                    states[i] = false
                } else {
                    states[i] = true
                }
                continue
            }

            // High score without brand only keeps the block briefly (pre-closer).
            if scores[i] >= Constants.stayScore, brandSilence <= 1 {
                states[i] = true
                continue
            }

            // Resume handoff — exit once brand has gone quiet (closer optional).
            if resumes[i], brandSilence >= 1, scores[i] < Constants.enterScore {
                inAd = false
                sawCloser = false
                brandSilence = 0
                states[i] = false
                continue
            }

            // Soft interior: stay while brand was recent; else leave the block.
            if brandSilence > Constants.brandSilenceExit {
                inAd = false
                sawCloser = false
                brandSilence = 0
                states[i] = false
            } else {
                states[i] = true
            }
        }
        return states
    }

    private static func podsFromStates(
        sentences: [Sentence],
        states: [Bool]
    ) -> [TimeRange] {
        var pods: [TimeRange] = []
        var current: TimeRange?
        for i in 0..<sentences.count {
            if states[i] {
                if var cur = current {
                    cur.end = sentences[i].end
                    current = cur
                } else {
                    current = TimeRange(start: sentences[i].start, end: sentences[i].end)
                }
            } else if let cur = current {
                pods.append(cur)
                current = nil
            }
        }
        if let cur = current {
            pods.append(cur)
        }
        return pods
    }

    private static func mergeNearbyPods(
        _ pods: [TimeRange],
        gapSeconds: Double
    ) -> [TimeRange] {
        guard var current = pods.first else { return [] }
        var out: [TimeRange] = []
        for pod in pods.dropFirst() {
            if pod.start <= current.end + gapSeconds {
                current.end = max(current.end, pod.end)
            } else {
                out.append(current)
                current = pod
            }
        }
        out.append(current)
        return out
    }
}
