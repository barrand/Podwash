// Segmenter CLI — argv[1] = transcript TimedWord JSON path.
// Prints {"approach":"...","segments":[{"start":..,"end":..}]}
// Compile with scripts/build_segmenter_cli.sh

import Foundation

@main
struct SegmenterCLI {
    static func main() throws {
        let args = CommandLine.arguments
        guard args.count >= 2 else {
            fputs("usage: segmenter-cli <transcript.json>\n", stderr)
            exit(2)
        }
        let url = URL(fileURLWithPath: args[1])
        let data = try Data(contentsOf: url)
        let words = try JSONDecoder().decode([TimedWord].self, from: data)
        let segmenter = HeuristicContentSegmenter()
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
