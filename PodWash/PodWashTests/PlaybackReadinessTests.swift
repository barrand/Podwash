import XCTest
@testable import PodWash

final class PlaybackReadinessTests: XCTestCase {
    func testReadinessStatesRemainDistinct() {
        XCTAssertNotEqual(AppShellModel.PlaybackReadiness.ready, .preparing)
        XCTAssertNotEqual(AppShellModel.PlaybackReadiness.preparing, .failed)
        XCTAssertNotEqual(AppShellModel.PlaybackReadiness.ready, .failed)
    }
}
