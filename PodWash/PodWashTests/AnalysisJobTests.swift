import XCTest
@testable import PodWash

final class AnalysisJobTests: XCTestCase {
    func testJobStoreRoundTripsRecoveryCheckpoint() {
        let suite = "AnalysisJobTests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        let store = AnalysisJobStore(defaults: defaults)
        let job = AnalysisJob(
            episodeID: "episode-1",
            title: "Episode one",
            stage: .adCheckDelayed,
            estimate: AnalysisJobEstimate(secondsRemaining: nil, progress: nil),
            updatedAt: Date(timeIntervalSince1970: 1),
            retryAfter: Date(timeIntervalSince1970: 31),
            detail: "Retrying automatically"
        )

        store.save([job.episodeID: job])

        XCTAssertEqual(store.load()[job.episodeID], job)
        XCTAssertFalse(job.isReadyForAutomaticPlayback)
        XCTAssertTrue(job.isDelayed)
    }

    func testReadyIsTheOnlyAutomaticHandoffState() {
        XCTAssertTrue(AnalysisJobStage.ready.userLabel == "Ready")
        XCTAssertFalse(AnalysisJobStage.adCheckDelayed.userLabel.isEmpty)
    }

    func testActivePreparationCopyUsesOneHonestRoughDuration() {
        XCTAssertEqual(
            AnalysisJobStage.transcribing.listenerStatus,
            "Preparing clean playback · Usually a few minutes"
        )
        XCTAssertEqual(
            AnalysisJobStage.checkingAds.listenerStatus,
            "Checking for ads · Usually a few minutes"
        )
        XCTAssertEqual(
            PreparationStatusCopy.downloading(progress: 0.42),
            "Downloading 42% · Usually a few minutes"
        )
        XCTAssertEqual(AnalysisJobStage.queued.listenerStatus, "Waiting to prepare")
        XCTAssertEqual(AnalysisJobStage.ready.listenerStatus, "Ready")
        XCTAssertEqual(AnalysisJobStage.adCheckDelayed.listenerStatus, "Ad check delayed")
        XCTAssertEqual(AnalysisJobStage.needsAttention.listenerStatus, "Needs attention")
    }

    func testQueueDisplayPlacesReadyJobsFirstWithoutReorderingEitherGroup() {
        let jobs = [
            job(id: "preparing-first", stage: .checkingAds),
            job(id: "ready-first", stage: .ready),
            job(id: "preparing-second", stage: .downloading),
            job(id: "ready-second", stage: .ready)
        ]

        XCTAssertEqual(
            AnalysisJob.orderedForQueueDisplay(jobs).map(\.episodeID),
            ["ready-first", "ready-second", "preparing-first", "preparing-second"]
        )
    }

    func testCompactShelfStatusUsesFourStepsAndMeasuredProgress() {
        let job = AnalysisJob(
            episodeID: "episode-1",
            title: "Episode one",
            stage: .transcribing,
            estimate: AnalysisJobEstimate(secondsRemaining: 95, progress: 0.42),
            updatedAt: Date(timeIntervalSince1970: 1),
            retryAfter: nil,
            detail: nil
        )

        XCTAssertEqual(job.compactShelfStatus(), "3/4 Preparing clean playback · 42% · ~2 min left")
    }

    func testCompactShelfStatusShowsElapsedAndRetryTimingWithoutFalseETA() {
        let start = Date(timeIntervalSince1970: 1_000)
        var job = AnalysisJob(
            episodeID: "episode-1",
            title: "Episode one",
            stage: .checkingAds,
            estimate: AnalysisJobEstimate(secondsRemaining: nil, progress: nil),
            updatedAt: start,
            retryAfter: nil,
            detail: nil
        )

        XCTAssertEqual(job.compactShelfStatus(now: start.addingTimeInterval(18)), "4/4 Checking for ads · 18s elapsed")

        job.stage = .adCheckDelayed
        job.retryAfter = start.addingTimeInterval(125)
        XCTAssertEqual(job.compactShelfStatus(now: start), "4/4 Ad check delayed · retrying in ~2 min")
    }

    private func job(id: String, stage: AnalysisJobStage) -> AnalysisJob {
        AnalysisJob(
            episodeID: id,
            title: id,
            stage: stage,
            estimate: AnalysisJobEstimate(secondsRemaining: nil, progress: nil),
            updatedAt: Date(timeIntervalSince1970: 1),
            retryAfter: nil,
            detail: nil
        )
    }
}
