//
//  PlaybackSourceResolver.swift
//  PodWash
//
//  Slice 10 — Prefer local download over remote enclosure URL (ADR-008 §4).
//

import Foundation

struct PlaybackSourceResolver: Sendable {
    let downloadsDirectory: URL
    let fileManager: FileManager

    init(downloadsDirectory: URL, fileManager: FileManager = .default) {
        self.downloadsDirectory = downloadsDirectory
        self.fileManager = fileManager
    }

    func playbackURL(for episode: Episode) -> URL? {
        let localURL = DownloadPaths.localFileURL(
            episodeID: episode.id,
            downloadsDirectory: downloadsDirectory
        )
        if fileManager.fileExists(atPath: localURL.path) {
            return localURL
        }
        return episode.audioURL
    }
}
