//
//  TopicLLMSegmenter.swift
//  PodWash
//
//  topic-llm-v1 — Apple Foundation Models TopicCard + chunk labeling + stitch.
//

import Foundation

#if canImport(FoundationModels)
import FoundationModels
#endif

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
                return fallback.segments(in: transcript)
            }
        }
        #endif
        return fallback.segments(in: transcript)
    }

    #if canImport(FoundationModels)
    @available(iOS 26.0, macOS 26.0, *)
    private func labelWithFoundationModels(
        transcript: [TimedWord],
        context: SegmentationContext
    ) async throws -> [ContentSegment] {
        let windows = TranscriptWindowChunker.windows(from: transcript)
        guard !windows.isEmpty else { return [] }

        let topicCard = try await makeTopicCard(context: context)
        var resolved: [(TranscriptWindow, ChunkAdLabel)] = []
        var prevLabel: ChunkAdLabel = .content
        var prevSnippet = ""

        let batchSize = 20
        var index = 0
        while index < windows.count {
            let end = min(index + batchSize, windows.count)
            let batch = Array(windows[index..<end])
            let rawLabels = try await labelBatch(
                topicCard: topicCard,
                windows: batch,
                previousLabel: prevLabel,
                previousSnippet: prevSnippet,
                allowMixedUnsure: true
            )

            var batchResolved: [(TranscriptWindow, ChunkAdLabel)] = []
            for (offset, window) in batch.enumerated() {
                let raw = rawLabels[window.id] ?? .content
                let nextText = (offset + 1 < batch.count) ? batch[offset + 1].text : nil
                var label = AdSpanStitcher.resolveUnsure(
                    label: raw,
                    text: window.text,
                    previousResolved: prevLabel,
                    nextText: nextText
                )
                if label == .mixed {
                    let refined = try await refineMixed(
                        window: window,
                        topicCard: topicCard,
                        previousLabel: prevLabel
                    )
                    for item in refined {
                        batchResolved.append(item)
                        prevLabel = item.1
                        prevSnippet = String(item.0.text.suffix(80))
                    }
                    continue
                }
                if label == .unsure {
                    label = .content
                }
                batchResolved.append((window, label))
                prevLabel = label
                prevSnippet = String(window.text.suffix(80))
            }
            resolved.append(contentsOf: batchResolved)
            index = end
        }

        return AdSpanStitcher.mergeAdSpans(labeled: resolved)
    }

    @available(iOS 26.0, macOS 26.0, *)
    private func makeTopicCard(context: SegmentationContext) async throws -> String {
        let trimmed = context.trimmed()
        if trimmed.showTitle.isEmpty, trimmed.episodeTitle.isEmpty,
           trimmed.showDescription.isEmpty, trimmed.episodeDescription.isEmpty
        {
            return TopicLLMPrompts.fallbackTopicCard(context: context)
        }
        let session = LanguageModelSession(instructions: TopicLLMPrompts.topicCardInstructions)
        let response = try await session.respond(
            to: TopicLLMPrompts.topicCardUserPrompt(context: trimmed)
        )
        let card = response.content.trimmingCharacters(in: .whitespacesAndNewlines)
        return card.isEmpty ? TopicLLMPrompts.fallbackTopicCard(context: context) : card
    }

    @available(iOS 26.0, macOS 26.0, *)
    private func labelBatch(
        topicCard: String,
        windows: [TranscriptWindow],
        previousLabel: ChunkAdLabel?,
        previousSnippet: String?,
        allowMixedUnsure: Bool
    ) async throws -> [Int: ChunkAdLabel] {
        let instructions = allowMixedUnsure
            ? TopicLLMPrompts.chunkLabelInstructions
            : TopicLLMPrompts.sentenceLabelInstructions
        let session = LanguageModelSession(instructions: instructions)
        let prompt = TopicLLMPrompts.formatChunkBatch(
            topicCard: topicCard,
            windows: windows,
            previousLabel: previousLabel,
            previousSnippet: previousSnippet
        )
        do {
            let response = try await session.respond(
                to: prompt,
                generating: TopicChunkLabelBatch.self
            )
            var map: [Int: ChunkAdLabel] = [:]
            for item in response.content.labels {
                map[item.id] = ChunkAdLabel.parse(item.label)
            }
            // Missing ids → content
            for w in windows where map[w.id] == nil {
                map[w.id] = .content
            }
            return map
        } catch {
            // Guardrail / generation failure → fail-safe content
            var map: [Int: ChunkAdLabel] = [:]
            for w in windows { map[w.id] = .content }
            return map
        }
    }

    @available(iOS 26.0, macOS 26.0, *)
    private func refineMixed(
        window: TranscriptWindow,
        topicCard: String,
        previousLabel: ChunkAdLabel
    ) async throws -> [(TranscriptWindow, ChunkAdLabel)] {
        let subs = TranscriptWindowChunker.sentenceWindows(from: window, startingID: window.id * 1000)
        guard !subs.isEmpty else { return [(window, .content)] }
        let map = try await labelBatch(
            topicCard: topicCard,
            windows: subs,
            previousLabel: previousLabel,
            previousSnippet: String(window.text.prefix(40)),
            allowMixedUnsure: false
        )
        var prev = previousLabel
        var out: [(TranscriptWindow, ChunkAdLabel)] = []
        for sub in subs {
            var label = map[sub.id] ?? .content
            if label == .mixed || label == .unsure { label = .content }
            label = AdSpanStitcher.resolveUnsure(
                label: label,
                text: sub.text,
                previousResolved: prev,
                nextText: nil
            )
            if label == .unsure || label == .mixed { label = .content }
            out.append((sub, label))
            prev = label
        }
        return out
    }
    #endif
}

#if canImport(FoundationModels)
@available(iOS 26.0, macOS 26.0, *)
@Generable(description: "Batch of chunk labels")
struct TopicChunkLabelBatch {
    @Guide(description: "One entry per chunk id")
    var labels: [TopicChunkLabelItem]
}

@available(iOS 26.0, macOS 26.0, *)
@Generable(description: "Label for one transcript chunk")
struct TopicChunkLabelItem {
    var id: Int
    @Guide(description: "One of: ad, content, mixed, unsure")
    var label: String
}
#endif
