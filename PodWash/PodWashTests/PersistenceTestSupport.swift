//
//  PersistenceTestSupport.swift
//  PodWashTests
//
//  Slice 11 — Shared reload harness, fixture loading, and EpisodePlaying spy (ADR-009 §3, §5).
//

import XCTest
@testable import PodWash

// MARK: - Reload harness (ADR-009 §3)

/// Per-test isolated identifier; two controllers with the same id simulate process relaunch.
@MainActor
final class PersistenceReloadHarness {
    let identifier: String

    init(identifier: String = UUID().uuidString) {
        self.identifier = identifier
    }

    func makeController() -> PersistenceController {
        PersistenceController.inMemory(identifier: identifier)
    }
}

// MARK: - Fixture feed loader (provenance: hand-authored sample_feed.xml, Slice 06)

enum FixtureFeedLoader {
    static func fixtureData(
        _ name: String,
        extension ext: String,
        file: StaticString = #filePath,
        line: UInt = #line
    ) throws -> Data {
        let bundle = Bundle(for: PersistenceReloadHarness.self)
        if let url = bundle.url(forResource: name, withExtension: ext, subdirectory: "Fixtures/feeds")
            ?? bundle.url(forResource: name, withExtension: ext) {
            return try Data(contentsOf: url)
        }
        let sourceURL = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .appendingPathComponent("Fixtures/feeds/\(name).\(ext)")
        if FileManager.default.fileExists(atPath: sourceURL.path) {
            return try Data(contentsOf: sourceURL)
        }
        XCTFail(
            "Missing fixture '\(name).\(ext)' (not in test bundle nor at \(sourceURL.path))",
            file: file,
            line: line
        )
        throw CocoaError(.fileNoSuchFile)
    }

    /// Parsed from bundled `sample_feed.xml` via `RSSParser.parse(data:)` — independent of Core Data stores.
    static func loadSampleFeed() throws -> PodcastFeed {
        let data = try fixtureData("sample_feed", extension: "xml")
        let parser = RSSParser()
        return try parser.parse(data: data)
    }

    static func seedEpisodes(into podcastStore: PodcastStore) throws {
        let feed = try loadSampleFeed()
        try podcastStore.save(feed)
    }
}

// MARK: - EpisodePlaying spy (ADR-009 §5, AC2–AC3)

@MainActor
final class EpisodePlayingSpy: EpisodePlaying {
    struct PlayCall: Equatable {
        let episodeID: String
        let date: Date
    }

    private(set) var playCalls: [PlayCall] = []
    private(set) var seekPositions: [TimeInterval] = []
    private(set) var pauseCallCount = 0

    func play(episodeID: String) {
        playCalls.append(PlayCall(episodeID: episodeID, date: Date()))
    }

    func pause() {
        pauseCallCount += 1
    }

    func seek(to seconds: TimeInterval) {
        seekPositions.append(seconds)
    }

    func waitForPlayCallCount(
        _ expected: Int,
        timeout: TimeInterval = 1.0,
        file: StaticString = #filePath,
        line: UInt = #line
    ) {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if playCalls.count >= expected {
                return
            }
            RunLoop.current.run(until: Date().addingTimeInterval(0.01))
        }
        XCTFail(
            "Expected \(expected) play(episodeID:) call(s) within \(timeout)s; got \(playCalls.count)",
            file: file,
            line: line
        )
    }
}
