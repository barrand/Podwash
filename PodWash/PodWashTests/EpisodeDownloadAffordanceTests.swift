//
//  EpisodeDownloadAffordanceTests.swift
//  PodWashTests
//
//  Task 024 — Distinguish download vs delete affordances (AC1–AC2).
//

import UIKit
import XCTest
@testable import PodWash

@MainActor
final class EpisodeDownloadAffordanceTests: XCTestCase {

    private static let fixtureEpisodeID = "fixture-ep-024"
    private static let layoutWidth: CGFloat = 390

    private var downloadsDirectory: URL!
    private var stateStore: InMemoryDownloadStateStore!
    private var downloadManager: DownloadManager!

    override func setUp() async throws {
        downloadsDirectory = FileManager.default.temporaryDirectory
            .appendingPathComponent("EpisodeDownloadAffordance-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: downloadsDirectory, withIntermediateDirectories: true)
        stateStore = InMemoryDownloadStateStore()
        downloadManager = DownloadManager(
            sessionConfiguration: .ephemeral,
            downloadsDirectory: downloadsDirectory,
            stateStore: stateStore
        )
    }

    override func tearDown() async throws {
        downloadManager = nil
        stateStore = nil
        if let downloadsDirectory {
            try? FileManager.default.removeItem(at: downloadsDirectory)
        }
        downloadsDirectory = nil
    }

    func testNotDownloadedUsesArrowDownCircleWithNonRedTint() {
        stateStore.setState(.notDownloaded, for: Self.fixtureEpisodeID)
        let cell = makeConfiguredCell()
        EpisodeTableViewCellLayoutTesting.layoutAtContentWidth(Self.layoutWidth, cell: cell)

        let downloadButton = EpisodeTableViewCellLayoutTesting.downloadButton(in: cell)
        XCTAssertEqual(
            downloadButton.image(for: .normal),
            UIImage(systemName: "arrow.down.circle"),
            "Not-downloaded affordance should use arrow.down.circle"
        )
        XCTAssertFalse(
            tintsEqual(downloadButton.tintColor, .systemRed),
            "Not-downloaded affordance tint should not be system red"
        )
    }

    func testDownloadedUsesTrashGlyphWithSystemRedTint() {
        stateStore.setState(.downloaded, for: Self.fixtureEpisodeID)
        let cell = makeConfiguredCell()
        EpisodeTableViewCellLayoutTesting.layoutAtContentWidth(Self.layoutWidth, cell: cell)

        let downloadButton = EpisodeTableViewCellLayoutTesting.downloadButton(in: cell)
        let image = downloadButton.image(for: .normal)
        let trash = UIImage(systemName: "trash")
        let trashFill = UIImage(systemName: "trash.fill")
        XCTAssertTrue(
            image == trash || image == trashFill,
            "Downloaded affordance should use trash or trash.fill"
        )
        XCTAssertNotEqual(image, UIImage(systemName: "trash.circle"))
        XCTAssertNotEqual(image, UIImage(systemName: "arrow.down.circle"))
        XCTAssertTrue(
            tintsEqual(downloadButton.tintColor, .systemRed),
            "Downloaded affordance tint should be system red"
        )
    }

    // MARK: - Helpers

    private func makeConfiguredCell() -> EpisodeTableViewCell {
        let episode = Episode(
            id: Self.fixtureEpisodeID,
            title: "Affordance Contrast Episode",
            pubDate: ISO8601DateFormatter().date(from: "2026-01-15T08:00:00Z")!,
            artworkURL: nil,
            showNotes: nil,
            audioURL: URL(string: "https://fixture.podwash.tests/audio/affordance.m4a")
        )
        let analysisViewModel = AnalysisUIViewModel(
            store: InMemoryCleaningToggleStore(),
            analyzer: InstantEpisodeAnalyzer(),
            autoAnalyzeOnEpisodeEnable: false
        )
        return EpisodeTableViewCellLayoutTesting.makeConfiguredCell(
            episode: episode,
            index: 0,
            analysisViewModel: analysisViewModel,
            downloadManager: downloadManager,
            isQueued: false
        )
    }

    private func tintsEqual(_ lhs: UIColor?, _ rhs: UIColor) -> Bool {
        guard let lhs else { return false }
        let traits = UITraitCollection(userInterfaceStyle: .light)
        return lhs.resolvedColor(with: traits).isEqual(rhs.resolvedColor(with: traits))
    }
}
