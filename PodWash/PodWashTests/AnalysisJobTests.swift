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

    func testAnalysisNeverDisplaysMadeUpPercentOrDuration() {
        var value = job(id: "episode", stage: .transcribing)
        value.estimate = AnalysisJobEstimate(secondsRemaining: 95, progress: 0.42)
        let row = EpisodeRowPresentationMapper.map(value)
        XCTAssertEqual(row.statusText, "Preparing clean playback")
        XCTAssertEqual(row.primaryControl, .progress(nil))
    }

    func testRetryCountdownUsesInjectedClock() {
        let start = Date(timeIntervalSince1970: 1000)
        var value = job(id: "episode", stage: .adCheckDelayed)
        value.retryAfter = start.addingTimeInterval(125)
        XCTAssertEqual(EpisodeRowPresentationMapper.map(value, now: start).statusText,
                       "Ad check delayed · Retrying in ~2 min")
        XCTAssertEqual(EpisodeRowPresentationMapper.map(value, now: start.addingTimeInterval(126)).statusText,
                       "Ad check delayed · Retrying now")
    }

    func testLegacyTerminalJobResolvesToTypedFailureReason() {
        var value = job(id: "episode", stage: .needsAttention)
        value.detail = "Download failed"
        XCTAssertEqual(value.resolvedFailureReason, .downloadFailed)

        value.detail = "unrecognized old failure"
        value.cloudFailure = .invalidResponse
        XCTAssertEqual(value.resolvedFailureReason, .cloud(.invalidResponse))
    }

    func testPreparationIssuePresentationMapsSafeCopyAndActions() {
        let local = PreparationIssuePresentationMapper.map(PreparationIssue(
            episodeID: "episode", episodeTitle: "Episode", reason: .localPreparationFailed,
            hasVerifiedLocalAudio: true
        ))
        XCTAssertEqual(local.shortStatus, "Local preparation failed")
        XCTAssertEqual(local.diagnosticCode, "PW-PREP-LOCAL")
        XCTAssertTrue(local.allowsRetry)
        XCTAssertTrue(local.allowsOriginalPlayback)

        let noAudio = PreparationIssuePresentationMapper.map(PreparationIssue(
            episodeID: "episode", episodeTitle: "Episode", reason: .noDownloadableAudio,
            hasVerifiedLocalAudio: false
        ))
        XCTAssertEqual(noAudio.diagnosticCode, "PW-PREP-NO-AUDIO")
        XCTAssertFalse(noAudio.allowsRetry)
        XCTAssertFalse(noAudio.allowsOriginalPlayback)

        let cloud = PreparationIssuePresentationMapper.map(PreparationIssue(
            episodeID: "episode", episodeTitle: "Episode", reason: .cloud(.invalidResponse),
            hasVerifiedLocalAudio: true
        ))
        XCTAssertEqual(cloud.diagnosticCode, "PW-PREP-CLOUD-INVALID-RESPONSE")
        XCTAssertTrue(cloud.allowsOriginalPlayback)
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
