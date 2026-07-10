//
//  FixtureDownload.swift
//  PodWash
//
//  Slice 10 — Launch-argument instant download stub for UI tests (ADR-008 §6).
//

import Foundation

enum FixtureDownload {
    static let launchArgument = "-UITestFixtureDownload"

    static var isEnabled: Bool {
        ProcessInfo.processInfo.arguments.contains { argument in
            argument == launchArgument || argument.hasSuffix("UITestFixtureDownload")
        }
    }

    static func bundledStubURL(in bundle: Bundle = .main) -> URL? {
        if let url = bundle.url(
            forResource: "stub_episode_audio",
            withExtension: "bin",
            subdirectory: "Fixtures/downloads"
        ) ?? bundle.url(forResource: "stub_episode_audio", withExtension: "bin") {
            return url
        }
        // Synchronized Xcode groups flatten resources to the bundle root; also try
        // enumerating in case the resource is registered under a different path.
        if let urls = bundle.urls(forResourcesWithExtension: "bin", subdirectory: nil) {
            return urls.first { $0.lastPathComponent == "stub_episode_audio.bin" }
        }
        return nil
    }

    static func clearDownloadsDirectoryIfNeeded(
        fileManager: FileManager = .default
    ) {
        guard isEnabled else { return }
        let directory = DownloadPaths.productionDownloadsDirectory
        try? fileManager.removeItem(at: directory)
        try? fileManager.createDirectory(at: directory, withIntermediateDirectories: true)
    }
}
