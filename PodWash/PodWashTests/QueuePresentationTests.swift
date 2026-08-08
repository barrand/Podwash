//
//  QueuePresentationTests.swift
//  PodWashTests
//

import XCTest
@testable import PodWash

final class QueuePresentationTests: XCTestCase {
    func testDownloadsExcludeNowPlayingPlayedAndManualQueue() {
        let input = QueuePresentationInput(
            manualQueueIDs: ["queued"],
            downloadedEpisodeIDs: ["queued", "playing", "played", "downloaded"],
            nowPlayingEpisodeID: "playing",
            metadataByEpisodeID: [
                "queued": metadata("queued"),
                "playing": metadata("playing"),
                "played": metadata("played", played: true),
                "downloaded": metadata("downloaded"),
            ],
            jobsByEpisodeID: [:],
            foregroundJob: nil
        )

        let presentation = QueuePresentationBuilder.build(input)
        XCTAssertEqual(presentation.upNext.map(\.episodeID), ["queued"])
        XCTAssertEqual(presentation.downloads.map(\.episodeID), ["downloaded"])
    }

    func testReadyJobProducesNoRowActivity() {
        let job = AnalysisJob(
            episodeID: "downloaded",
            title: "Downloaded",
            stage: .ready,
            estimate: AnalysisJobEstimate(secondsRemaining: nil, progress: nil),
            updatedAt: .now
        )
        let input = QueuePresentationInput(
            manualQueueIDs: ["downloaded"],
            downloadedEpisodeIDs: ["downloaded"],
            nowPlayingEpisodeID: nil,
            metadataByEpisodeID: ["downloaded": metadata("downloaded")],
            jobsByEpisodeID: ["downloaded": job],
            foregroundJob: nil
        )

        XCTAssertNil(QueuePresentationBuilder.build(input).upNext.first?.activity)
    }

    private func metadata(_ id: String, played: Bool = false) -> QueueEpisodeMetadata {
        QueueEpisodeMetadata(
            episodeID: id,
            title: id,
            podcastTitle: "Podcast",
            publicationDate: Date(timeIntervalSince1970: 1),
            isPlayed: played
        )
    }
}
