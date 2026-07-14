//
//  AnalysisTimelineViewLayoutTests.swift
//  PodWashTests
//
//  Task 011 — Player chrome timeline minimum heights.
//

import XCTest
@testable import PodWash

final class AnalysisTimelineViewLayoutTests: XCTestCase {

    func testPlayerChromeTimelineMinimumHeights() {
        XCTAssertGreaterThanOrEqual(AnalysisTimelineModel.miniPlayerTimelineHeight, 12)
        XCTAssertGreaterThanOrEqual(AnalysisTimelineModel.fullPlayerTimelineHeight, 20)
        XCTAssertGreaterThan(
            AnalysisTimelineModel.fullPlayerTimelineHeight,
            AnalysisTimelineModel.miniPlayerTimelineHeight
        )
    }
}
