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

    /// Compact runtime instructions (plan policy, fewer tokens for on-device context).
    static let chunkLabelInstructions = """
        You classify one podcast transcript chunk for a skip-ads feature.
        Output only the structured label field.
        ad = commercial, sponsor read, promo, live-read, or marketing sell (offer/visit/apply/shop/brand+URL), including cold opens and local sponsors.
        content = in-domain host talk, interview, news, digression, show open/close, welcome-back without a pitch.
        mixed = both a clear ad stretch and clear show content in this chunk.
        unsure = cannot tell.
        Domain is the main topic signal. Energetic in-domain talk about games, recruiting, NIL, coaches, or schedules is content unless it is a sponsor pitch.
        """

    static let sentenceLabelInstructions = """
        Classify one short sentence: ad or content. Marketing/sponsor = ad. In-domain talk = content. If unsure → content.
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
        let card = clip(topicCard, maxChars: 400)
        var lines: [String] = ["CARD:", card, "", "CHUNKS:"]
        for (index, window) in windows.enumerated() {
            let prev: String
            if index == 0 {
                let pl = previousLabel?.rawValue ?? "content"
                let snip = snippet(previousSnippet ?? "", max: 60)
                prev = "prev:\(pl)|\"\(snip)\""
            } else {
                let prior = windows[index - 1]
                prev = "prev:(batch)|\"\(snippet(prior.text, max: 60))\""
            }
            let nextText: String
            if index + 1 < windows.count {
                nextText = snippet(windows[index + 1].text, max: 60)
            } else {
                nextText = "(end)"
            }
            lines.append("[\(window.id)] \(fmt(window.start))-\(fmt(window.end))")
            lines.append("  \(prev)")
            lines.append("  next:\"\(nextText)\"")
            lines.append("  text:\(clip(window.text, maxChars: 320))")
        }
        return lines.joined(separator: "\n")
    }

    private static func snippet(_ text: String, max: Int = 80) -> String {
        let t = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard t.count > max else { return t }
        return String(t.suffix(max))
    }

    private static func clip(_ text: String, maxChars: Int) -> String {
        let t = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard t.count > maxChars else { return t }
        return String(t.prefix(maxChars)) + "…"
    }

    private static func fmt(_ t: Double) -> String {
        String(format: "%.1f", t)
    }
}
