import SwiftUI

/// Small state machine for transcript follow behavior. Keeping this independent
/// of SwiftUI makes the recovery control deterministic and testable.
struct TranscriptFollowState {
    private(set) var isFollowing = true

    mutating func userBeganScrolling() {
        isFollowing = false
    }

    mutating func snapToFollow() {
        isFollowing = true
    }
}
