//
//  AppShellModelSmartAutoplayTests.swift
//  PodWashTests
//
//  ADR-029 — Shell wiring: Coming up, smart off, preparing, skip dismiss,
//  end-of-episode advance, binge enter, cleaning-off eligibility.
//

import AVFoundation
import XCTest
@testable import PodWash

@MainActor
final class AppShellModelSmartAutoplayTests: XCTestCase {

    private var harness: PersistenceReloadHarness!
    private var downloadsDirectory: URL!

    private let feedA = URL(string: "https://example.com/show-a.xml")!
    private let feedB = URL(string: "https://example.com/show-b.xml")!
    private let feedSerial = URL(string: "https://example.com/serial.xml")!

    override func setUp() {
        super.setUp()
        harness = PersistenceReloadHarness()
        downloadsDirectory = FileManager.default.temporaryDirectory
            .appendingPathComponent("smart-shell-\(UUID().uuidString)", isDirectory: true)
        try? FileManager.default.createDirectory(at: downloadsDirectory, withIntermediateDirectories: true)
    }

    override func tearDown() {
        try? FileManager.default.removeItem(at: downloadsDirectory)
        harness = nil
        super.tearDown()
    }

    // MARK: - Coming up

    func testComingUpPopulatesAfterPlayWhenQueueEmpty() throws {
        let persistence = harness.makeController()
        try seedTwoShows(persistence: persistence)
        try turnCleaningOff(persistence: persistence, feeds: [feedA, feedB])
        try installLocalDownload(for: "a-1")
        try installLocalDownload(for: "b-1")

        let model = makeShell(persistence: persistence)
        model.settingsStore.smartAutoplayEnabled = true

        guard let episode = model.podcastStore.episodeLookup(id: "a-1") else {
            return XCTFail("missing a-1")
        }
        model.playEpisode(episode.episode, podcastTitle: episode.podcastTitle, feedURL: episode.feedURL)

        XCTAssertFalse(model.comingUpItems.isEmpty, "Coming up should peek next shows")
        XCTAssertEqual(model.comingUpItems.first?.episodeID, "b-1")
        model.stopAndDismissPlayer()
    }

    func testComingUpClearedWhenManualQueueNonEmpty() throws {
        let persistence = harness.makeController()
        try seedTwoShows(persistence: persistence)
        try turnCleaningOff(persistence: persistence, feeds: [feedA, feedB])
        try installLocalDownload(for: "a-1")

        let model = makeShell(persistence: persistence)
        model.settingsStore.smartAutoplayEnabled = true
        try model.queueStore.add("b-1")

        guard let episode = model.podcastStore.episodeLookup(id: "a-1") else {
            return XCTFail("missing a-1")
        }
        model.playEpisode(episode.episode, podcastTitle: episode.podcastTitle, feedURL: episode.feedURL)

        XCTAssertTrue(
            model.comingUpItems.isEmpty,
            "Manual Up Next wins — Coming up stays empty"
        )
        model.stopAndDismissPlayer()
    }

    // MARK: - Smart off / preparing

    func testSmartAutoplayOffStopsAdvance() throws {
        let persistence = harness.makeController()
        try seedTwoShows(persistence: persistence)
        try turnCleaningOff(persistence: persistence, feeds: [feedA, feedB])
        try installLocalDownload(for: "a-1")

        let model = makeShell(persistence: persistence)
        model.settingsStore.smartAutoplayEnabled = false

        guard let episode = model.podcastStore.episodeLookup(id: "a-1") else {
            return XCTFail("missing a-1")
        }
        model.playEpisode(episode.episode, podcastTitle: episode.podcastTitle, feedURL: episode.feedURL)

        let next = model.queueCoordinator?.resolveSmartNext?("a-1", false)
        XCTAssertNil(next)
        model.stopAndDismissPlayer()
    }

    func testPreparingNextWhenWarmMiss() throws {
        let persistence = harness.makeController()
        try seedTwoShows(persistence: persistence)
        // Cleaning ON for B, no local file / cache → not ready.
        try turnCleaningOff(persistence: persistence, feeds: [feedA])
        try modelCleaningOn(persistence: persistence, feed: feedB, enabled: true)
        try installLocalDownload(for: "a-1")
        // b-1 intentionally not downloaded / not analyzed.

        let model = makeShell(persistence: persistence)
        model.settingsStore.smartAutoplayEnabled = true

        guard let episode = model.podcastStore.episodeLookup(id: "a-1") else {
            return XCTFail("missing a-1")
        }
        model.playEpisode(episode.episode, podcastTitle: episode.podcastTitle, feedURL: episode.feedURL)

        let nextID = model.queueCoordinator?.resolveSmartNext?("a-1", false)
        XCTAssertEqual(nextID, "b-1")
        XCTAssertTrue(model.isPreparingNextEpisode)
        XCTAssertEqual(model.preparingNextAnnouncement, "Preparing Show B")
        model.stopAndDismissPlayer()
    }

    // MARK: - Skip dismiss

    func testSkipToNextShowDismissesEpisodeForever() throws {
        let persistence = harness.makeController()
        try seedTwoShows(persistence: persistence)
        try turnCleaningOff(persistence: persistence, feeds: [feedA, feedB])
        try installLocalDownload(for: "a-1")
        try installLocalDownload(for: "b-1")

        let model = makeShell(persistence: persistence)
        model.settingsStore.smartAutoplayEnabled = true

        guard let episode = model.podcastStore.episodeLookup(id: "a-1") else {
            return XCTFail("missing a-1")
        }
        model.playEpisode(episode.episode, podcastTitle: episode.podcastTitle, feedURL: episode.feedURL)
        model.startPlaybackWhenReady()

        model.skipToNextShow()

        waitUntil(timeout: 3.0) {
            model.nowPlayingEpisodeID == "b-1"
                || model.podcastStore.isDismissedFromAutoplay(episodeID: "a-1")
        }

        XCTAssertTrue(model.podcastStore.isDismissedFromAutoplay(episodeID: "a-1"))
        model.stopAndDismissPlayer()
    }

    // MARK: - End advance

    func testPlaybackEndedAdvancesToSmartNextViaPlayEpisode() throws {
        let persistence = harness.makeController()
        try seedTwoShows(persistence: persistence)
        try turnCleaningOff(persistence: persistence, feeds: [feedA, feedB])
        try installLocalDownload(for: "a-1")
        try installLocalDownload(for: "b-1")

        let model = makeShell(persistence: persistence)
        model.settingsStore.smartAutoplayEnabled = true

        guard let episode = model.podcastStore.episodeLookup(id: "a-1") else {
            return XCTFail("missing a-1")
        }
        model.playEpisode(episode.episode, podcastTitle: episode.podcastTitle, feedURL: episode.feedURL)
        model.startPlaybackWhenReady()
        XCTAssertEqual(model.nowPlayingEpisodeID, "a-1")

        // Simulate AVPlayerItemDidPlayToEndTime → engine callback.
        model.engine?.onPlaybackEnded?()

        waitUntil(timeout: 3.0) {
            model.nowPlayingEpisodeID == "b-1"
        }
        XCTAssertEqual(model.nowPlayingEpisodeID, "b-1")
        model.stopAndDismissPlayer()
    }

    // MARK: - Binge + cleaning-off

    func testManualOpenOfBingeShowEntersBingeInComingUp() throws {
        let persistence = harness.makeController()
        try seedBingeAndEpisodic(persistence: persistence)
        try turnCleaningOff(persistence: persistence, feeds: [feedSerial, feedA])
        try installLocalDownload(for: "s-1")
        try installLocalDownload(for: "s-2")
        try installLocalDownload(for: "a-1")

        let model = makeShell(persistence: persistence)
        model.settingsStore.smartAutoplayEnabled = true
        try model.podcastStore.setBinge(true, feedURL: feedSerial)

        guard let episode = model.podcastStore.episodeLookup(id: "s-1") else {
            return XCTFail("missing s-1")
        }
        model.playEpisode(episode.episode, podcastTitle: episode.podcastTitle, feedURL: episode.feedURL)

        XCTAssertFalse(model.comingUpItems.isEmpty)
        XCTAssertEqual(model.comingUpItems.first?.episodeID, "s-2")
        XCTAssertTrue(model.comingUpItems.first?.isBinge == true)
        model.stopAndDismissPlayer()
    }

    func testCleaningOffShowStillEligibleInSmartOrderCatalog() throws {
        let persistence = harness.makeController()
        try seedTwoShows(persistence: persistence)
        try turnCleaningOff(persistence: persistence, feeds: [feedA, feedB])

        let shows = PodcastStore(context: persistence.viewContext).smartOrderShows()
        let engine = SmartOrderEngine()
        let next = engine.nextEpisode(
            shows: shows,
            currentEpisodeID: "a-1",
            currentFeedURL: feedA
        )
        XCTAssertEqual(next?.episodeID, "b-1")
    }

    // MARK: - Helpers

    private func seedTwoShows(persistence: PersistenceController) throws {
        let store = PodcastStore(context: persistence.viewContext)
        try store.save(
            PodcastFeed(
                title: "Show A",
                artworkURL: nil,
                description: nil,
                episodes: [
                    Episode(
                        id: "a-1",
                        title: "A latest",
                        pubDate: Date(timeIntervalSince1970: 200),
                        artworkURL: nil,
                        showNotes: nil,
                        audioURL: URL(string: "https://fixture.podwash.tests/audio/a1.m4a")
                    ),
                ]
            ),
            feedURL: feedA
        )
        try store.save(
            PodcastFeed(
                title: "Show B",
                artworkURL: nil,
                description: nil,
                episodes: [
                    Episode(
                        id: "b-1",
                        title: "B latest",
                        pubDate: Date(timeIntervalSince1970: 300),
                        artworkURL: nil,
                        showNotes: nil,
                        audioURL: URL(string: "https://fixture.podwash.tests/audio/b1.m4a")
                    ),
                ]
            ),
            feedURL: feedB
        )
        try store.touchLastHeard(feedURL: feedA, at: Date(timeIntervalSince1970: 500))
        try store.touchLastHeard(feedURL: feedB, at: Date(timeIntervalSince1970: 100))
    }

    private func seedBingeAndEpisodic(persistence: PersistenceController) throws {
        let store = PodcastStore(context: persistence.viewContext)
        try store.save(
            PodcastFeed(
                title: "Serial",
                artworkURL: nil,
                description: nil,
                episodes: [
                    Episode(
                        id: "s-1",
                        title: "S1",
                        pubDate: Date(timeIntervalSince1970: 100),
                        artworkURL: nil,
                        showNotes: nil,
                        audioURL: URL(string: "https://fixture.podwash.tests/audio/s1.m4a")
                    ),
                    Episode(
                        id: "s-2",
                        title: "S2",
                        pubDate: Date(timeIntervalSince1970: 200),
                        artworkURL: nil,
                        showNotes: nil,
                        audioURL: URL(string: "https://fixture.podwash.tests/audio/s2.m4a")
                    ),
                ]
            ),
            feedURL: feedSerial
        )
        try store.save(
            PodcastFeed(
                title: "Show A",
                artworkURL: nil,
                description: nil,
                episodes: [
                    Episode(
                        id: "a-1",
                        title: "A",
                        pubDate: Date(timeIntervalSince1970: 300),
                        artworkURL: nil,
                        showNotes: nil,
                        audioURL: URL(string: "https://fixture.podwash.tests/audio/a1.m4a")
                    ),
                ]
            ),
            feedURL: feedA
        )
    }

    private func turnCleaningOff(persistence: PersistenceController, feeds: [URL]) throws {
        let cleaning = CleaningToggleStore(context: persistence.viewContext)
        for feed in feeds {
            try cleaning.setChannelCleaning(forFeedURL: feed, enabled: false)
        }
    }

    private func modelCleaningOn(persistence: PersistenceController, feed: URL, enabled: Bool) throws {
        let cleaning = CleaningToggleStore(context: persistence.viewContext)
        try cleaning.setChannelCleaning(forFeedURL: feed, enabled: enabled)
    }

    private func installLocalDownload(for episodeID: String) throws {
        guard let source = FixtureAudio.bundledURL(in: Bundle.main) else {
            // Fallback tiny file so cleaning-off play path still has a local URL.
            let destination = DownloadPaths.localFileURL(
                episodeID: episodeID,
                downloadsDirectory: downloadsDirectory
            )
            try Data([0x00, 0x01, 0x02, 0x03]).write(to: destination)
            return
        }
        let destination = DownloadPaths.localFileURL(
            episodeID: episodeID,
            downloadsDirectory: downloadsDirectory
        )
        try? FileManager.default.removeItem(at: destination)
        try FileManager.default.copyItem(at: source, to: destination)
    }

    private func makeShell(persistence: PersistenceController) -> AppShellModel {
        let commands = RemoteCommandCoordinator(commands: MPRemoteCommandCenterAdapter())
        let context = persistence.viewContext
        let downloadConfig = URLSessionConfiguration.ephemeral
        downloadConfig.protocolClasses = [StubDownloadURLProtocol.self]
        let testDownloadManager = DownloadManager(
            sessionConfiguration: downloadConfig,
            downloadsDirectory: downloadsDirectory,
            stateStore: InMemoryDownloadStateStore(
                backing: DownloadStateStore(context: context)
            )
        )
        let model = AppShellModel(
            persistence: persistence,
            remoteCommands: commands,
            episodeAnalyzer: InstantEpisodeAnalyzer(),
            settingsStore: makeIsolatedSettingsStore(),
            fixtureLibraryModeForTesting: false,
            downloadManager: testDownloadManager
        )
        model.downloadsDirectoryForTesting = downloadsDirectory
        return model
    }

    private func makeIsolatedSettingsStore() -> SettingsStore {
        let suite = "com.podwash.tests.smart-shell.\(UUID().uuidString)"
        guard let defaults = UserDefaults(suiteName: suite) else {
            XCTFail("Could not create isolated UserDefaults suite")
            return SettingsStore()
        }
        defaults.removePersistentDomain(forName: suite)
        return SettingsStore(userDefaults: defaults)
    }

    private func waitUntil(
        timeout: TimeInterval,
        pollInterval: TimeInterval = 0.05,
        _ condition: @escaping () -> Bool,
        file: StaticString = #filePath,
        line: UInt = #line
    ) {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if condition() { return }
            RunLoop.current.run(until: Date().addingTimeInterval(pollInterval))
        }
        XCTFail("Condition not met within \(timeout)s", file: file, line: line)
    }
}
