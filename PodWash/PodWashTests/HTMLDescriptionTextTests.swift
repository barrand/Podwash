//
//  HTMLDescriptionTextTests.swift
//  PodWashTests
//

import XCTest
@testable import PodWash

final class HTMLDescriptionTextTests: XCTestCase {
    func testConvertsRSSHTMLToDisplayText() {
        let description = HTMLDescriptionText.attributedString(
            from: "<p>Listen to <strong>PodWash</strong> &amp; enjoy.</p>"
        )

        XCTAssertEqual(
            String(description.characters).trimmingCharacters(in: .whitespacesAndNewlines),
            "Listen to PodWash & enjoy."
        )
    }

    func testKeepsPlainTextDescriptionsUnchanged() {
        let description = HTMLDescriptionText.attributedString(from: "A plain podcast description.")

        XCTAssertEqual(String(description.characters), "A plain podcast description.")
    }
}
