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
