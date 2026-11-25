import CoreData
import XCTest
@testable import PodWash

@MainActor
final class ListeningHistoryStoreTests: XCTestCase {
    func testMigratesShippingSQLiteStoreAndImportsPlayedEpisodesOnce() throws {
        let models = try XCTUnwrap(Bundle(for: AppShellModel.self).url(forResource: "PodWash", withExtension: "momd"))
        let version = models.appendingPathComponent("PodWash.mom")
        let oldModel = try XCTUnwrap(NSManagedObjectModel(contentsOf: version))
        let currentModel = try XCTUnwrap(NSManagedObjectModel(contentsOf: models))
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let storeURL = directory.appendingPathComponent("PodWash.sqlite")
        let oldCoordinator = NSPersistentStoreCoordinator(managedObjectModel: oldModel)
        let oldStore = try oldCoordinator.addPersistentStore(type: .sqlite, at: storeURL)
        let oldContext = NSManagedObjectContext(concurrencyType: .mainQueueConcurrencyType)
        oldContext.persistentStoreCoordinator = oldCoordinator
        let feedURL = try XCTUnwrap(URL(string: "https://history.example.test/feed"))
        let feed = try FixtureFeedLoader.loadSampleFeed()
        let episode = try XCTUnwrap(feed.episodes.first)
        try PodcastStore(context: oldContext).save(feed, feedURL: feedURL)
        try ResumePositionStore(context: oldContext).setPlayed(true, for: episode.id)
        try ResumePositionStore(context: oldContext).setPosition(90, for: episode.id)
        try QueueStore(context: oldContext).add(episode.id)
        try NowPlayingSessionStore(context: oldContext).setActiveEpisodeID(episode.id)
        oldContext.reset()
        try oldCoordinator.remove(oldStore)

        let coordinator = NSPersistentStoreCoordinator(managedObjectModel: currentModel)
        let currentStore = try coordinator.addPersistentStore(type: .sqlite, at: storeURL, options: [
            NSMigratePersistentStoresAutomaticallyOption: true,
            NSInferMappingModelAutomaticallyOption: true
        ])
        let context = NSManagedObjectContext(concurrencyType: .mainQueueConcurrencyType)
        context.persistentStoreCoordinator = coordinator
        defer {
            context.reset()
            try? coordinator.remove(currentStore)
        }
        let history = ListeningHistoryStore(context: context)
        try history.importPlayedEpisodes()
        try history.importPlayedEpisodes()
        XCTAssertEqual(history.entries().map(\.id.episodeID), [episode.id])
        XCTAssertNil(history.entries().first?.completedAt)
        XCTAssertEqual(ResumePositionStore(context: context).position(for: episode.id), 90)
        XCTAssertEqual(QueueStore(context: context).queueEpisodeIDs(), [episode.id])
        XCTAssertEqual(NowPlayingSessionStore(context: context).activeEpisodeID(), episode.id)
    }

    func testCompletionDeduplicatesRunAndScopesEpisodeIDToFeed() throws {
        let context = PersistenceController.inMemory()
        let history = ListeningHistoryStore(context: context.viewContext)
        let episode = try XCTUnwrap(FixtureFeedLoader.loadSampleFeed().episodes.first)
        let first = try XCTUnwrap(URL(string: "https://history.example.test/first"))
        let second = try XCTUnwrap(URL(string: "https://history.example.test/second"))
        let firstDate = Date(timeIntervalSince1970: 100)
        let secondDate = Date(timeIntervalSince1970: 200)
        XCTAssertTrue(try history.recordCompletion(episode: episode, feedURL: first, showTitle: "A",
                                                   runID: "first", at: firstDate) {})
        XCTAssertFalse(try history.recordCompletion(episode: episode, feedURL: first, showTitle: "A",
                                                    runID: "first", at: secondDate) { XCTFail("duplicate update") })
        XCTAssertTrue(try history.recordCompletion(episode: episode, feedURL: second, showTitle: "B",
                                                   runID: "second", at: secondDate) {})
        XCTAssertEqual(history.entries().map(\.id.feedURL), [second, first])
        XCTAssertEqual(history.entries().compactMap(\.completedAt), [secondDate, firstDate])
    }
}
