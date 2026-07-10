//
//  FixtureQueue.swift
//  PodWash
//
//  Slice 11 — Launch-argument queue reset / preserve for UI tests (slice-11-queue-resume-ux).
//

import Foundation

enum FixtureQueue {
    static let launchArgument = "-UITestFixtureQueue"
    static let preserveLaunchArgument = "-UITestFixtureQueuePreserve"

    static var isEnabled: Bool {
        ProcessInfo.processInfo.arguments.contains { argument in
            argument == launchArgument || argument.hasSuffix("UITestFixtureQueue")
        }
    }

    static var shouldPreserveOnLaunch: Bool {
        ProcessInfo.processInfo.arguments.contains { argument in
            argument == preserveLaunchArgument || argument.hasSuffix("UITestFixtureQueuePreserve")
        }
    }

    /// Wipe up-next on launch unless preserve flag is set (relaunch persistence scenario).
    static var shouldResetOnLaunch: Bool {
        isEnabled && !shouldPreserveOnLaunch
    }
}
