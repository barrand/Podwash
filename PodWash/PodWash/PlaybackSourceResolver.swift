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
        if let localURL = try? DownloadPaths.migrateLegacyLocalFileIfNeeded(
            episodeID: episode.id,
            downloadsDirectory: downloadsDirectory,
            fileManager: fileManager
        ) {
            return localURL
        }
        return episode.audioURL
    }
}
