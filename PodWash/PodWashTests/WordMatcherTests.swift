//
//  WordMatcherTests.swift
//  PodWashTests
//
//  Slice 02 — Matching engine. Verifies WordMatcher against
//  docs/specs/matching-spec.md §3 (normalize) and §4 (exact set membership).
//

import XCTest
@testable import PodWash

final class WordMatcherTests: XCTestCase {

    /// AC1 — `normalize(_:)` matches the spec §3 example table.
    func testNormalizeMatchesSpecTable() {
        // Spec §3 example table.
        XCTAssertEqual(WordMatcher.normalize("Shit!"), "shit")
        XCTAssertEqual(WordMatcher.normalize("'ship'"), "ship")
        XCTAssertEqual(WordMatcher.normalize("$#!%"), "")
        XCTAssertEqual(WordMatcher.normalize("  FREAKING,"), "freaking")

        // Interior characters are untouched.
        XCTAssertEqual(WordMatcher.normalize("f*ck"), "f*ck")

        // Interior apostrophe preserved — and it does NOT collapse to "shit".
        XCTAssertEqual(WordMatcher.normalize("shit's"), "shit's")
        XCTAssertNotEqual(WordMatcher.normalize("shit's"), "shit")
    }

    /// AC2 — exact set membership only: "shipment" must NOT match a target set
    /// containing "ship" (substring-false-positive guarantee, spec §4).
    func testNoSubstringFalsePositive() {
        let targetSet = WordMatcher.normalizedTargetSet(WordProfiles.harmless)

        // Positive controls: the enumerated words themselves match.
        XCTAssertTrue(WordMatcher.matches(WordMatcher.normalize("ship"), in: targetSet))
        XCTAssertTrue(WordMatcher.matches(WordMatcher.normalize("shipped"), in: targetSet))

        // The guarantee: a superstring token does not match.
        XCTAssertFalse(
            WordMatcher.matches(WordMatcher.normalize("shipment"), in: targetSet),
            "\"shipment\" must not match a set containing \"ship\" (exact membership only)"
        )
        // And an unrelated token does not match either.
        XCTAssertFalse(WordMatcher.matches(WordMatcher.normalize("well"), in: targetSet))
    }
}
