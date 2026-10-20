import XCTest
@testable import PodWash

final class UpcomingPlaybackPlanTests: XCTestCase {
    private let feed = URL(string: "https://example.com/feed.xml")!

    func testPlanKeepsManualOrderThenShowsTwoDeduplicatedAutoplayEpisodes() {
        let plan = UpcomingSelectionPolicy().playbackPlan(
            manualQueueIDs: ["manual-2", "manual-1", "manual-2"],
            autoplay: [item("manual-1"), item("auto-1"), item("auto-2")],
            smartAutoplayEnabled: true
        )

        XCTAssertEqual(plan.manualEpisodeIDs, ["manual-2", "manual-1"])
        XCTAssertEqual(plan.autoplay.map(\.episodeID), ["auto-1", "auto-2"])
        XCTAssertEqual(plan.preparationEpisodeIDs, ["manual-2", "manual-1"])
    }

    func testPlanUsesAutoplayToFillTheTwoItemPreparationWindow() {
        let plan = UpcomingSelectionPolicy().playbackPlan(
            manualQueueIDs: ["manual"],
            autoplay: [item("auto-1"), item("auto-2")],
            smartAutoplayEnabled: true
        )

        XCTAssertEqual(plan.preparationEpisodeIDs, ["manual", "auto-1"])
    }

    func testSmartAutoplayOffRemovesForecastWithoutChangingManualQueue() {
        let plan = UpcomingSelectionPolicy().playbackPlan(
            manualQueueIDs: ["manual"], autoplay: [item("auto-1")], smartAutoplayEnabled: false
        )

        XCTAssertEqual(plan.manualEpisodeIDs, ["manual"])
        XCTAssertTrue(plan.autoplay.isEmpty)
    }

    private func item(_ id: String) -> ComingUpItem {
        ComingUpItem(episodeID: id, episodeTitle: id, podcastTitle: "Podcast", feedURL: feed, isBinge: false)
    }
}
