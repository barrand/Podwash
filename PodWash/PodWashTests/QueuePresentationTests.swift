//
//  QueuePresentationTests.swift
//  PodWashTests
//

import XCTest
@testable import PodWash

final class QueuePresentationTests: XCTestCase {

    func testAvailabilityCopyUsesMeasuredDownloadProgressAndNoFabricatedDuration() {
        XCTAssertEqual(EpisodeReadinessStatus.preparing.text, "Preparing clean playback · On device")
        XCTAssertEqual(EpisodeReadinessStatus.checkingAds.text, "Checking for ads · On device")
        XCTAssertEqual(EpisodeReadinessStatus.downloading(progress: 0.5).text, "Downloading · 50%")
        XCTAssertEqual(EpisodeReadinessStatus.downloading(progress: 4).text, "Downloading · 100%")
        XCTAssertTrue(EpisodeReadinessStatus.preparing.showsIndeterminateProgress)
        XCTAssertFalse(EpisodeReadinessStatus.downloading(progress: 0.5).showsIndeterminateProgress)
    }

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
            availabilityByEpisodeID: [
                "queued": readyAvailability(),
                "playing": readyAvailability(),
                "played": readyAvailability(),
                "downloaded": readyAvailability(),
            ],
            foregroundJob: nil,
            pendingQueueActivationEpisodeID: nil
        )

        let presentation = QueuePresentationBuilder.build(input)
        XCTAssertEqual(presentation.upNext.map(\.episodeID), ["queued"])
        XCTAssertEqual(presentation.downloads.map(\.episodeID), ["downloaded"])
        XCTAssertEqual(presentation.downloadsSummary.text, "1 ready")
    }

    func testReadyJobWithoutLocalFileIsNeverShownAsReady() {
        let job = AnalysisJob(
            episodeID: "episode",
            title: "Episode",
            stage: .ready,
            estimate: AnalysisJobEstimate(secondsRemaining: nil, progress: nil),
            updatedAt: .now
        )

        let availability = EpisodeAvailabilityResolver.resolve(EpisodeAvailabilityInput(
            downloadState: .notDownloaded,
            hasVerifiedLocalFile: false,
            isAnalysisReady: true,
            durableJob: job,
            foregroundJob: nil
        ))

        XCTAssertEqual(availability.readiness, .waitingToDownload)
    }

    func testLocalAudioAndCompletedAnalysisAreReadyOfflineEvenWithStaleJob() {
        let staleJob = AnalysisJob(
            episodeID: "episode",
            title: "Episode",
            stage: .transcribing,
            estimate: AnalysisJobEstimate(secondsRemaining: nil, progress: nil),
            updatedAt: .now
        )

        let availability = EpisodeAvailabilityResolver.resolve(EpisodeAvailabilityInput(
            downloadState: .downloaded,
            hasVerifiedLocalFile: true,
            isAnalysisReady: true,
            durableJob: staleJob,
            foregroundJob: nil
        ))

        XCTAssertEqual(availability.readiness, .readyOffline)
        XCTAssertEqual(availability.readiness.text, "Ready to play offline")
    }

    func testDownloadedWithoutJobIsExplicitlyNotPrepared() {
        let availability = EpisodeAvailabilityResolver.resolve(EpisodeAvailabilityInput(
            downloadState: .downloaded,
            hasVerifiedLocalFile: true,
            isAnalysisReady: false,
            durableJob: nil,
            foregroundJob: nil
        ))

        XCTAssertEqual(availability.readiness, .downloadedNotPrepared)
    }

    private func readyAvailability() -> EpisodeAvailability {
        EpisodeAvailability(localAudio: .downloaded, preparation: .ready, readiness: .readyOffline)
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
