import XCTest
@testable import PodWash

final class BackgroundActivityTests: XCTestCase {
    func testIdleQueueAndCompletedWorkLeaveNoStrip() {
        for stage in [AnalysisJobStage.queued, .ready, .adCheckDelayed, .downloading] {
            XCTAssertNil(resolve(jobs: [job("idle", stage)]), "\(stage) must not invent running work")
        }
        XCTAssertNil(resolve())
    }

    func testDownloadOutsideManualQueueShowsMeasuredProgress() throws {
        let activity = try XCTUnwrap(resolve(downloads: [download("outside-queue", 0.42)]))
        XCTAssertEqual(activity.episodeID, "outside-queue")
        XCTAssertEqual(activity.text, "Downloading · 42%: Title outside-queue")
        XCTAssertFalse(activity.isFailure)
    }

    func testDownloadProgressIsClampedAndNeverInvented() throws {
        for (progress, expected) in [(Double(-1), "0%"), (4, "100%"), (0.425, "43%")] {
            XCTAssertEqual(resolve(downloads: [download("a", progress)])?.status, "Downloading · \(expected)")
        }
        XCTAssertEqual(resolve(downloads: [download("a", .nan)])?.status, "Downloading")
        XCTAssertEqual(resolve(downloads: [download("a", .infinity)])?.status, "Downloading")
    }

    func testPreparationAndAdChecksDoNotShowMadeUpPercentages() {
        XCTAssertEqual(resolve(jobs: [job("a", .transcribing)])?.text, "Preparing: Title a")
        XCTAssertEqual(resolve(jobs: [job("a", .checkingAds)])?.text, "Checking for ads: Title a")
    }

    func testForegroundTakesPriorityAndDuplicateWorkIsCountedOnce() throws {
        let activity = try XCTUnwrap(resolve(
            foreground: job("z", .checkingAds),
            jobs: [job("z", .transcribing), job("a", .transcribing)],
            downloads: [download("b", 0.1)], refreshing: true))
        XCTAssertEqual(activity.episodeID, "z")
        XCTAssertEqual(activity.status, "Checking for ads")
        XCTAssertEqual(activity.additionalCount, 3)
        XCTAssertTrue(activity.accessibilityLabel.hasSuffix("3 more activities"))
    }

    func testActualDownloadSupersedesOldCheckpointWithoutDoubleCounting() throws {
        let activity = try XCTUnwrap(resolve(jobs: [job("a", .needsAttention)], downloads: [download("a", 0.2)]))
        XCTAssertEqual(activity.status, "Downloading · 20%")
        XCTAssertEqual(activity.additionalCount, 0)
        XCTAssertFalse(activity.isFailure)
    }

    func testCompletedForegroundDoesNotHideNewBackgroundPreparationForSameEpisode() {
        XCTAssertEqual(resolve(foreground: job("a", .ready), jobs: [job("a", .transcribing)])?.status, "Preparing")
    }

    func testFailureOffersRecoveryBeforeOtherWork() throws {
        let activity = try XCTUnwrap(resolve(foreground: job("a", .checkingAds), jobs: [job("z", .needsAttention)]))
        XCTAssertTrue(activity.isFailure)
        XCTAssertEqual(activity.episodeID, "z")
        XCTAssertEqual(activity.additionalCount, 1)
    }

    func testDismissalRevealsRunningWorkAndDoesNotSuppressNewFailure() throws {
        var failure = job("a", .needsAttention)
        failure.failureReason = .downloadFailed
        let initial = try XCTUnwrap(resolve(jobs: [failure]))
        XCTAssertEqual(initial.status, "Download failed")
        let dismissed: Set<String> = [try XCTUnwrap(initial.failureID)]
        XCTAssertNil(resolve(jobs: [failure], dismissed: dismissed))
        XCTAssertEqual(resolve(jobs: [failure, job("b", .transcribing)], dismissed: dismissed)?.episodeID, "b")
        failure.updatedAt = failure.updatedAt.addingTimeInterval(1)
        XCTAssertTrue(try XCTUnwrap(resolve(jobs: [failure], dismissed: dismissed)).isFailure)
    }

    func testActivityOrderIsStableAcrossDictionaryAndProgressUpdates() {
        let jobs = [job("z", .transcribing), job("a", .checkingAds)]
        XCTAssertEqual(resolve(jobs: jobs), resolve(jobs: jobs.reversed()))
        XCTAssertEqual(resolve(jobs: jobs, downloads: [download("b", 0.1)])?.episodeID,
                       resolve(jobs: jobs, downloads: [download("b", 0.9)])?.episodeID)
    }

    func testActivityLifecycleReturnsToZeroSpaceAfterCompletionOrCancellation() {
        XCTAssertNotNil(resolve(downloads: [download("a", 0)]))
        XCTAssertNotNil(resolve(jobs: [job("a", .transcribing)]))
        XCTAssertNotNil(resolve(jobs: [job("a", .checkingAds)]))
        XCTAssertNil(resolve(jobs: [job("a", .ready)]))
        XCTAssertNil(resolve())
    }

    func testFeedRefreshAppearsWithoutPlaybackAndDisappearsWhenFinished() {
        XCTAssertEqual(resolve(refreshing: true)?.text, "Refreshing podcasts")
        XCTAssertNil(resolve(refreshing: false))
    }

    private func job(_ id: String, _ stage: AnalysisJobStage) -> AnalysisJob {
        AnalysisJob(episodeID: id, title: "Title \(id)", stage: stage,
                    estimate: AnalysisJobEstimate(secondsRemaining: nil, progress: nil),
                    updatedAt: Date(timeIntervalSince1970: 100))
    }

    private func download(_ id: String, _ progress: Double) -> ActivityDownload {
        ActivityDownload(episodeID: id, title: "Title \(id)", progress: progress)
    }

    private func resolve(foreground: AnalysisJob? = nil, jobs: [AnalysisJob] = [],
                         downloads: [ActivityDownload] = [], refreshing: Bool = false,
                         dismissed: Set<String> = []) -> BackgroundActivityPresentation? {
        BackgroundActivityResolver.resolve(foreground: foreground, ownedJobs: jobs, downloads: downloads,
            isRefreshingFeeds: refreshing, dismissedFailureIDs: dismissed)
    }
}
