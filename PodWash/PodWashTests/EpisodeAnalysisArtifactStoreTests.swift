import XCTest
@testable import PodWash

final class EpisodeAnalysisArtifactStoreTests: XCTestCase {
    private var root: URL!
    private var defaults: UserDefaults!
    private var store: EpisodeAnalysisArtifactStore!

    override func setUp() {
        super.setUp()
        root = FileManager.default.temporaryDirectory.appendingPathComponent("ArtifactStore-\(UUID().uuidString)", isDirectory: true)
        let suite = "com.podwash.tests.artifacts.\(UUID().uuidString)"
        defaults = UserDefaults(suiteName: suite)!
        defaults.removePersistentDomain(forName: suite)
        store = EpisodeAnalysisArtifactStore(baseDirectory: root.appendingPathComponent("artifacts"), defaults: defaults)
    }

    override func tearDown() {
        try? FileManager.default.removeItem(at: root)
        store = nil
        defaults = nil
        root = nil
        super.tearDown()
    }

    func testRoundTripAndRemoval() throws {
        let artifact = EpisodeAnalysisArtifact(
            episodeID: "episode-1",
            adSpans: [ContentSegment(start: 12, end: 30)],
            analysisFingerprint: "v1",
            completedAt: Date(timeIntervalSince1970: 100)
        )
        try store.store(artifact)
        XCTAssertEqual(store.load(episodeID: "episode-1"), artifact)
        try store.remove(episodeID: "episode-1")
        XCTAssertNil(store.load(episodeID: "episode-1"))
    }

    func testMigrationRetainsOnlyCompletedAdSpans() throws {
        let cache = IntervalCache(baseDirectory: root.appendingPathComponent("intervals"))
        try cache.store([
            CensorInterval(start: 1, end: 2, action: .mute, source: .profanity),
            CensorInterval(start: 10, end: 20, action: .skip, source: .unrelatedContent),
        ], episodeID: "episode-1", targetWords: ["damn"])
        try cache.store([
            CensorInterval(start: 30, end: 40, action: .skip, source: .unrelatedContent),
        ], episodeID: "episode-2", targetWords: ["damn"], analysisCompleted: false)

        store.migrateLegacyArtifactsIfNeeded(intervalCache: cache)

        XCTAssertEqual(store.load(episodeID: "episode-1")?.adSpans, [ContentSegment(start: 10, end: 20)])
        XCTAssertNil(store.load(episodeID: "episode-2"))
    }
}
