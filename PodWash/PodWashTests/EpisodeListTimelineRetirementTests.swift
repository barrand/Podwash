//
//  EpisodeListTimelineRetirementTests.swift
//  PodWashTests
//
//  Task 026 — Episode row no longer hosts analysis timeline chrome (AC4).
//

import XCTest
@testable import PodWash

@MainActor
final class EpisodeListTimelineRetirementTests: XCTestCase {

    private static let fixtureEpisodeID = "fixture-ep-026"
    private static let phoneLayoutWidth: CGFloat = 390

    private var downloadsDirectory: URL!
    private var downloadManager: DownloadManager!

    override func setUp() async throws {
        downloadsDirectory = FileManager.default.temporaryDirectory
            .appendingPathComponent("EpisodeListTimelineRetirement-\(UUID().uuidString)", isDirectory: true)
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

    func testAnalyzingConfigureOmitsTimelineAccessibilityHost() {
        let cell = makeAnalyzingConfiguredCell()

        EpisodeTableViewCellLayoutTesting.layoutAtContentWidth(Self.phoneLayoutWidth, cell: cell)

        let host = EpisodeTableViewCellLayoutTesting.timelineHost(in: cell)
        XCTAssertTrue(
            host.isHidden,
            "Analysis timeline host must stay hidden while episode row is analyzing"
        )
        XCTAssertEqual(
            host.bounds.height,
            0,
            accuracy: 0.5,
            "Analysis timeline host height must collapse when row timeline retires"
        )
        XCTAssertNil(
            host.accessibilityIdentifier,
            "Analyzing row must not publish analysisTimeline accessibility host"
        )
        XCTAssertFalse(
            host.isAccessibilityElement,
            "Timeline accessibility host must not be exposed on analyzing rows"
        )
    }

    // MARK: - Helpers

    private func makeAnalyzingConfiguredCell() -> EpisodeTableViewCell {
        let episode = Episode(
            id: Self.fixtureEpisodeID,
            title: "Timeline Retirement — Analyzing Row",
            pubDate: ISO8601DateFormatter().date(from: "2026-01-15T08:00:00Z")!,
            artworkURL: nil,
            showNotes: nil,
            audioURL: URL(string: "https://fixture.podwash.tests/audio/retirement.m4a")
        )

        let analysisViewModel = AnalysisUIViewModel(
            store: InMemoryCleaningToggleStore(),
            analyzer: InstantEpisodeAnalyzer(),
            autoAnalyzeOnEpisodeEnable: true
        )
        analysisViewModel.primeEpisodeCleaningToggle(episodeID: episode.id)
        XCTAssertTrue(
            analysisViewModel.episodeRowShowsTimeline(episodeID: episode.id),
            "Fixture must configure an analyzing snapshot before asserting retirement"
        )

        return EpisodeTableViewCellLayoutTesting.makeConfiguredCell(
            episode: episode,
            index: 0,
            analysisViewModel: analysisViewModel,
            downloadManager: downloadManager,
            isQueued: false
        )
    }
}
