//
//  NowPlayingSessionUITests.swift
//  PodWashUITests
//
//  Slice 31 — Restore now-playing session on relaunch UI tests (slice-31-ux.md). AC5–AC6.
//  Launch args and pinned position from ADR-027 §8 / slice-31-ux.md Fixture constants.
//

import XCTest

final class NowPlayingSessionUITests: XCTestCase {

  private let fixtureRunIdentifier = "now-playing-\(UUID().uuidString)"

  private let nowPlayingSessionArgs = [
    "-UITestFixtureLibrary",
    "-UITestFixtureNowPlayingSession",
    "-UITestChannelCleaningOff",
  ]
  private let nowPlayingSessionPreserveArgs = [
    "-UITestFixtureLibrary",
    "-UITestFixtureNowPlayingSessionPreserve",
    "-UITestChannelCleaningOff",
  ]

  /// UX pinned restore position (FixtureNowPlayingSession.pinnedRestorePositionSeconds).
  private let pinnedPositionSeconds = 15
  private let relaunchMiniTimeout: TimeInterval = 10
  private let fixtureTimeout: TimeInterval = 5

  /// Library show 0, episode row 0 — independent of implementation (slice-31-ux.md).
  private let queuedEpisodeID = "lib-0-fixture-ep-002"

  override func setUpWithError() throws {
    continueAfterFailure = false
  }

  // MARK: - AC5: mini player restores paused after terminate + preserve relaunch

  @MainActor
  func testMiniPlayerRestoresPausedAfterRelaunch() throws {
    let app = launchApp(arguments: nowPlayingSessionArgs)
    establishPausedSession(in: app)

    app.terminate()

    let relaunched = launchApp(arguments: nowPlayingSessionPreserveArgs)
    waitForLibraryRoot(relaunched)

    let miniPlayer = element("miniPlayer", in: relaunched)
    XCTAssertTrue(
      miniPlayer.waitForExistence(timeout: relaunchMiniTimeout),
      "miniPlayer must appear within \(relaunchMiniTimeout)s after preserve relaunch without episode-row tap"
    )

    let miniPlayPause = element("miniPlayerPlayPause", in: relaunched)
    XCTAssertTrue(miniPlayPause.waitForExistence(timeout: fixtureTimeout))
    XCTAssertEqual(
      miniPlayPause.value as? String,
      "paused",
      "restored mini player must not auto-play"
    )

    // Regression: the restored mini-player reservation must not paint over the
    // system tab bar. Query the visible UIKit tab buttons (rather than its
    // implementation-specific UITabBarItem identifier) because this is the
    // exact control a listener taps to reach their library or add a show.
    let libraryTab = relaunched.tabBars.buttons["Library"]
    XCTAssertTrue(libraryTab.waitForExistence(timeout: fixtureTimeout))
    XCTAssertTrue(libraryTab.isHittable, "Library must remain hittable on cold restore")
    let discoverTab = relaunched.tabBars.buttons["Discover"]
    XCTAssertTrue(discoverTab.waitForExistence(timeout: fixtureTimeout))
    XCTAssertTrue(discoverTab.isHittable, "Discover must remain hittable on cold restore")

    tapMiniPlayerBar(relaunched)

    let elapsed = element("playback.elapsed", in: relaunched)
    XCTAssertTrue(elapsed.waitForExistence(timeout: fixtureTimeout))
    let elapsedSeconds = Int(elapsed.value as? String ?? "-1") ?? -1
    XCTAssertGreaterThanOrEqual(
      elapsedSeconds,
      pinnedPositionSeconds - 1,
      "playback.elapsed must be within ±1 s of pinned restore position"
    )
    XCTAssertLessThanOrEqual(
      elapsedSeconds,
      pinnedPositionSeconds + 1,
      "playback.elapsed must be within ±1 s of pinned restore position"
    )

    let fullPlayPause = element("playback.playPause", in: relaunched)
    XCTAssertTrue(fullPlayPause.waitForExistence(timeout: fixtureTimeout))
    XCTAssertEqual(fullPlayPause.value as? String, "paused")
  }

  // MARK: - AC6: up-next queue persists with restored session after relaunch

  @MainActor
  func testQueuePersistsWithRestoredSessionAfterRelaunch() throws {
    let app = launchApp(arguments: nowPlayingSessionArgs)
    establishPausedSession(in: app, queueEpisodeID: queuedEpisodeID)

    app.terminate()

    let relaunched = launchApp(arguments: nowPlayingSessionPreserveArgs)
    waitForLibraryRoot(relaunched)

    let miniPlayer = element("miniPlayer", in: relaunched)
    XCTAssertTrue(
      miniPlayer.waitForExistence(timeout: relaunchMiniTimeout),
      "miniPlayer must restore before queue chrome assert"
    )
    let miniPlayPause = element("miniPlayerPlayPause", in: relaunched)
    XCTAssertEqual(miniPlayPause.value as? String, "paused")

    assertQueuedEpisodeVisible(in: relaunched, episodeID: queuedEpisodeID)
  }

  // MARK: - Seed helper (slice-31-ux.md)

  @MainActor
  private func establishPausedSession(
    in app: XCUIApplication,
    queueEpisodeID: String? = nil
  ) {
    waitForLibraryRoot(app)
    navigateToEpisodeList(app)

    let episodeCell = element("episodeCell_0", in: app)
    XCTAssertTrue(episodeCell.waitForExistence(timeout: fixtureTimeout))
    episodeCell.tap()

    let miniPlayer = element("miniPlayer", in: app)
    XCTAssertTrue(
      miniPlayer.waitForExistence(timeout: fixtureTimeout),
      "miniPlayer must appear after first-launch episode play"
    )

    let miniPlayPause = element("miniPlayerPlayPause", in: app)
    XCTAssertTrue(miniPlayPause.waitForExistence(timeout: fixtureTimeout))
    waitForAccessibilityValue(
        "playing",
      identifier: "miniPlayerPlayPause",
      in: app,
      timeout: fixtureTimeout,
      message: "miniPlayerPlayPause must report playing before seek"
    )

    if let queueEpisodeID {
      // Queue while the episode list is the top chrome, then prove the
      // listener-visible Queue tab contains that exact episode before relaunch.
      let queueAdd = app.buttons["queueAddButton_1"]
      XCTAssertTrue(queueAdd.waitForExistence(timeout: fixtureTimeout))
      tapQueueAddIfNeeded(queueAdd, in: app)
      assertQueuedEpisodeVisible(in: app, episodeID: queueEpisodeID)

      let libraryTab = app.tabBars.buttons["Library"]
      XCTAssertTrue(libraryTab.waitForExistence(timeout: fixtureTimeout))
      libraryTab.tap()
      waitForLibraryRoot(app)
    }

    tapMiniPlayerBar(app)

    let fullPlayPause = element("playback.playPause", in: app)
    XCTAssertTrue(fullPlayPause.waitForExistence(timeout: fixtureTimeout))

    // Pause first so ±15 seeks are relative to a stable clock near start (UX: "from start").
    // Seeking while playing lets the playhead race past the pinned 15 s (±1) window.
    if (fullPlayPause.value as? String) == "playing" {
      fullPlayPause.tap()
      waitForAccessibilityValue(
        "paused",
        identifier: "playback.playPause",
        in: app,
        timeout: fixtureTimeout,
        message: "playback.playPause must report paused before pinned seek"
      )
    }

    let seekBack = app.buttons["playback.seekBack15"]
    XCTAssertTrue(seekBack.waitForExistence(timeout: fixtureTimeout))
    // Rewind toward 0 so one +15 lands at the pinned restore position.
    for _ in 0..<3 {
      let elapsedBefore = element("playback.elapsed", in: app)
      let secondsBefore = Int(elapsedBefore.value as? String ?? "0") ?? 0
      if secondsBefore <= 1 { break }
      seekBack.tap()
    }

    let seekForward = app.buttons["playback.seekForward15"]
    XCTAssertTrue(seekForward.waitForExistence(timeout: fixtureTimeout))
    seekForward.tap()

    waitForAccessibilityValue(
      "paused",
      identifier: "playback.playPause",
      in: app,
      timeout: fixtureTimeout,
      message: "playback.playPause must remain paused after seek (position flush)"
    )

    let elapsed = element("playback.elapsed", in: app)
    XCTAssertTrue(elapsed.waitForExistence(timeout: fixtureTimeout))
    waitUntilElapsed(
      inRange: (pinnedPositionSeconds - 1)...(pinnedPositionSeconds + 1),
      in: app,
      timeout: fixtureTimeout
    )

    dismissFullPlayer(app)
    XCTAssertTrue(miniPlayer.waitForExistence(timeout: fixtureTimeout))
    XCTAssertEqual(element("miniPlayerPlayPause", in: app).value as? String, "paused")

  }

  // MARK: - Launch + query helpers

  @MainActor
  private func launchApp(arguments: [String]) -> XCUIApplication {
    let app = XCUIApplication()
    app.launchEnvironment["PODWASH_UI_TEST_RUN_ID"] = fixtureRunIdentifier
    app.launchArguments.append(contentsOf: arguments)
    app.launch()
    return app
  }

  @MainActor
  private func element(_ identifier: String, in app: XCUIApplication) -> XCUIElement {
    app.descendants(matching: .any)[identifier]
  }

  @MainActor
  private func waitForLibraryRoot(_ app: XCUIApplication, timeout: TimeInterval = 5) {
    let root = element("libraryRoot", in: app)
    XCTAssertTrue(root.waitForExistence(timeout: timeout), "libraryRoot must appear within \(timeout)s")
  }

  @MainActor
  private func navigateToEpisodeList(_ app: XCUIApplication) {
    let showCell = element("libraryCell_0", in: app)
    XCTAssertTrue(showCell.waitForExistence(timeout: fixtureTimeout))
    showCell.tap()
    let episodeList = element("episodeList", in: app)
    XCTAssertTrue(episodeList.waitForExistence(timeout: fixtureTimeout))
  }

  @MainActor
  private func assertQueuedEpisodeVisible(in app: XCUIApplication, episodeID: String) {
    let queueTab = app.tabBars.buttons["Queue"]
    XCTAssertTrue(queueTab.waitForExistence(timeout: fixtureTimeout))
    XCTAssertTrue(queueTab.isHittable, "Queue tab must remain tappable with mini-player visible")
    queueTab.tap()

    let queueRoot = element("queueTab", in: app)
    XCTAssertTrue(queueRoot.waitForExistence(timeout: fixtureTimeout))
    let queuedEpisode = element("queueEpisode_\(episodeID)", in: app)
    XCTAssertTrue(queuedEpisode.waitForExistence(timeout: fixtureTimeout))
    XCTAssertFalse(
      element("queueEmpty", in: app).exists,
      "Queue must show the seeded episode rather than its empty state."
    )
  }

  @MainActor
  private func tapMiniPlayerBar(_ app: XCUIApplication) {
    let bar = element("miniPlayer", in: app)
    XCTAssertTrue(bar.waitForExistence(timeout: fixtureTimeout))
    bar.coordinate(withNormalizedOffset: CGVector(dx: 0.2, dy: 0.5)).tap()
  }

  @MainActor
  private func dismissFullPlayer(_ app: XCUIApplication) {
    let fullPlayPause = element("playback.playPause", in: app)
    for _ in 0..<2 {
      guard fullPlayPause.exists else { break }
      app.swipeDown()
      let sheetGone = NSPredicate(format: "exists == false")
      let expectation = XCTNSPredicateExpectation(predicate: sheetGone, object: fullPlayPause)
      _ = XCTWaiter().wait(for: [expectation], timeout: fixtureTimeout)
    }
    let miniPlayer = element("miniPlayer", in: app)
    _ = miniPlayer.waitForExistence(timeout: fixtureTimeout)
  }

  /// Mini-player safe-area can report `queueAddButton_*` as exists&&!isHittable;
  /// scroll once then coordinate-tap so seed does not depend on exact chrome inset.
  @MainActor
  private func tapQueueAddIfNeeded(_ queueAdd: XCUIElement, in app: XCUIApplication) {
    if queueAdd.isHittable {
      queueAdd.tap()
      return
    }
    app.swipeUp()
    if queueAdd.waitForExistence(timeout: 1), queueAdd.isHittable {
      queueAdd.tap()
      return
    }
    queueAdd.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5)).tap()
  }

  @MainActor
  private func waitForAccessibilityValue(
    _ expected: String,
    identifier: String,
    in app: XCUIApplication,
    timeout: TimeInterval,
    message: String
  ) {
    let control = element(identifier, in: app)
    let predicate = NSPredicate(format: "value == %@", expected)
    let expectation = XCTNSPredicateExpectation(predicate: predicate, object: control)
    let result = XCTWaiter().wait(for: [expectation], timeout: timeout)
    XCTAssertEqual(result, .completed, message)
    XCTAssertEqual(control.value as? String, expected)
  }

  @MainActor
  private func waitUntilElapsed(
    inRange range: ClosedRange<Int>,
    in app: XCUIApplication,
    timeout: TimeInterval,
    file: StaticString = #filePath,
    line: UInt = #line
  ) {
    let elapsed = element("playback.elapsed", in: app)
    let deadline = Date().addingTimeInterval(timeout)
    while Date() < deadline {
      let seconds = Int(elapsed.value as? String ?? "-1") ?? -1
      if range.contains(seconds) { return }
      RunLoop.current.run(until: Date().addingTimeInterval(0.05))
    }
    let finalSeconds = Int(elapsed.value as? String ?? "-1") ?? -1
    XCTFail(
      "playback.elapsed \(finalSeconds) not in \(range.lowerBound)...\(range.upperBound) within \(timeout)s",
      file: file,
      line: line
    )
  }
}
