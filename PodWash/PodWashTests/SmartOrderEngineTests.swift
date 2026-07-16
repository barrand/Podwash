//
//  SmartOrderEngineTests.swift
//  PodWashTests
//
//  ADR-029 — Smart autoplay ordering unit tests.
//

import XCTest
@testable import PodWash

final class SmartOrderEngineTests: XCTestCase {

    private let feedA = URL(string: "https://example.com/a.xml")!
    private let feedB = URL(string: "https://example.com/b.xml")!
    private let feedSerial = URL(string: "https://example.com/serial.xml")!

    func testNonBingePicksLatestEligiblePerShowInLRPOrder() {
        let shows = [
            SmartOrderShow(
                feedURL: feedA,
                title: "Planet Money",
                isBinge: false,
                lastHeardAt: Date(timeIntervalSince1970: 200),
                episodes: [
                    ep("pm-old", title: "Old", pub: 100, played: true),
                    ep("pm-new", title: "New", pub: 300, played: false),
                ]
            ),
            SmartOrderShow(
                feedURL: feedB,
                title: "Darknet",
                isBinge: false,
                lastHeardAt: Date(timeIntervalSince1970: 100),
                episodes: [
                    ep("dd-new", title: "Latest", pub: 400, played: false),
                ]
            ),
        ]
        let engine = SmartOrderEngine()
        let next = engine.nextEpisode(
            shows: shows,
            currentEpisodeID: "pm-new",
            currentFeedURL: feedA
        )
        XCTAssertEqual(next?.episodeID, "dd-new")
        XCTAssertEqual(next?.podcastTitle, "Darknet")
    }

    func testBingePlaysOldestUnplayedAndStays() {
        let shows = [
            SmartOrderShow(
                feedURL: feedSerial,
                title: "Serial",
                isBinge: true,
                lastHeardAt: nil,
                episodes: [
                    ep("s1", title: "Ep1", pub: 100, played: true),
                    ep("s2", title: "Ep2", pub: 200, played: false),
                    ep("s3", title: "Ep3", pub: 300, played: false),
                ]
            ),
            SmartOrderShow(
                feedURL: feedA,
                title: "Planet Money",
                isBinge: false,
                lastHeardAt: nil,
                episodes: [ep("pm", title: "PM", pub: 500, played: false)],
            ),
        ]
        var engine = SmartOrderEngine(activeBingeFeedURL: feedSerial)
        let peek = engine.peek(
            count: 3,
            shows: shows,
            currentEpisodeID: "s1",
            currentFeedURL: feedSerial
        )
        // Stay in binge for remaining episodes, then fill peek from rotation.
        XCTAssertEqual(peek.map(\.episodeID), ["s2", "s3", "pm"])
        XCTAssertTrue(peek[0].isBinge && peek[1].isBinge)
        XCTAssertFalse(peek[2].isBinge)
    }

    func testSkipToNextShowExitsBingeAndDismisses() {
        let shows = [
            SmartOrderShow(
                feedURL: feedSerial,
                title: "Serial",
                isBinge: true,
                lastHeardAt: Date(timeIntervalSince1970: 50),
                episodes: [
                    ep("s2", title: "Ep2", pub: 200, played: false),
                    ep("s3", title: "Ep3", pub: 300, played: false),
                ]
            ),
            SmartOrderShow(
                feedURL: feedA,
                title: "Planet Money",
                isBinge: false,
                lastHeardAt: Date(timeIntervalSince1970: 10),
                episodes: [ep("pm", title: "PM", pub: 500, played: false)],
            ),
        ]
        let engine = SmartOrderEngine(activeBingeFeedURL: feedSerial)
        let next = engine.nextEpisode(
            shows: shows,
            currentEpisodeID: "s2",
            currentFeedURL: feedSerial,
            skipToNextShow: true
        )
        // s2 dismissed in simulation; binge exited → LRP picks least-heard (Planet Money).
        XCTAssertEqual(next?.episodeID, "pm")
    }

    func testDismissedEpisodesNeverEligible() {
        let show = SmartOrderShow(
            feedURL: feedA,
            title: "A",
            isBinge: false,
            lastHeardAt: nil,
            episodes: [
                ep("a1", title: "One", pub: 100, played: false, dismissed: true),
                ep("a2", title: "Two", pub: 200, played: false),
            ]
        )
        XCTAssertEqual(SmartOrderEngine.latestEligible(for: show)?.id, "a2")
    }

    func testUnfinishedRemainsEligible() {
        let episode = ep("u1", title: "Unfinished", pub: 100, played: false, position: 30)
        XCTAssertTrue(SmartOrderEngine.isEligible(episode))
    }

    func testPeekCountMatchesWarmDepth() {
        let shows = [
            SmartOrderShow(
                feedURL: feedA,
                title: "A",
                isBinge: false,
                lastHeardAt: Date(timeIntervalSince1970: 1),
                episodes: [ep("a1", title: "A1", pub: 100, played: false)],
            ),
            SmartOrderShow(
                feedURL: feedB,
                title: "B",
                isBinge: false,
                lastHeardAt: Date(timeIntervalSince1970: 2),
                episodes: [ep("b1", title: "B1", pub: 200, played: false)],
            ),
            SmartOrderShow(
                feedURL: feedSerial,
                title: "C",
                isBinge: false,
                lastHeardAt: Date(timeIntervalSince1970: 3),
                episodes: [ep("c1", title: "C1", pub: 300, played: false)],
            ),
        ]
        let engine = SmartOrderEngine()
        let peek = engine.peek(
            count: 3,
            shows: shows,
            currentEpisodeID: nil,
            currentFeedURL: nil
        )
        XCTAssertEqual(peek.count, 3)
        XCTAssertEqual(peek.map(\.episodeID), ["a1", "b1", "c1"])
    }

    // MARK: - Helpers

    private func ep(
        _ id: String,
        title: String,
        pub: TimeInterval,
        played: Bool,
        dismissed: Bool = false,
        position: TimeInterval = 0
    ) -> SmartOrderEpisode {
        SmartOrderEpisode(
            id: id,
            title: title,
            pubDate: Date(timeIntervalSince1970: pub),
            isPlayed: played,
            playbackPosition: position,
            dismissedFromAutoplay: dismissed
        )
    }
}
