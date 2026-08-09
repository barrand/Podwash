//
//  FixtureSettings.swift
//  PodWash
//
//  Slice 13 — Launch-argument fixture mode for Settings UI tests (ADR-010).
//

import Foundation

enum FixtureSettings {
    static let launchArgument = "-UITestFixtureSettings"
    static let resetLaunchArgument = "-UITestResetSettings"

    nonisolated static var isEnabled: Bool {
        ProcessInfo.processInfo.arguments.contains { argument in
            argument == launchArgument || argument.hasSuffix("UITestFixtureSettings")
        }
    }

    /// Allows an App Shell fixture to start from defaults without replacing the
    /// shell with the Settings-only fixture.
    nonisolated static var shouldResetOnLaunch: Bool {
        ProcessInfo.processInfo.arguments.contains { argument in
            argument == resetLaunchArgument || argument.hasSuffix("UITestResetSettings")
        }
    }

    /// Wipe persisted settings so UI tests start from PRD fresh defaults.
    nonisolated static func prepareFreshDefaults(in defaults: UserDefaults = .standard) {
        guard isEnabled || shouldResetOnLaunch else { return }
        SettingsStore.clearPersistedValues(in: defaults)
    }
}
