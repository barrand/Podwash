import XCTest
@testable import PodWash

final class TranscriptFollowStateTests: XCTestCase {
    func testManualScrollDisablesFollow() {
        var state = TranscriptFollowState()

        state.userBeganScrolling()

        XCTAssertFalse(state.isFollowing)
    }

    func testSnapRestoresFollowImmediately() {
        var state = TranscriptFollowState()
        state.userBeganScrolling()

        state.snapToFollow()

        XCTAssertTrue(state.isFollowing)
    }

    func testSnapDoesNotRequireACompletionCallback() {
        var state = TranscriptFollowState()
        state.userBeganScrolling()
        state.snapToFollow()

        XCTAssertTrue(state.isFollowing)
    }

    func testNextManualScrollAfterSnapDisablesFollow() {
        var state = TranscriptFollowState()
        state.snapToFollow()

        state.userBeganScrolling()

        XCTAssertFalse(state.isFollowing)
    }
}
