//
//  TranscriptCache.swift
//  PodWash
//
//  Slice 26 — On-disk JSON cache of full-episode ASR transcripts (ADR-022).
//

import Foundation

/// On-disk JSON cache of the full episode ASR transcript.
struct TranscriptCache: Sendable {

    let baseDirectory: URL

    init(baseDirectory: URL) {
        self.baseDirectory = baseDirectory
    }

    /// Production cache location under Application Support.
    static var applicationSupport: TranscriptCache {
        let support = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
        return TranscriptCache(
            baseDirectory: support.appendingPathComponent("TranscriptCache", isDirectory: true)
        )
    }

    /// True iff a transcript file exists for `episodeID` (affordance gate; no decode required).
    func exists(episodeID: String) -> Bool {
        FileManager.default.fileExists(atPath: cacheFileURL(episodeID: episodeID).path)
    }

    func load(episodeID: String) -> [TimedWord]? {
        let url = cacheFileURL(episodeID: episodeID)
        guard let data = try? Data(contentsOf: url) else { return nil }
        return try? JSONDecoder().decode([TimedWord].self, from: data)
    }

    /// Overwrites any prior file for this episode (terminal re-analyze).
    func store(_ words: [TimedWord], episodeID: String) throws {
        try FileManager.default.createDirectory(at: baseDirectory, withIntermediateDirectories: true)
        let data = try JSONEncoder().encode(words)
        try data.write(to: cacheFileURL(episodeID: episodeID), options: .atomic)
    }

    /// Episode delete / download+cache purge — AC10.
    func remove(episodeID: String) throws {
        let url = cacheFileURL(episodeID: episodeID)
        guard FileManager.default.fileExists(atPath: url.path) else { return }
        try FileManager.default.removeItem(at: url)
    }

    /// Test helper — removes the cache directory.
    func clear() throws {
        if FileManager.default.fileExists(atPath: baseDirectory.path) {
            try FileManager.default.removeItem(at: baseDirectory)
        }
    }

    // MARK: - Private

    private func cacheFileURL(episodeID: String) -> URL {
        let safeStem = DownloadPaths.fileNameStem(for: episodeID)
        return baseDirectory.appendingPathComponent("\(safeStem).json", isDirectory: false)
    }
}
