import SwiftUI
import XCTest
@testable import PodWash

@MainActor final class EpisodeListTimelineRetirementTests: XCTestCase {
    func testPreparationIsIndeterminateNotInventedTimeline() {
        let row = EpisodeRowPresentationMapper.map(.preparing)
        XCTAssertEqual(row.primaryControl, .progress(nil))
        XCTAssertNil(row.progress)
        XCTAssertFalse(row.statusText.contains("minute"))
    }
    func testCheckingAdsDoesNotClaimMeasuredProgress() {
        let row = EpisodeRowPresentationMapper.map(.checkingAds)
        XCTAssertEqual(row.primaryControl, .progress(nil))
    }
}
