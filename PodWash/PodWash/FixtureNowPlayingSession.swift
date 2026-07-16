//
//  FixtureNowPlayingSession.swift
//  PodWash
//
//  Slice 31 — Fixed-identifier Library relaunch fixture (ADR-027 §8 / slice-31-ux.md).
//

import Foundation

enum FixtureNowPlayingSession {
    static let launchArgument = "-UITestFixtureNowPlayingSession"
    static let preserveLaunchArgument = "-UITestFixtureNowPlayingSessionPreserve"
    /// Stable temp-SQLite key shared by both launches of the relaunch UITest.
    static let persistenceIdentifier = "uitest-now-playing-session"
    /// UX pinned restore position (discrete seek +15 from start).
    static let pinnedRestorePositionSeconds: TimeInterval = 15.0

    static var isEnabled: Bool {
        ProcessInfo.processInfo.arguments.contains { argument in
            argument == launchArgument
                || (argument.hasSuffix("UITestFixtureNowPlayingSession")
                    && !argument.hasSuffix("UITestFixtureNowPlayingSessionPreserve"))
        }
    }

    static var shouldPreserveOnLaunch: Bool {
        ProcessInfo.processInfo.arguments.contains { argument in
            argument == preserveLaunchArgument
                || argument.hasSuffix("UITestFixtureNowPlayingSessionPreserve")
        }
    }

    /// Either seed or preserve arg — use the fixed persistence identifier.
    static var usesFixedPersistence: Bool {
        isEnabled || shouldPreserveOnLaunch
    }
}
