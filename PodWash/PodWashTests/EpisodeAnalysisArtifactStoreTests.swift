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

    func testRejectsArtifactFromOldPipeline() throws {
        let artifact = EpisodeAnalysisArtifact(
            episodeID: "episode-1",
            adSpans: [ContentSegment(start: 10, end: 20)],
            analysisFingerprint: "legacy",
            completedAt: Date(),
            schemaVersion: 1,
            pipelineVersion: "cloud-gemini-v1"
        )
        try store.store(artifact)
        XCTAssertNil(store.load(episodeID: "episode-1"))
    }

    func testRoundTripPreservesTypedReasons() throws {
        let segment = ContentSegment(
            start: 10,
            end: 20,
            startSentenceID: 4,
            endSentenceID: 7,
            reasons: [.paidAd, .underwriting]
        )
        try store.store(EpisodeAnalysisArtifact(
            episodeID: "episode-typed",
            adSpans: [segment],
            analysisFingerprint: "typed",
            completedAt: Date()
        ))
        XCTAssertEqual(store.load(episodeID: "episode-typed")?.segments, [segment])
    }
}
