//
//  BuildStampTests.swift
//  PodWashTests
//
//  Task 008 — Visible build datestamp in Settings. AC1, AC3.
//
//  Fixture provenance:
//  - Pinned instant 2026-07-13 22:55:23 UTC → 26.7.13.16.55.23 MT (America/Denver, MDT).
//    Hand-derived from task-008 example format; independent of BuildStamp implementation.
//  - Stamp pattern `^\d{2}\.\d{1,2}\.\d{1,2}\.\d{1,2}\.\d{2}\.\d{2}$` from task-008 AC2.
//
//  Until BuildStamp.swift and compile-time stamp injection exist (Engineer),
//  these tests fail to compile — intended TDD red state.
//

import XCTest
@testable import PodWash

final class BuildStampTests: XCTestCase {

    private let infoPlistKey = "PodWashBuildStamp"
    private let stampPattern = #"^\d{2}\.\d{1,2}\.\d{1,2}\.\d{1,2}\.\d{2}\.\d{2}$"#

    /// 2026-07-13 22:55:23 UTC → 16:55:23 MDT (task-008 golden example).
    private var pinnedInstant: Date {
        var components = DateComponents()
        components.calendar = Calendar(identifier: .gregorian)
        components.timeZone = TimeZone(secondsFromGMT: 0)
        components.year = 2026
        components.month = 7
        components.day = 13
        components.hour = 22
        components.minute = 55
        components.second = 23
        guard let date = components.date else {
            XCTFail("Could not construct pinned instant")
            return Date()
        }
        return date
    }

    // MARK: - AC1

    func testFormatsPinnedDateInMountainTime() {
        XCTAssertEqual(
            BuildStamp.format(pinnedInstant),
            "26.7.13.16.55.23",
            "Pinned UTC instant must format to exact Mountain Time stamp (YY.M.D.H.MM.SS)"
        )
    }

    // MARK: - AC3

    func testStampMatchesBundledCompileTimeConstant() {
        let firstRead = BuildStamp.bundled
        let secondRead = BuildStamp.bundled

        XCTAssertFalse(firstRead.isEmpty, "Bundled stamp must be non-empty")
        XCTAssertEqual(
            firstRead,
            secondRead,
            "Compile-time stamp must be identical across reads in one process"
        )
        XCTAssertNotNil(
            firstRead.range(of: stampPattern, options: .regularExpression),
            "Bundled stamp must match YY.M.D.H.MM.SS pattern; got \(firstRead)"
        )

        guard let plistStamp = Bundle.main.object(forInfoDictionaryKey: infoPlistKey) as? String else {
            XCTFail("\(infoPlistKey) missing from test-host app Info.plist")
            return
        }
        XCTAssertFalse(plistStamp.isEmpty, "\(infoPlistKey) must be non-empty")
        XCTAssertEqual(
            firstRead,
            plistStamp,
            "BuildStamp.bundled must match Info.plist \(infoPlistKey)"
        )
    }
}
