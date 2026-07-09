//
//  AnalysisUIStateTests.swift
//  PodWashTests
//
//  Slice 09 — Analysis UI state machine + toggle persistence (AC1, AC4).
//

import XCTest
@testable import PodWash

@MainActor
final class AnalysisUIStateTests: XCTestCase {

    func testStateMachineTransitions() {
        let viewModel = AnalysisUIViewModel(
            store: InMemoryCleaningToggleStore(),
            analyzer: InstantEpisodeAnalyzer(),
            autoAnalyzeOnEpisodeEnable: false
        )

        XCTAssertEqual(AnalysisUIState.allCases.count, 4)
        XCTAssertEqual(Set(AnalysisUIState.allCases), Set([.off, .channelOn, .episodeOn, .analyzing]))
        XCTAssertEqual(viewModel.state, .off)

        XCTAssertTrue(viewModel.transition(to: .channelOn))
        XCTAssertEqual(viewModel.state, .channelOn)

        XCTAssertTrue(viewModel.transition(to: .analyzing))
        XCTAssertEqual(viewModel.state, .analyzing)

        XCTAssertTrue(viewModel.transition(to: .episodeOn))
        XCTAssertEqual(viewModel.state, .episodeOn)

        XCTAssertTrue(viewModel.transition(to: .off))
        XCTAssertEqual(viewModel.state, .off)

        XCTAssertTrue(viewModel.transition(to: .episodeOn))
        XCTAssertEqual(viewModel.state, .episodeOn)

        XCTAssertFalse(viewModel.transition(to: .channelOn))
        XCTAssertEqual(viewModel.state, .episodeOn)

        XCTAssertTrue(viewModel.transition(to: .analyzing))
        XCTAssertTrue(viewModel.transition(to: .channelOn))

        let fresh = AnalysisUIViewModel(
            store: InMemoryCleaningToggleStore(),
            analyzer: InstantEpisodeAnalyzer(),
            autoAnalyzeOnEpisodeEnable: false
        )
        XCTAssertFalse(fresh.transition(to: .analyzing))
        XCTAssertEqual(fresh.state, .off)
    }

    func testTogglePersistence() {
        let store = InMemoryCleaningToggleStore()
        store.setChannelCleaning(true)
        store.setEpisodeCleaning("episode-alpha", enabled: true)

        let first = AnalysisUIViewModel(
            store: store,
            analyzer: InstantEpisodeAnalyzer(),
            autoAnalyzeOnEpisodeEnable: false
        )
        XCTAssertTrue(first.store.isChannelCleaningEnabled)
        XCTAssertTrue(first.store.isEpisodeCleaningEnabled("episode-alpha"))
        XCTAssertEqual(first.state, .channelOn)

        let second = AnalysisUIViewModel(
            store: store,
            analyzer: InstantEpisodeAnalyzer(),
            autoAnalyzeOnEpisodeEnable: false
        )
        XCTAssertTrue(second.store.isChannelCleaningEnabled)
        XCTAssertTrue(second.store.isEpisodeCleaningEnabled("episode-alpha"))
        XCTAssertEqual(second.state, .channelOn)
    }

    func testPrimeEpisodeCleaningShowsAnalyzingRow() {
        let viewModel = AnalysisUIViewModel(
            store: InMemoryCleaningToggleStore(),
            analyzer: InstantEpisodeAnalyzer(),
            autoAnalyzeOnEpisodeEnable: true
        )

        viewModel.primeEpisodeCleaningToggle(episodeID: "fixture-ep-001")

        XCTAssertEqual(viewModel.state, .analyzing)
        XCTAssertTrue(viewModel.episodeRowShowsProgress(episodeID: "fixture-ep-001"))
        XCTAssertFalse(viewModel.episodeRowShowsOnBadge(episodeID: "fixture-ep-001"))
    }
}
