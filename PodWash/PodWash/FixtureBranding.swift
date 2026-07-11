//
//  FixtureBranding.swift
//  PodWash
//
//  Slice 21 — Launch-argument fixture mode for branding UI tests (ADR-019).
//

import Foundation

enum FixtureBranding {
    static let launchArgument = "-UITestFixtureBranding"

    nonisolated static var isEnabled: Bool {
        ProcessInfo.processInfo.arguments.contains { argument in
            argument == launchArgument || argument.hasSuffix("UITestFixtureBranding")
        }
    }
}
