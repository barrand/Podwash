//
//  LabelerCLI — topic-llm-v1 offline runner.
//  usage: labeler-cli <transcript.json> [meta.json]
//  Prints {"approach":"topic-llm-v1","segments":[...],"topicCard":"...","available":bool}
//

import Foundation
#if canImport(FoundationModels)
import FoundationModels
#endif

struct LabelerMeta: Codable {
    var showName: String?
    var showDescription: String?
    var episodeTitle: String?
    var episodeDescription: String?
}

@main
struct LabelerCLI {
    static func main() async {
        let args = CommandLine.arguments
        guard args.count >= 2 else {
            fputs("usage: labeler-cli <transcript.json> [meta.json]\n", stderr)
            exit(2)
        }
        do {
            try await run(transcriptPath: args[1], metaPath: args.count >= 3 ? args[2] : nil)
        } catch {
            fputs("labeler-cli error: \(error)\n", stderr)
            exit(1)
        }
    }

    static func run(transcriptPath: String, metaPath: String?) async throws {
        let transcriptURL = URL(fileURLWithPath: transcriptPath)
        let words = try JSONDecoder().decode(
            [TimedWord].self,
            from: Data(contentsOf: transcriptURL)
        )

        var context = SegmentationContext.empty
        if let metaPath {
            let meta = try JSONDecoder().decode(
                LabelerMeta.self,
                from: Data(contentsOf: URL(fileURLWithPath: metaPath))
            )
            context = SegmentationContext(
                showTitle: meta.showName ?? "",
                showDescription: meta.showDescription ?? "",
                episodeTitle: meta.episodeTitle ?? "",
                episodeDescription: meta.episodeDescription ?? ""
            )
        } else {
            let sibling = transcriptURL.deletingLastPathComponent().appendingPathComponent("meta.json")
            if let data = try? Data(contentsOf: sibling),
               let meta = try? JSONDecoder().decode(LabelerMeta.self, from: data)
            {
                context = SegmentationContext(
                    showTitle: meta.showName ?? "",
                    showDescription: meta.showDescription ?? "",
                    episodeTitle: meta.episodeTitle ?? "",
                    episodeDescription: meta.episodeDescription ?? ""
                )
            }
        }

        let segmenter = TopicLLMSegmenter()
        let available = segmenter.isModelAvailable
        if !available {
            fputs(
                "warning: Apple Intelligence / Foundation Models unavailable — using heuristic fallback\n",
                stderr
            )
        }

        let segments = await segmenter.segments(in: words, context: context)
        let approach = available ? TopicLLMPrompts.approachIdentifier : segmenter.fallback.approachIdentifier

        let payload: [String: Any] = [
            "approach": approach,
            "available": available,
            "segments": segments.map { ["start": $0.start, "end": $0.end] as [String: Double] },
            "windowCount": TranscriptWindowChunker.windows(from: words).count,
        ]
        let out = try JSONSerialization.data(
            withJSONObject: payload,
            options: [.prettyPrinted, .sortedKeys]
        )
        FileHandle.standardOutput.write(out)
        FileHandle.standardOutput.write(Data("\n".utf8))
    }
}
