//
//  RSSParserTests.swift
//  PodWashTests
//
//  Slice 06 — RSS parser unit tests (ADR-004). AC1–AC3.
//

import XCTest
@testable import PodWash

final class RSSParserTests: XCTestCase {

    // MARK: - Golden decode helpers (independent of production types until Engineer lands them)

    private struct GoldenEpisode: Decodable, Equatable {
        let title: String
        let pubDate: Date
        let artworkURL: URL?
        let showNotes: String?
    }

    private struct GoldenPodcastFeed: Decodable, Equatable {
        let title: String
        let artworkURL: URL?
        let description: String?
        let episodes: [GoldenEpisode]
    }

    private static let goldenDecoder: JSONDecoder = {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return decoder
    }()

    // MARK: - Fixture loading

    private func fixtureData(
        _ name: String,
        extension ext: String,
        file: StaticString = #filePath,
        line: UInt = #line
    ) throws -> Data {
        let bundle = Bundle(for: type(of: self))
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

    private func loadGolden() throws -> GoldenPodcastFeed {
        let data = try fixtureData("sample_feed_expected", extension: "json")
        return try Self.goldenDecoder.decode(GoldenPodcastFeed.self, from: data)
    }

    private func loadSampleFeedXML() throws -> Data {
        try fixtureData("sample_feed", extension: "xml")
    }

    // MARK: - Typed equality helpers

    private func assertOptionalURLEqual(
        _ actual: URL?,
        _ expected: URL?,
        _ message: String = "",
        file: StaticString = #filePath,
        line: UInt = #line
    ) {
        switch (actual, expected) {
        case (nil, nil):
            break
        case let (actual?, expected?):
            XCTAssertEqual(actual.absoluteString, expected.absoluteString, message, file: file, line: line)
        case (nil, .some):
            XCTFail("Expected URL \(expected!.absoluteString), got nil. \(message)", file: file, line: line)
        case (.some, nil):
            XCTFail("Expected nil URL, got \(actual!.absoluteString). \(message)", file: file, line: line)
        }
    }

    private func assertEpisodeMatchesGolden(
        _ episode: Episode,
        golden: GoldenEpisode,
        index: Int,
        file: StaticString = #filePath,
        line: UInt = #line
    ) {
        XCTAssertEqual(episode.title, golden.title, "episode[\(index)].title", file: file, line: line)
        XCTAssertEqual(episode.pubDate, golden.pubDate, "episode[\(index)].pubDate", file: file, line: line)
        XCTAssertEqual(episode.showNotes, golden.showNotes, "episode[\(index)].showNotes", file: file, line: line)
        assertOptionalURLEqual(
            episode.artworkURL,
            golden.artworkURL,
            "episode[\(index)].artworkURL",
            file: file,
            line: line
        )
    }

    private func assertFeedMatchesGolden(
        _ feed: PodcastFeed,
        golden: GoldenPodcastFeed,
        file: StaticString = #filePath,
        line: UInt = #line
    ) {
        XCTAssertEqual(feed.title, golden.title, file: file, line: line)
        XCTAssertEqual(feed.description, golden.description, file: file, line: line)
        assertOptionalURLEqual(feed.artworkURL, golden.artworkURL, "channel artworkURL", file: file, line: line)
        XCTAssertEqual(feed.episodes.count, golden.episodes.count, file: file, line: line)
        for (index, goldenEpisode) in golden.episodes.enumerated() {
            assertEpisodeMatchesGolden(feed.episodes[index], golden: goldenEpisode, index: index, file: file, line: line)
        }
    }

    // MARK: - AC1: golden parse match

    func testParseSampleFeedMatchesGolden() throws {
        let golden = try loadGolden()
        let xmlData = try loadSampleFeedXML()
        let parser = RSSParser()

        let feed = try parser.parse(data: xmlData)

        XCTAssertEqual(feed.episodes.count, 5)
        assertFeedMatchesGolden(feed, golden: golden)
    }

    // MARK: - AC2: malformed and empty feeds

    func testMalformedAndEmptyFeeds() throws {
        let parser = RSSParser()

        let malformedXML = """
        <?xml version="1.0" encoding="UTF-8"?>
        <rss version="2.0">
          <channel>
            <title>Broken Feed
        """.data(using: .utf8)!

        do {
            _ = try parser.parse(data: malformedXML)
            XCTFail("Expected RSSParserError.malformedFeed for unclosed XML")
        } catch let error as RSSParserError {
            XCTAssertEqual(error, .malformedFeed)
        } catch {
            XCTFail("Expected RSSParserError, got \(error)")
        }

        let emptyFeedXML = """
        <?xml version="1.0" encoding="UTF-8"?>
        <rss version="2.0">
          <channel>
            <title>Empty Feed</title>
            <link>https://fixture.podwash.tests/empty</link>
            <description>No episodes yet</description>
          </channel>
        </rss>
        """.data(using: .utf8)!

        let emptyFeed = try parser.parse(data: emptyFeedXML)
        XCTAssertEqual(emptyFeed.episodes.count, 0)
        XCTAssertEqual(emptyFeed.title, "Empty Feed")
    }

    // MARK: - AC3: optional artwork and show notes

    func testArtworkAndShowNotesOptional() throws {
        let golden = try loadGolden()
        let xmlData = try loadSampleFeedXML()
        let feed = try RSSParser().parse(data: xmlData)

        XCTAssertEqual(feed.episodes.count, golden.episodes.count)

        let richEpisode = feed.episodes[0]
        let richGolden = golden.episodes[0]
        XCTAssertEqual(richEpisode.title, richGolden.title)
        XCTAssertNotNil(richEpisode.artworkURL)
        XCTAssertNotNil(richEpisode.showNotes)
        XCTAssertFalse(richEpisode.showNotes?.isEmpty ?? true)

        let sparseEpisode = feed.episodes[4]
        let sparseGolden = golden.episodes[4]
        XCTAssertEqual(sparseEpisode.title, sparseGolden.title)
        XCTAssertNil(sparseEpisode.artworkURL)
        XCTAssertNil(sparseEpisode.showNotes)
    }
}
