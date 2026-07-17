//
//  TopicLLMPrompts.swift
//  PodWash
//
//  topic-llm-v1 — frozen prompt strings for TopicCard + chunk labeling.
//

import Foundation

enum TopicLLMPrompts {
    static let approachIdentifier = "topic-llm-v1"

    static let topicCardInstructions = """
        You write a TOPIC CARD used to judge ads vs content in a podcast transcript.

        Given show name, show description, episode title, and episode description, output 3–5 short lines:

        Line 1: SHOW DOMAIN — the show’s usual subject area in a few words (audience, genre).
        Line 2–3: EPISODE HOOKS — the main topics suggested by the title/description (bullet-like phrases). Say "general episode / variety" if the description is vague or multi-topic.
        Line 4: SCOPE — one sentence: "In-domain host talk, interviews, and digressions are content even when the conversation jumps around."
        Line 5 (optional): OUT OF SCOPE — kinds of material that are still ads here (sponsor reads, commercials, network promos), even if local to the audience.

        Ignore sponsor names and subscribe CTAs in the RSS text when writing DOMAIN/HOOKS.
        Do not invent a single narrow plot if the episode is a roundup or open talk show.
        """

    static let chunkLabelInstructions = """
        You label podcast transcript chunks as "ad", "content", "mixed", or "unsure" for a skip-ads feature.

        You are given:
        - TOPIC CARD: show domain + episode hooks (see card)
        - CHUNKS: timed transcript excerpts (id, startSec, endSec, text) with neighbor context

        Mark "ad" if the chunk is almost entirely:
        - A commercial, sponsor read, underwriting credit, or network promo
        - Marketing copy (offer, discount, visit/apply/shop, brand + URL)
        - Host live-read for a sponsor, even if local to the audience

        Mark "content" if the chunk is almost entirely:
        - In-domain host talk, interview, news, or digressions
        - Show open/close about the episode (not a paid spot)
        - Welcome-back / act titles / station IDs without a sponsor pitch

        Mark "mixed" if the chunk clearly contains BOTH a sponsor/commercial stretch AND real show content
        (e.g. end of an ad then “welcome back”, or live-read then interview). Do not force a majority guess.

        Mark "unsure" if you cannot tell. Do not guess.

        Rules:
        - Use SHOW DOMAIN as the main topic signal; EPISODE HOOKS are hints only.
        - Off-domain + marketing → ad. In-domain + marketing (local live-read) → ad.
        - In-domain conversation without a sell → content, even if not listed in hooks.
        - Cold-open ads with no “sponsored by” are still ads.
        - Do not label on URL alone.
        - Use NEIGHBOR CONTEXT (prev label + short prev/next text) to stay consistent with an
          ongoing ad or ongoing content — but do not override a clear opposite signal in this chunk.
        - Output one label per chunk id. No explanations.
        """

    static let sentenceLabelInstructions = """
        You label short podcast transcript sentences as "ad" or "content" only (no mixed/unsure).
        Use the TOPIC CARD. Sponsor/commercial/marketing = ad. In-domain show talk = content.
        If unsure, choose content. Output one label per id. No explanations.
        """

    static func topicCardUserPrompt(context: SegmentationContext) -> String {
        let c = context.trimmed()
        return """
            SHOW NAME: \(c.showTitle)
            SHOW DESCRIPTION: \(c.showDescription.isEmpty ? "(none)" : c.showDescription)
            EPISODE TITLE: \(c.episodeTitle)
            EPISODE DESCRIPTION: \(c.episodeDescription.isEmpty ? "(none)" : c.episodeDescription)
            """
    }

    static func fallbackTopicCard(context: SegmentationContext) -> String {
        let title = context.showTitle.isEmpty ? "this podcast" : context.showTitle
        return """
            SHOW DOMAIN — \(title)
            EPISODE HOOKS — general episode / variety
            SCOPE — In-domain host talk, interviews, and digressions are content even when the conversation jumps around.
            OUT OF SCOPE — sponsor reads, commercials, network promos (even if local to the audience)
            """
    }

    static func formatChunkBatch(
        topicCard: String,
        windows: [TranscriptWindow],
        previousLabel: ChunkAdLabel?,
        previousSnippet: String?
    ) -> String {
        var lines: [String] = ["TOPIC CARD:", topicCard, "", "CHUNKS:"]
        for (index, window) in windows.enumerated() {
            let prev: String
            if index == 0 {
                let pl = previousLabel?.rawValue ?? "content"
                let snip = previousSnippet ?? ""
                prev = "prev: \(pl) | \"\(snip)\""
            } else {
                let prior = windows[index - 1]
                prev = "prev: (prior in batch) | \"\(snippet(prior.text))\""
            }
            let nextText: String
            if index + 1 < windows.count {
                nextText = snippet(windows[index + 1].text)
            } else {
                nextText = "(end of batch)"
            }
            lines.append("[\(window.id)] \(fmt(window.start))-\(fmt(window.end))")
            lines.append("  \(prev)")
            lines.append("  next_text: \"\(nextText)\"")
            lines.append("  text: \(window.text)")
            lines.append("")
        }
        return lines.joined(separator: "\n")
    }

    private static func snippet(_ text: String, max: Int = 80) -> String {
        let t = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard t.count > max else { return t }
        return String(t.suffix(max))
    }

    private static func fmt(_ t: Double) -> String {
        String(format: "%.1f", t)
    }
}
