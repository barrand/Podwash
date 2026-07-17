//
//  TopicLLMSegmenter.swift
//  PodWash
//
//  topic-llm-v1 — Apple Foundation Models TopicCard + chunk labeling + stitch.
//

import Foundation
import os

#if canImport(FoundationModels)
import FoundationModels
#endif

private let topicLLMLog = Logger(subsystem: "com.barrandfarm.PodWash", category: "TopicLLM")

/// Async topic/LLM content segmenter. Falls back to heuristic when Apple Intelligence is unavailable.
nonisolated protocol TopicSegmenting: Sendable {
    var approachIdentifier: String { get }
    var isModelAvailable: Bool { get }
    func segments(in transcript: [TimedWord], context: SegmentationContext) async -> [ContentSegment]
}

/// Production topic-llm-v1 segmenter.
nonisolated struct TopicLLMSegmenter: TopicSegmenting {
    var approachIdentifier: String { TopicLLMPrompts.approachIdentifier }

    /// When Foundation Models cannot run, use heuristic-cue-v6.1.
    var fallback: HeuristicContentSegmenter = HeuristicContentSegmenter()

    /// Emitted when `PODWASH_TOPIC_LLM_VERBOSE=1` (labeler-cli / debugging).
    var verboseDiagnostics: Bool = ProcessInfo.processInfo.environment["PODWASH_TOPIC_LLM_VERBOSE"] == "1"

    var isModelAvailable: Bool {
        #if canImport(FoundationModels)
        if #available(iOS 26.0, macOS 26.0, *) {
            if case .available = SystemLanguageModel.default.availability {
                return true
            }
        }
        #endif
        return false
    }

    func segments(in transcript: [TimedWord], context: SegmentationContext) async -> [ContentSegment] {
        guard isModelAvailable else {
            return fallback.segments(in: transcript)
        }
        #if canImport(FoundationModels)
        if #available(iOS 26.0, macOS 26.0, *) {
            do {
                return try await labelWithFoundationModels(transcript: transcript, context: context)
            } catch {
                diag("foundation-models path failed: \(error) — heuristic fallback")
                return fallback.segments(in: transcript)
            }
        }
        #endif
        return fallback.segments(in: transcript)
    }

    private func diag(_ message: String) {
        topicLLMLog.error("\(message, privacy: .public)")
        if verboseDiagnostics {
            fputs("topic-llm: \(message)\n", stderr)
        }
    }

    #if canImport(FoundationModels)
    @available(iOS 26.0, macOS 26.0, *)
    private func labelWithFoundationModels(
        transcript: [TimedWord],
        context: SegmentationContext
    ) async throws -> [ContentSegment] {
        let windows = TranscriptWindowChunker.windows(from: transcript)
        guard !windows.isEmpty else { return [] }

        var topicCard = try await makeTopicCard(context: context)
        if topicCard.count > 350 {
            topicCard = String(topicCard.prefix(350)) + "…"
        }
        if verboseDiagnostics {
            fputs("topic-llm: topicCard=\n\(topicCard)\n", stderr)
            fputs("topic-llm: windows=\(windows.count)\n", stderr)
        }

        // Fresh session every few windows — on-device context is ~4k and accumulates turns.
        var session = LanguageModelSession(instructions: TopicLLMPrompts.chunkLabelInstructions)
        var turnsInSession = 0
        let maxTurnsPerSession = 4
        var resolved: [(TranscriptWindow, ChunkAdLabel)] = []
        var prevLabel: ChunkAdLabel = .content
        var prevSnippet = ""
        var labelCounts: [ChunkAdLabel: Int] = [:]

        for (offset, window) in windows.enumerated() {
            if turnsInSession >= maxTurnsPerSession {
                session = LanguageModelSession(instructions: TopicLLMPrompts.chunkLabelInstructions)
                turnsInSession = 0
            }
            let nextText = (offset + 1 < windows.count) ? windows[offset + 1].text : nil
            let raw: ChunkAdLabel
            do {
                raw = try await labelOneWindow(
                    session: &session,
                    topicCard: topicCard,
                    window: window,
                    previousLabel: prevLabel,
                    previousSnippet: prevSnippet,
                    nextText: nextText,
                    allowMixedUnsure: true
                )
                turnsInSession += 1
            } catch let error as LanguageModelSession.GenerationError {
                switch error {
                case .exceededContextWindowSize:
                    diag("context full at window \(window.id) — new session")
                    session = LanguageModelSession(instructions: TopicLLMPrompts.chunkLabelInstructions)
                    turnsInSession = 0
                    do {
                        raw = try await labelOneWindow(
                            session: &session,
                            topicCard: topicCard,
                            window: window,
                            previousLabel: prevLabel,
                            previousSnippet: prevSnippet,
                            nextText: nextText,
                            allowMixedUnsure: true
                        )
                        turnsInSession += 1
                    } catch {
                        raw = sellHeuristicLabel(window)
                    }
                case .refusal:
                    diag("refusal at window \(window.id) — sell-heuristic")
                    raw = sellHeuristicLabel(window)
                default:
                    diag("error at window \(window.id): \(error) — sell-heuristic")
                    raw = sellHeuristicLabel(window)
                }
            } catch {
                diag("error at window \(window.id): \(error) — sell-heuristic")
                raw = sellHeuristicLabel(window)
            }

            var label = AdSpanStitcher.resolveUnsure(
                label: raw,
                text: window.text,
                previousResolved: prevLabel,
                nextText: nextText
            )
            // Short local live-reads are often marked content; strong sponsor openers win.
            if label == .content || label == .unsure,
               AdSpanStitcher.looksLikeStrongSponsor(window.text.lowercased())
            {
                label = .ad
            }

            if label == .mixed {
                let refined = await refineMixed(
                    session: &session,
                    window: window,
                    topicCard: topicCard,
                    previousLabel: prevLabel
                )
                for item in refined {
                    resolved.append(item)
                    labelCounts[item.1, default: 0] += 1
                    prevLabel = item.1
                    prevSnippet = String(item.0.text.suffix(60))
                }
                continue
            }
            if label == .unsure {
                label = .content
            }
            resolved.append((window, label))
            labelCounts[label, default: 0] += 1
            prevLabel = label
            prevSnippet = String(window.text.suffix(60))
            if verboseDiagnostics, (offset + 1) % 20 == 0 {
                fputs("topic-llm: progress \(offset + 1)/\(windows.count)\n", stderr)
            }
        }

        if verboseDiagnostics {
            let hist = labelCounts.keys.sorted { $0.rawValue < $1.rawValue }
                .map { "\($0.rawValue)=\(labelCounts[$0] ?? 0)" }
                .joined(separator: " ")
            fputs("topic-llm: labels \(hist)\n", stderr)
        }

        return AdSpanStitcher.mergeAdSpans(labeled: resolved)
            .filter { segment in
                // Drop model false-positives on energetic in-domain talk with no marketing cues.
                let text = transcript
                    .filter { $0.start >= segment.start - 0.05 && $0.end <= segment.end + 0.05 }
                    .map(\.word)
                    .joined(separator: " ")
                    .lowercased()
                return AdSpanStitcher.looksLikeSell(text)
            }
    }

    @available(iOS 26.0, macOS 26.0, *)
    private func makeTopicCard(context: SegmentationContext) async throws -> String {
        let trimmed = context.trimmed(maxChars: 400)
        if trimmed.showTitle.isEmpty, trimmed.episodeTitle.isEmpty,
           trimmed.showDescription.isEmpty, trimmed.episodeDescription.isEmpty
        {
            return TopicLLMPrompts.fallbackTopicCard(context: context)
        }
        let session = LanguageModelSession(instructions: TopicLLMPrompts.topicCardInstructions)
        do {
            let response = try await session.respond(
                to: TopicLLMPrompts.topicCardUserPrompt(context: trimmed)
            )
            let card = response.content.trimmingCharacters(in: .whitespacesAndNewlines)
            return card.isEmpty ? TopicLLMPrompts.fallbackTopicCard(context: context) : card
        } catch {
            return TopicLLMPrompts.fallbackTopicCard(context: context)
        }
    }

    @available(iOS 26.0, macOS 26.0, *)
    private func labelOneWindow(
        session: inout LanguageModelSession,
        topicCard: String,
        window: TranscriptWindow,
        previousLabel: ChunkAdLabel,
        previousSnippet: String,
        nextText: String?,
        allowMixedUnsure: Bool
    ) async throws -> ChunkAdLabel {
        let text = clip(window.text, maxChars: 280)
        let next = clip(nextText ?? "", maxChars: 80)
        let prev = clip(previousSnippet, maxChars: 80)
        let prompt = """
            CARD: \(clip(topicCard, maxChars: 280))
            id=\(window.id) t=\(String(format: "%.0f", window.start))-\(String(format: "%.0f", window.end))
            prev=\(previousLabel.rawValue) "\(prev)"
            next="\(next)"
            text: \(text)
            """

        if allowMixedUnsure {
            let response = try await session.respond(
                to: prompt,
                generating: TopicChunkOneLabel.self
            )
            return ChunkAdLabel.parse(response.content.label)
        } else {
            let response = try await session.respond(
                to: prompt,
                generating: TopicChunkBinaryLabel.self
            )
            return ChunkAdLabel.parse(response.content.label)
        }
    }

    @available(iOS 26.0, macOS 26.0, *)
    private func refineMixed(
        session: inout LanguageModelSession,
        window: TranscriptWindow,
        topicCard: String,
        previousLabel: ChunkAdLabel
    ) async -> [(TranscriptWindow, ChunkAdLabel)] {
        let subs = TranscriptWindowChunker.sentenceWindows(from: window, startingID: window.id * 1000)
        guard !subs.isEmpty else { return [(window, .content)] }
        let capped = Array(subs.prefix(6))
        var prev = previousLabel
        var out: [(TranscriptWindow, ChunkAdLabel)] = []
        for (i, sub) in capped.enumerated() {
            let next = (i + 1 < capped.count) ? capped[i + 1].text : nil
            let raw: ChunkAdLabel
            do {
                raw = try await labelOneWindow(
                    session: &session,
                    topicCard: topicCard,
                    window: sub,
                    previousLabel: prev,
                    previousSnippet: String(prev == .ad ? "ad" : "content"),
                    nextText: next,
                    allowMixedUnsure: false
                )
            } catch {
                raw = sellHeuristicLabel(sub)
            }
            var label = raw
            if label == .mixed || label == .unsure { label = .content }
            label = AdSpanStitcher.resolveUnsure(
                label: label,
                text: sub.text,
                previousResolved: prev,
                nextText: next
            )
            if label == .unsure || label == .mixed { label = .content }
            out.append((sub, label))
            prev = label
        }
        for sub in subs.dropFirst(capped.count) {
            out.append((sub, .content))
        }
        return out
    }

    private func sellHeuristicLabel(_ window: TranscriptWindow) -> ChunkAdLabel {
        let lower = window.text.lowercased()
        if AdSpanStitcher.looksLikeShowResume(lower) { return .content }
        if AdSpanStitcher.looksLikeSell(lower) { return .ad }
        return .content
    }

    private func clip(_ text: String, maxChars: Int) -> String {
        let t = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard t.count > maxChars else { return t }
        return String(t.prefix(maxChars)) + "…"
    }
    #endif
}

#if canImport(FoundationModels)
@available(iOS 26.0, macOS 26.0, *)
@Generable
struct TopicChunkOneLabel {
    @Guide(description: "Chunk label", .anyOf(["ad", "content", "mixed", "unsure"]))
    var label: String
}

@available(iOS 26.0, macOS 26.0, *)
@Generable
struct TopicChunkBinaryLabel {
    @Guide(description: "Sentence label", .anyOf(["ad", "content"]))
    var label: String
}
#endif
