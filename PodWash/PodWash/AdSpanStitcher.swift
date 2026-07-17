//
//  AdSpanStitcher.swift
//  PodWash
//
//  topic-llm-v1 — resolve unsure labels + merge consecutive ad windows into pods.
//

import Foundation

enum ChunkAdLabel: String, Equatable, Sendable {
    case ad
    case content
    case mixed
    case unsure

    static func parse(_ raw: String) -> ChunkAdLabel {
        switch raw.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() {
        case "ad": return .ad
        case "mixed": return .mixed
        case "unsure": return .unsure
        default: return .content
        }
    }
}

enum AdSpanStitcher {
    private static let minPodSeconds: Double = 5.0

    /// Resolve `unsure` using neighbor hysteresis (plan table). `mixed` left for caller to refine.
    static func resolveUnsure(
        label: ChunkAdLabel,
        text: String,
        previousResolved: ChunkAdLabel?,
        nextText: String?
    ) -> ChunkAdLabel {
        guard label == .unsure else { return label }
        let prev = previousResolved ?? .content
        let combined = (text + " " + (nextText ?? "")).lowercased()
        let sellish = looksLikeSell(combined)
        let resumeish = looksLikeShowResume(combined)

        switch prev {
        case .ad:
            if resumeish, !sellish { return .content }
            if sellish || looksLikeSell(text.lowercased()) { return .ad }
            if resumeish { return .content }
            return .ad
        case .content, .mixed, .unsure:
            if sellish { return .ad }
            return .content
        }
    }

    /// Merge consecutive ad-labeled spans into ContentSegments; drop pods < 5 s.
    static func mergeAdSpans(
        windows: [(start: Double, end: Double, label: ChunkAdLabel)]
    ) -> [ContentSegment] {
        var pods: [(Double, Double)] = []
        var current: (Double, Double)?
        for w in windows {
            let forced = forceContentIfShowResume(textHint: nil, label: w.label)
            let label = forced
            if label == .ad {
                if var cur = current {
                    cur.1 = w.end
                    current = cur
                } else {
                    current = (w.start, w.end)
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
            .filter { $0.1 - $0.0 >= minPodSeconds }
            .map { ContentSegment(start: $0.0, end: $0.1) }
    }

    /// Overload that can hard-cut on resume using window text.
    static func mergeAdSpans(
        labeled: [(window: TranscriptWindow, label: ChunkAdLabel)]
    ) -> [ContentSegment] {
        var resolved: [(start: Double, end: Double, label: ChunkAdLabel)] = []
        for item in labeled {
            var label = item.label
            if looksLikeShowResume(item.window.text.lowercased()) {
                label = .content
            }
            resolved.append((item.window.start, item.window.end, label))
        }
        return mergeAdSpans(windows: resolved)
    }

    static func looksLikeSell(_ lower: String) -> Bool {
        let needles = [
            ".com", "dot com", " slash ", "visit ", "apply ", "learn more",
            "brought to you", "sponsored", "shop ", "save ", "discount",
            "free shipping", "sign up", "download ", "promo", "coupon",
        ]
        return needles.contains { lower.contains($0) }
    }

    /// High-precision sponsor openers — override model "content" on short live-reads.
    static func looksLikeStrongSponsor(_ lower: String) -> Bool {
        if lower.contains("brought to you") { return true }
        if lower.contains("sponsored by") { return true }
        if lower.contains("this message comes from") { return true }
        if lower.contains("support for") && lower.contains("comes from") { return true }
        return false
    }

    static func looksLikeShowResume(_ lower: String) -> Bool {
        if lower.contains("welcome back") { return true }
        if lower.contains("back to the") { return true }
        if lower.contains("broadcasting from") { return true }
        if lower.contains("i've been") && lower.contains("broadcast") { return true }
        if lower.range(of: #"\bact (one|two|three|1|2|3)\b"#, options: .regularExpression) != nil {
            return true
        }
        if lower.hasPrefix("okay so") || lower.hasPrefix("ok so") { return true }
        // "It's American life" / show reopen — require show-ish tokens (bare "it's" is too noisy).
        if (lower.hasPrefix("it's ") || lower.hasPrefix("its ")),
           !looksLikeSell(lower),
           lower.range(
            of: #"\b(american life|act one|act two|welcome|podcast|show|fan)\b"#,
            options: .regularExpression
           ) != nil
        {
            return true
        }
        return false
    }

    private static func forceContentIfShowResume(textHint: String?, label: ChunkAdLabel) -> ChunkAdLabel {
        guard let textHint else { return label }
        if looksLikeShowResume(textHint.lowercased()) { return .content }
        return label
    }
}
