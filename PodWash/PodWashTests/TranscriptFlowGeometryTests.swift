import CoreGraphics
import XCTest
@testable import PodWash

final class TranscriptFlowGeometryTests: XCTestCase {
    func testFiniteContainerWidthIsPreservedAcrossWrappedRows() {
        let layout = TranscriptFlowGeometry(
            itemSizes: Array(repeating: CGSize(width: 100, height: 20), count: 3),
            containerWidth: 250,
            horizontalSpacing: 4,
            verticalSpacing: 4
        )

        XCTAssertEqual(layout.size, CGSize(width: 250, height: 44))
        XCTAssertEqual(layout.frames.map(\.origin), [
            CGPoint(x: 0, y: 0),
            CGPoint(x: 104, y: 0),
            CGPoint(x: 0, y: 24),
        ])
    }

    func testOversizedTokenIsConstrainedToTranscriptColumn() {
        let layout = TranscriptFlowGeometry(
            itemSizes: [
                CGSize(width: 600, height: 60),
                CGSize(width: 40, height: 20),
            ],
            containerWidth: 250,
            horizontalSpacing: 4,
            verticalSpacing: 4
        )

        XCTAssertEqual(layout.frames[0], CGRect(x: 0, y: 0, width: 250, height: 60))
        XCTAssertEqual(layout.frames[1], CGRect(x: 0, y: 64, width: 40, height: 20))
        XCTAssertEqual(layout.size, CGSize(width: 250, height: 84))
        XCTAssertTrue(layout.frames.allSatisfy { $0.maxX <= layout.size.width })
    }

    func testUnconstrainedMeasurementUsesNaturalContentSize() {
        let layout = TranscriptFlowGeometry(
            itemSizes: [
                CGSize(width: 30, height: 18),
                CGSize(width: 50, height: 20),
            ],
            containerWidth: nil,
            horizontalSpacing: 4,
            verticalSpacing: 4
        )

        XCTAssertEqual(layout.frames[1].origin, CGPoint(x: 34, y: 0))
        XCTAssertEqual(layout.size, CGSize(width: 84, height: 20))
    }
}
