//
//  DownloadPaths.swift
//  PodWash
//
//  Slice 10 — Deterministic sandbox paths for episode downloads (ADR-008 §2).
//

import Foundation

enum DownloadPaths: Sendable {
    nonisolated static func localFileURL(episodeID: String, downloadsDirectory: URL) -> URL {
        downloadsDirectory.appendingPathComponent("\(episodeID).m4a", isDirectory: false)
    }

    nonisolated static func partialFileURL(episodeID: String, downloadsDirectory: URL) -> URL {
        downloadsDirectory.appendingPathComponent("\(episodeID).m4a.part", isDirectory: false)
    }

    nonisolated static var productionDownloadsDirectory: URL {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
            .appendingPathComponent("Downloads", isDirectory: true)
    }
}
