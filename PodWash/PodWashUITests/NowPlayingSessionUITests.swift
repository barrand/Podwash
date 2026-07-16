//
//  NowPlayingSessionUITests.swift
//  PodWashUITests
//
//  Slice 31 — Restore now-playing session on relaunch UI tests (slice-31-ux.md). AC5–AC6.
//  Launch args and pinned position from ADR-027 §8 / slice-31-ux.md Fixture constants.
//

import XCTest

final class NowPlayingSessionUITests: XCTestCase {

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
    establishPausedSessionWithQueue(in: app, recordQueueSnapshot: false)

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
    let snapshot = establishPausedSessionWithQueue(in: app, recordQueueSnapshot: true)

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

    navigateToEpisodeList(relaunched)

    let queueList = element("queueList", in: relaunched)
    XCTAssertTrue(queueList.waitForExistence(timeout: fixtureTimeout))
    XCTAssertEqual(
      queueList.value as? String,
      snapshot.queueListValue,
      "queueList count must match pre-terminate snapshot"
    )

    let queueCell0 = element("queueCell_0", in: relaunched)
    XCTAssertTrue(queueCell0.waitForExistence(timeout: fixtureTimeout))
    XCTAssertEqual(
      queueCell0.value as? String,
      snapshot.queueCell0Value,
      "queueCell_0 episode id must match pre-terminate snapshot"
    )
    XCTAssertEqual(
      queueCell0.value as? String,
      queuedEpisodeID,
      "seeded queue must expose lib-0-fixture-ep-002 at index 0"
    )
  }

  // MARK: - Seed helper (slice-31-ux.md establishPausedSessionWithQueue)

  private struct QueueSnapshot {
    let queueListValue: String
    let queueCell0Value: String
  }

  @discardableResult
  @MainActor
  private func establishPausedSessionWithQueue(
    in app: XCUIApplication,
    recordQueueSnapshot: Bool
  ) -> QueueSnapshot {
    _ = recordQueueSnapshot
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
    miniPlayPause.tap()
    waitForAccessibilityValue(
      "playing",
      identifier: "miniPlayerPlayPause",
      in: app,
      timeout: fixtureTimeout,
      message: "miniPlayerPlayPause must report playing before seek"
    )

    // Queue while the episode list is still the top chrome — full-player sheet
    // otherwise covers `queueAddButton_1` (exists && !isHittable).
    let queueAdd = app.buttons["queueAddButton_1"]
    XCTAssertTrue(queueAdd.waitForExistence(timeout: fixtureTimeout))
    tapQueueAddIfNeeded(queueAdd, in: app)

    waitForAccessibilityValue(
      "1",
      identifier: "queueList",
      in: app,
      timeout: 2,
      message: "queueList must report one queued episode"
    )

    let queueCell0 = element("queueCell_0", in: app)
    XCTAssertTrue(queueCell0.waitForExistence(timeout: fixtureTimeout))
    XCTAssertEqual(queueCell0.value as? String, queuedEpisodeID)

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

    let listValue = element("queueList", in: app).value as? String ?? ""
    let cellValue = queueCell0.value as? String ?? ""
    return QueueSnapshot(queueListValue: listValue, queueCell0Value: cellValue)
  }

  // MARK: - Launch + query helpers

  @MainActor
  private func launchApp(arguments: [String]) -> XCUIApplication {
    let app = XCUIApplication()
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
