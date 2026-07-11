//
//  CarPlayTemplateTests.swift
//  PodWashTests
//
//  Slice 15 — CarPlay library, show, queue, selection, now-playing, plist (ADR-016).
//  Maps AC#1–#6 from docs/slices/slice-15-carplay.md.
//
//  Golden library titles: hand-transcribed from Fixtures/itunes/itunes_popular_response.json
//  entries 0–1 (independent provenance; see Fixtures/itunes/README.md).
//  Golden episode titles: hand-transcribed from Fixtures/feeds/sample_feed.xml items 0–2.
//  Audio fixture: test-clip.m4a (30.0 s) per Fixtures/audio/test-clip.provenance.md (Slice 14).
//
//  AC4 uses EpisodePlayingSpy (ADR-009 §5) — not PlaybackTransporting (ADR-011).
//  Until CarPlay data sources, coordinator, updater, and presenting protocols exist
//  (Engineer), this file fails to compile — intended TDD red state.
//

import AVFoundation
import XCTest
@testable import PodWash

// MARK: - Test builder (CarPlayTemplateBuilding)

@MainActor
private final class CarPlayStoreTemplateBuilder: CarPlayTemplateBuilding {
    // nonisolated(unsafe): avoid MainActor TaskLocal hop when releasing in deinit
    // (XCTest teardown otherwise SIGABRT via swift_task_deinitOnExecutorImpl).
    nonisolated(unsafe) private let store: PodcastStore
    nonisolated(unsafe) private let queue: QueueStore

    init(store: PodcastStore, queue: QueueStore) {
        self.store = store
        self.queue = queue
    }

    // Avoid MainActor/TaskLocal deinit crash under SWIFT_DEFAULT_ACTOR_ISOLATION.
    nonisolated deinit {}

    func libraryListItems() -> [CarPlayListItemModel] {
        CarPlayLibraryDataSource(store: store).listItems()
    }

    func showListItems(subscriptionIndex: Int) -> [CarPlayListItemModel] {
        CarPlayShowDataSource(store: store, subscriptionIndex: subscriptionIndex).listItems()
    }

    func queueListItems() -> [CarPlayListItemModel] {
        CarPlayQueueDataSource(store: store, queue: queue).listItems()
    }
}

// MARK: - Tests

@MainActor
final class CarPlayTemplateTests: XCTestCase {

    // Hand-transcribed from itunes_popular_response.json entries 0–1 (Slice 22 golden).
    private let goldenLibraryTitle0 = "Fixture Popular Alpha"
    private let goldenLibraryTitle1 = "Fixture Popular Beta"

    // Hand-transcribed from sample_feed.xml items 0–2 (Slice 06 golden).
    private let goldenEpisodeTitle0 = "Alpha Signal — Pilot Launch"
    private let goldenEpisodeTitle1 = "Beta Notes — Listener Mail"
    private let goldenEpisodeTitle2 = "Gamma Graph — Data Deep Dive"

    private var harness: PersistenceReloadHarness!

    override func setUp() {
        super.setUp()
        harness = PersistenceReloadHarness()
    }

    override func tearDown() {
        harness = nil
        super.tearDown()
    }

    private func testClipURL(file: StaticString = #filePath, line: UInt = #line) -> URL {
        let bundle = Bundle(for: type(of: self))
        guard let bundledURL = bundle.url(forResource: "test-clip", withExtension: "m4a") else {
            XCTFail("Missing test-clip.m4a in \(bundle.bundlePath)", file: file, line: line)
            return URL(fileURLWithPath: "/dev/null")
        }

        let tempURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("podwash-carplay-test-clip.m4a")
        try? FileManager.default.removeItem(at: tempURL)
        do {
            try FileManager.default.copyItem(at: bundledURL, to: tempURL)
        } catch {
            XCTFail("Could not copy test-clip fixture: \(error)", file: file, line: line)
            return bundledURL
        }
        return tempURL
    }

    private func carPlaySceneConfigurationCount() -> Int {
        guard
            let manifest = Bundle.main.object(forInfoDictionaryKey: "UIApplicationSceneManifest") as? [String: Any],
            let configurations = manifest["UISceneConfigurations"] as? [String: Any]
        else {
            return 0
        }

        var count = 0
        for (_, value) in configurations {
            guard let scenes = value as? [[String: Any]] else { continue }
            for scene in scenes {
                if scene["UISceneClassName"] as? String == "CPTemplateApplicationScene" {
                    count += 1
                }
            }
        }
        return count
    }

    // MARK: - AC1: library list from subscriptions

    func testLibraryListItemsFromSubscriptions() throws {
        let persistence = harness.makeController()
        let store = PodcastStore(context: persistence.viewContext, retaining: persistence)
        try FixtureLibrary.prepareSeededStore(store)

        let dataSource = CarPlayLibraryDataSource(store: store)
        let items = dataSource.listItems()

        XCTAssertEqual(items.count, 2)
        XCTAssertEqual(items[0].text, goldenLibraryTitle0)
        XCTAssertEqual(items[1].text, goldenLibraryTitle1)
        XCTAssertEqual(items.filter { $0.image != nil }.count, 2)
    }

    // MARK: - AC2: show list for subscription index 0

    func testShowListItemsForSubscription() throws {
        let persistence = harness.makeController()
        let store = PodcastStore(context: persistence.viewContext, retaining: persistence)
        try FixtureLibrary.prepareSeededStore(store)

        let dataSource = CarPlayShowDataSource(store: store, subscriptionIndex: 0)
        let items = dataSource.listItems()

        XCTAssertEqual(items.count, 5)
        XCTAssertEqual(items[0].text, goldenEpisodeTitle0)
        XCTAssertEqual(items[1].text, goldenEpisodeTitle1)
    }

    // MARK: - AC3: queue list from QueueStore order

    func testQueueListItemsFromStore() throws {
        let persistence = harness.makeController()
        let store = PodcastStore(context: persistence.viewContext, retaining: persistence)
        let queue = QueueStore(context: persistence.viewContext)

        try FixtureFeedLoader.seedEpisodes(into: store)
        try queue.add("fixture-ep-001")
        try queue.add("fixture-ep-002")
        try queue.add("fixture-ep-003")

        let dataSource = CarPlayQueueDataSource(store: store, queue: queue)
        let items = dataSource.listItems()

        XCTAssertEqual(items.count, 3)
        XCTAssertEqual(
            items.map(\.text),
            [goldenEpisodeTitle0, goldenEpisodeTitle1, goldenEpisodeTitle2]
        )
        XCTAssertEqual(items.filter { $0.image != nil }.count, 3)
    }

    // MARK: - AC4: queue selection starts playback for fixture-ep-002

    func testQueueSelectionStartsPlayback() throws {
        let persistence = harness.makeController()
        let store = PodcastStore(context: persistence.viewContext, retaining: persistence)
        let queue = QueueStore(context: persistence.viewContext)

        try FixtureFeedLoader.seedEpisodes(into: store)
        try queue.add("fixture-ep-001")
        try queue.add("fixture-ep-002")
        try queue.add("fixture-ep-003")

        let player = EpisodePlayingSpy()
        let nowPlayingDouble = CPNowPlayingTemplateDouble()
        let url = testClipURL()
        let engine = PlaybackEngine(
            url: url,
            title: goldenEpisodeTitle0,
            artist: "PodWash QA",
            nowPlayingUpdater: NowPlayingInfoRecorder()
        )
        let updater = CarPlayNowPlayingUpdater(engine: engine, presenting: nowPlayingDouble)
        updater.attach()

        let builder = CarPlayStoreTemplateBuilder(store: store, queue: queue)
        let coordinator = CarPlayCoordinator(
            builder: builder,
            player: player,
            nowPlaying: updater
        )

        addTeardownBlock { [engine] in
            engine.pause()
        }

        coordinator.selectQueueItem(at: 1)

        XCTAssertEqual(player.playCalls.count, 1)
        XCTAssertEqual(player.playCalls[0].episodeID, "fixture-ep-002")
    }

    // MARK: - AC5: now-playing state + title propagation

    func testNowPlayingStatePropagation() throws {
        let nowPlayingDouble = CPNowPlayingTemplateDouble()
        let url = testClipURL()
        let engine = PlaybackEngine(
            url: url,
            title: goldenEpisodeTitle0,
            artist: "PodWash QA",
            nowPlayingUpdater: NowPlayingInfoRecorder()
        )
        let updater = CarPlayNowPlayingUpdater(engine: engine, presenting: nowPlayingDouble)
        updater.attach()

        addTeardownBlock { [engine] in
            engine.pause()
        }

        engine.play()

        XCTAssertEqual(nowPlayingDouble.playbackStateUpdates.last, .playing)
        XCTAssertEqual(nowPlayingDouble.lastTitle, goldenEpisodeTitle0)

        engine.pause()

        XCTAssertEqual(nowPlayingDouble.playbackStateUpdates, [.playing, .paused])
    }

    // MARK: - AC6: Info.plist declares exactly one CarPlay scene

    func testCarPlaySceneDeclaredInPlist() {
        let count = carPlaySceneConfigurationCount()
        XCTAssertEqual(
            count,
            1,
            "UIApplicationSceneManifest must contain exactly 1 CPTemplateApplicationScene configuration (found \(count))"
        )
    }
}
