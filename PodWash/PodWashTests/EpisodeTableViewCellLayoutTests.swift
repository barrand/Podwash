//
//  EpisodeTableViewCellLayoutTests.swift
//  PodWashTests
//
//  Task 006 — Episode row survives SwiftUI→UIKit zero-width layout pass (AC1–AC2).
//

import XCTest
@testable import PodWash

@MainActor
final class EpisodeTableViewCellLayoutTests: XCTestCase {

    private static let fixtureEpisodeID = "fixture-ep-001"
    private static let zeroLayoutWidth: CGFloat = 0
    private static let phoneLayoutWidth: CGFloat = 390
    private static let accessoryButtonWidth: CGFloat = 44
    private static let timelineWidthTolerance: CGFloat = 1

    private var downloadsDirectory: URL!
    private var downloadManager: DownloadManager!

    override func setUp() async throws {
        downloadsDirectory = FileManager.default.temporaryDirectory
            .appendingPathComponent("EpisodeCellLayout-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: downloadsDirectory, withIntermediateDirectories: true)
        downloadManager = DownloadManager(
            sessionConfiguration: .ephemeral,
            downloadsDirectory: downloadsDirectory,
            stateStore: InMemoryDownloadStateStore()
        )
    }

    override func tearDown() async throws {
        downloadManager = nil
        if let downloadsDirectory {
            try? FileManager.default.removeItem(at: downloadsDirectory)
        }
        downloadsDirectory = nil
    }

    // MARK: - AC1: zero → phone width keeps 44pt accessories off the text stack

    func testCellSurvivesZeroWidthThenPhoneWidthWithoutOverlap() {
        let cell = makeConfiguredCell(showsTimeline: false)

        EpisodeTableViewCellLayoutTesting.layoutAtContentWidth(Self.zeroLayoutWidth, cell: cell)
        EpisodeTableViewCellLayoutTesting.layoutAtContentWidth(Self.phoneLayoutWidth, cell: cell)

        let queueAddButton = EpisodeTableViewCellLayoutTesting.queueAddButton(in: cell)
        let downloadButton = EpisodeTableViewCellLayoutTesting.downloadButton(in: cell)
        XCTAssertEqual(queueAddButton.bounds.width, Self.accessoryButtonWidth, accuracy: 0.5)
        XCTAssertEqual(downloadButton.bounds.width, Self.accessoryButtonWidth, accuracy: 0.5)

        let textStack = EpisodeTableViewCellLayoutTesting.textStack(in: cell)
        let accessoryStack = EpisodeTableViewCellLayoutTesting.accessoryStack(in: cell)
        let textFrame = textStack.convert(textStack.bounds, to: cell.contentView)
        let accessoryFrame = accessoryStack.convert(accessoryStack.bounds, to: cell.contentView)
        XCTAssertFalse(
            textFrame.intersects(accessoryFrame),
            "Accessory stack overlaps title/text stack after phone-width layout"
        )
    }

    // MARK: - AC2: zero → phone width fills analysis timeline bar to host width

    func testTimelineBarFillsHostAfterZeroWidthLayout() {
        let cell = makeConfiguredCell(showsTimeline: true)

        EpisodeTableViewCellLayoutTesting.layoutAtContentWidth(Self.zeroLayoutWidth, cell: cell)
        EpisodeTableViewCellLayoutTesting.layoutAtContentWidth(Self.phoneLayoutWidth, cell: cell)

        let host = EpisodeTableViewCellLayoutTesting.timelineHost(in: cell)
        let timelineBar = EpisodeTableViewCellLayoutTesting.timelineBar(in: cell)
        XCTAssertFalse(host.isHidden, "Analysis timeline host should be visible for this test")
        XCTAssertEqual(
            timelineBar.bounds.width,
            host.bounds.width,
            accuracy: Self.timelineWidthTolerance,
            "Timeline bar should fill its host after phone-width layout"
        )
    }

    // MARK: - Helpers

    private func makeConfiguredCell(showsTimeline: Bool) -> EpisodeTableViewCell {
        let episode = Episode(
            id: Self.fixtureEpisodeID,
            title: "Alpha Signal — Pilot Launch",
            pubDate: ISO8601DateFormatter().date(from: "2026-01-15T08:00:00Z")!,
            artworkURL: nil,
            showNotes: nil,
            audioURL: URL(string: "https://fixture.podwash.tests/audio/alpha.m4a")
        )

        let analysisViewModel = AnalysisUIViewModel(
            store: InMemoryCleaningToggleStore(),
            analyzer: InstantEpisodeAnalyzer(),
            autoAnalyzeOnEpisodeEnable: true
        )
        if showsTimeline {
            analysisViewModel.primeEpisodeCleaningToggle(episodeID: episode.id)
            XCTAssertTrue(analysisViewModel.episodeRowShowsTimeline(episodeID: episode.id))
        }

        return EpisodeTableViewCellLayoutTesting.makeConfiguredCell(
            episode: episode,
            index: 0,
            analysisViewModel: analysisViewModel,
            downloadManager: downloadManager,
            isQueued: false
        )
    }
}
