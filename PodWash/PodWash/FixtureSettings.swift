//
//  FixtureSettings.swift
//  PodWash
//
//  Slice 13 — Launch-argument fixture mode for Settings UI tests (ADR-010).
//

import Foundation

enum FixtureSettings {
    static let launchArgument = "-UITestFixtureSettings"

    nonisolated static var isEnabled: Bool {
        ProcessInfo.processInfo.arguments.contains { argument in
            argument == launchArgument || argument.hasSuffix("UITestFixtureSettings")
        }
    }

    /// Wipe persisted settings so UI tests start from PRD fresh defaults.
    nonisolated static func prepareFreshDefaults(in defaults: UserDefaults = .standard) {
        guard isEnabled else { return }
        SettingsStore.clearPersistedValues(in: defaults)
    }
}
