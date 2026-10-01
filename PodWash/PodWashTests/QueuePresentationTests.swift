//
//  QueuePresentationTests.swift
//  PodWashTests
//

import XCTest
@testable import PodWash

final class QueuePresentationTests: XCTestCase {

    func testCopyUsesOnlyMeasuredDownloadProgress() {
        XCTAssertEqual(EpisodeRowPresentationMapper.map(.preparing).statusText, "Preparing clean playback")
        XCTAssertEqual(EpisodeRowPresentationMapper.map(.checkingAds).statusText, "Checking for ads")
        XCTAssertEqual(EpisodeRowPresentationMapper.map(.downloading(progress: 0.5)).statusText, "Downloading · 50%")
        XCTAssertEqual(EpisodeRowPresentationMapper.map(.downloading(progress: 4)).progress, 1)
    }

    func testQueuePreservesAllManualMembershipWithoutInventingDownloadsCollection() {
        let input = QueuePresentationInput(manualQueueIDs: ["third", "first", "second"],
            metadataByEpisodeID: ["first": metadata("first"), "second": metadata("second"), "third": metadata("third")],
            availabilityByEpisodeID: ["first": readyAvailability()],
            foregroundJob: nil)
        XCTAssertEqual(QueuePresentationBuilder.build(input).upNext.map(\.episodeID), ["third", "first", "second"])
    }

    func testStaleReadyJobWithoutLocalFileIsShownAsNotDownloaded() {
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

        XCTAssertEqual(availability.readiness, .notDownloaded)
    }

    func testActivePreparationOwnerWithoutLocalFileIsWaitingToDownload() {
        let availability = EpisodeAvailabilityResolver.resolve(EpisodeAvailabilityInput(
            downloadState: .notDownloaded,
            hasVerifiedLocalFile: false,
            isAnalysisReady: false,
            durableJob: nil,
            foregroundJob: nil,
            hasActiveWorkOwner: true
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
        XCTAssertEqual(EpisodeRowPresentationMapper.map(availability).statusText, "Ready to play offline")
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
