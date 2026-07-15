//
//  MiniPlayerSuperSeekBarHostTests.swift
//  PodWashTests
//
//  Slice 30 — Shared SuperSeekBarView host seam (ADR-026 §1). AC6.
//  Source-contract asserts: both player chrome hosts use SuperSeekBarView; mini
//  retires AnalysisTimelineView / miniPlayerAnalysisTimeline for player chrome.
//
//  Until Engineer migrates MiniPlayerBar (slice-30 implement), these tests fail —
//  intended TDD red state.
//

import XCTest

final class MiniPlayerSuperSeekBarHostTests: XCTestCase {

    private var innerProjectDir: URL {
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
    }

    private var miniPlayerBarURL: URL {
        innerProjectDir.appendingPathComponent("PodWash/MiniPlayerBar.swift")
    }

    private var playbackControlsViewURL: URL {
        innerProjectDir.appendingPathComponent("PodWash/PlaybackControlsView.swift")
    }

    // MARK: - AC6

    func testMiniPlayerBarHostsSuperSeekBarViewNotParallelTimelinePaint() throws {
        let source = try String(contentsOf: miniPlayerBarURL, encoding: .utf8)
        XCTAssertTrue(
            source.contains("SuperSeekBarView"),
            "MiniPlayerBar must host SuperSeekBarView (ADR-026 shared chrome)"
        )
        XCTAssertFalse(
            source.contains("AnalysisTimelineView"),
            "Mini player chrome must not paint AnalysisTimelineView — use SuperSeekBarView only"
        )
        XCTAssertFalse(
            source.contains("miniPlayerAnalysisTimeline"),
            "Retired miniPlayerAnalysisTimeline identifier must not appear in MiniPlayerBar"
        )
    }

    func testPlaybackControlsViewHostsSuperSeekBarView() throws {
        let source = try String(contentsOf: playbackControlsViewURL, encoding: .utf8)
        XCTAssertTrue(
            source.contains("SuperSeekBarView"),
            "PlaybackControlsView must host SuperSeekBarView for full-player chrome"
        )
        XCTAssertFalse(
            source.contains("AnalysisTimelineView"),
            "Full player chrome must not paint a parallel AnalysisTimelineView seek path"
        )
    }
}
