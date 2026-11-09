import SwiftUI
import UIKit
import XCTest
@testable import PodWash

@MainActor
final class BackgroundActivityLayoutTests: XCTestCase {
    private let longTitle = "A very long episode title about how the world changes, with more details than fit on a small phone"

    func testLongTitleKeepsCompactStripWithinNarrowPhoneWidth() {
        let size = measure(width: 320, type: .large)
        XCTAssertEqual(size.width, 320, accuracy: 1)
        XCTAssertGreaterThan(size.height, 20)
        XCTAssertLessThan(size.height, 44, "Normal activity should stay a single compact row")
    }

    func testLargeTypeWrapsVerticallyWithoutOverflowingWidth() {
        let normal = measure(width: 320, type: .large)
        let accessible = measure(width: 320, type: .accessibility3)
        XCTAssertEqual(accessible.width, 320, accuracy: 1)
        XCTAssertGreaterThan(accessible.height, normal.height)
        XCTAssertLessThan(accessible.height, 180, "Accessible text must leave room for the player and tabs")
    }

    func testFailureRecoveryHasRoomForFullSizeDismissTarget() {
        let size = measure(width: 320, type: .large, failure: true)
        XCTAssertEqual(size.width, 320, accuracy: 1)
        XCTAssertGreaterThanOrEqual(size.height, 44)
    }

    func testReducedMotionVoiceOverAndLargeTextEachDisableAutomaticScrolling() {
        XCTAssertTrue(ActivityMarqueeMotion.usesStaticText(reduceMotion: true, voiceOver: false, largeText: false))
        XCTAssertTrue(ActivityMarqueeMotion.usesStaticText(reduceMotion: false, voiceOver: true, largeText: false))
        XCTAssertTrue(ActivityMarqueeMotion.usesStaticText(reduceMotion: false, voiceOver: false, largeText: true))
        XCTAssertFalse(ActivityMarqueeMotion.usesStaticText(reduceMotion: false, voiceOver: false, largeText: false))
    }

    private func measure(width: CGFloat, type: DynamicTypeSize,
                         failure: Bool = false) -> CGSize {
        let presentation = BackgroundActivityPresentation(episodeID: "episode", title: longTitle,
            status: failure ? "Preparation needs attention" : "Preparing", symbol: "waveform",
            additionalCount: 2, failureID: failure ? "failure" : nil)
        let view = BackgroundActivityMarquee(presentation: presentation, onOpenIssue: {}, onDismissIssue: {})
            .dynamicTypeSize(type)
        let controller = UIHostingController(rootView: view)
        return controller.sizeThatFits(in: CGSize(width: width, height: 1000))
    }
}
