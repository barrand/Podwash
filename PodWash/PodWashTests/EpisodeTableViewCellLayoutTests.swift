import SwiftUI
import UIKit
import XCTest
@testable import PodWash

@MainActor final class SharedEpisodeRowLayoutTests: XCTestCase {
    func testRowFitsNarrowAndPhoneWidthsAndSelfSizesWithLargeText() {
        for width in [320.0, 390.0, 430.0] {
            for size in [DynamicTypeSize.large, .accessibility3] {
                let snapshot = EpisodeRowSnapshot(episodeID: "stable-identity",
                    title: "A long episode title that wraps to two lines without losing the primary controls",
                    presentation: EpisodeRowPresentationMapper.map(.readyOffline),
                    context: .library(publicationDate: Date(), isPlayed: false),
                    cleaningSummary: nil, menu: [.addToUpNext, .markPlayed])
                let host = UIHostingController(rootView: SharedEpisodeRow(snapshot: snapshot,
                    bindings: EpisodeRowBindings(primary: EpisodeRowActions(), perform: { _ in }))
                    .environment(\.dynamicTypeSize, size))
                let fit = host.sizeThatFits(in: CGSize(width: width, height: 2000))
                XCTAssertLessThanOrEqual(fit.width, width + 1)
                XCTAssertGreaterThan(fit.width, 0)
                XCTAssertGreaterThan(fit.height, 44)
                XCTAssertLessThan(fit.height, 2000)
            }
        }
    }
}
