//
//  IntervalCache.swift
//  PodWash
//
//  Slice 07 — Analyze-episode pipeline. On-disk JSON cache of merged censor
//  intervals keyed by episode ID + normalized target-word fingerprint (ADR-005 §3).
//

import CryptoKit
import Foundation

/// Stable episode identity for cache keys. Slice 11 may replace with persisted model IDs.
struct EpisodeIdentity: Hashable, Codable, Equatable, Sendable {
    let id: String
}

/// On-disk JSON cache of merged censor intervals.
struct IntervalCache: Sendable {

    let baseDirectory: URL

    init(baseDirectory: URL) {
        self.baseDirectory = baseDirectory
    }

    /// Production cache location under Application Support.
    static var applicationSupport: IntervalCache {
        let support = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
        return IntervalCache(baseDirectory: support.appendingPathComponent("IntervalCache", isDirectory: true))
    }

    /// Deterministic fingerprint: sorted, normalized target words joined by `\n`.
    static func fingerprint(for targetWords: Set<String>) -> String {
        WordMatcher.normalizedTargetSet(targetWords)
            .sorted()
            .joined(separator: "\n")
    }

    func load(episodeID: String, targetWords: Set<String>) -> [CensorInterval]? {
        let url = cacheFileURL(episodeID: episodeID, targetWords: targetWords)
        guard let data = try? Data(contentsOf: url) else { return nil }
        return try? JSONDecoder().decode([CensorInterval].self, from: data)
    }

    func store(_ intervals: [CensorInterval], episodeID: String, targetWords: Set<String>) throws {
        try FileManager.default.createDirectory(at: baseDirectory, withIntermediateDirectories: true)
        let url = cacheFileURL(episodeID: episodeID, targetWords: targetWords)
        let data = try JSONEncoder().encode(intervals)
        try data.write(to: url, options: .atomic)
    }

    /// Test helper — removes all cached files.
    func clear() throws {
        if FileManager.default.fileExists(atPath: baseDirectory.path) {
            try FileManager.default.removeItem(at: baseDirectory)
        }
    }

    // MARK: - Private

    private func cacheFileURL(episodeID: String, targetWords: Set<String>) -> URL {
        // ADR-013 §3.4 — format token so sourced unions do not collide with v1 payloads.
        let fp = Self.fingerprint(for: targetWords) + "\n" + "interval-format:v2"
        let digest = SHA256.hash(data: Data(fp.utf8))
        let hash = digest.map { String(format: "%02x", $0) }.joined()
        let safeStem = DownloadPaths.fileNameStem(for: episodeID)
        let filename = "\(safeStem)__\(hash).json"
        return baseDirectory.appendingPathComponent(filename, isDirectory: false)
    }
}
