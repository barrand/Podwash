// Segmenter CLI — [--approach v6.1|viterbi] transcript TimedWord JSON path.
// Prints {"approach":"...","segments":[{"start":..,"end":..}]}
// Compile with scripts/build_segmenter_cli.sh

import Foundation

@main
struct SegmenterCLI {
    static func main() throws {
        let args = CommandLine.arguments
        let raw = Array(args.dropFirst())
        let approach: String
        let path: String
        if raw.count == 3, raw[0] == "--approach" {
            approach = raw[1]
            path = raw[2]
        } else if raw.count == 1 {
            approach = "v6.1"
            path = raw[0]
        } else {
            fputs("usage: segmenter-cli [--approach v6.1|viterbi] <transcript.json>\n", stderr)
            exit(2)
        }
        let url = URL(fileURLWithPath: path)
        let data = try Data(contentsOf: url)
        let words = try JSONDecoder().decode([TimedWord].self, from: data)
        let segmenter: any ContentSegmenting
        switch approach {
        case "v6.1", "heuristic-cue-v6.1":
            segmenter = HeuristicContentSegmenter()
        case "viterbi", "anchor-viterbi-v1":
            segmenter = HeuristicContentSegmenter.AnchorViterbiContentSegmenter()
        default:
            fputs("unknown approach: \(approach)\n", stderr)
            exit(2)
        }
        let segments = segmenter.segments(in: words)
        let payload: [String: Any] = [
            "approach": segmenter.approachIdentifier,
            "segments": segments.map { ["start": $0.start, "end": $0.end] },
        ]
        let out = try JSONSerialization.data(withJSONObject: payload, options: [.prettyPrinted, .sortedKeys])
        FileHandle.standardOutput.write(out)
        FileHandle.standardOutput.write(Data("\n".utf8))
    }
}
