//
//  SmokeTests.swift
//  PodWashTests
//
//  Slice 01 — Foundation. Real (non-template) smoke test that proves the
//  PodWash app module compiles, links, and can be exercised from the unit
//  test bundle via @testable import. This is the build/test loop every later
//  slice depends on.
//

import XCTest
@testable import PodWash

@MainActor
final class SmokeTests: XCTestCase {

    /// Asserts the app module loaded and a known app type is usable from tests.
    /// `Item` is a real type owned by the app target, so referencing and
    /// instantiating it confirms `@testable import PodWash` links correctly.
    func testAppModuleLoads() throws {
        let reference = Date(timeIntervalSince1970: 1_000)
        let item = Item(timestamp: reference)

        XCTAssertEqual(
            item.timestamp,
            reference,
            "Item from the PodWash app module should preserve its timestamp"
        )

        // The @main app type must be visible to the test bundle.
        XCTAssertNotNil(PodWashApp.self)
    }
}
