//
//  FixtureRuntime.swift
//  PodWash
//
//  Shared isolation contract for UI-test launches.
//

import Foundation

enum FixtureRuntime {
    static let runIdentifierEnvironmentKey = "PODWASH_UI_TEST_RUN_ID"

    /// A launcher normally provides this value. Falling back to a process-local UUID
    /// still prevents an unconfigured fixture launch from touching listener data.
    static let runIdentifier: String = {
        let supplied = ProcessInfo.processInfo.environment[runIdentifierEnvironmentKey]
        return (supplied?.isEmpty == false) ? supplied! : UUID().uuidString
    }()

    static var isFixtureLaunch: Bool {
        ProcessInfo.processInfo.arguments.contains { $0.contains("UITestFixture") }
    }

    static var persistenceIdentifier: String {
        "uitest-\(runIdentifier)"
    }
}
