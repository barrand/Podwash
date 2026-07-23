import XCTest
@testable import PodWash

final class AnchorViterbiContentSegmenterTests: XCTestCase {
    private func words(_ values: [String]) -> [TimedWord] {
        values.enumerated().map { offset, word in
            TimedWord(word: word, start: Double(offset) * 2, end: Double(offset) * 2 + 1)
        }
    }

    func testViterbiKeepsSoftInteriorBetweenSponsorAnchors() {
        let transcript = words([
            "This", "episode", "is", "sponsored", "by", "Acme.",
            "Their", "tools", "help", "teams", "work.",
            "Visit", "acme.com", "today.",
            "Back", "to", "the", "interview."
        ])
        let segments = HeuristicContentSegmenter.AnchorViterbiContentSegmenter().segments(in: transcript)
        XCTAssertEqual(segments.count, 1)
        XCTAssertLessThanOrEqual(segments[0].start, 1)
        XCTAssertGreaterThanOrEqual(segments[0].end, 26)
        XCTAssertLessThan(segments[0].end, 30)
    }

    func testViterbiReturnsNoSegmentsForNormalConversation() {
        let transcript = words(["Today", "we", "talk", "about", "electric", "cars.", "The", "battery", "market", "is", "changing."])
        XCTAssertTrue(HeuristicContentSegmenter.AnchorViterbiContentSegmenter().segments(in: transcript).isEmpty)
    }
}
