//
//  EpisodeAnalysisArtifactStore.swift
//  PodWash
//
//  Durable listener-facing ad analysis, independent of the derived cache key.
//

import Foundation

struct EpisodeAnalysisArtifact: Codable, Equatable, Sendable {
    let episodeID: String
    let adSpans: [ContentSegment]
    let analysisFingerprint: String
    let completedAt: Date
}

/// Stores the last completed ad result by episode id. Unlike `IntervalCache`, this
/// is intentionally not invalidated when the implementation changes.
struct EpisodeAnalysisArtifactStore: Sendable {
    let baseDirectory: URL
    private let defaults: UserDefaults
    private let migrationKey = "podwash.analysisArtifactMigration.v1"

    init(baseDirectory: URL, defaults: UserDefaults = .standard) {
        self.baseDirectory = baseDirectory
        self.defaults = defaults
    }

    static var applicationSupport: EpisodeAnalysisArtifactStore {
        let support = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
        return EpisodeAnalysisArtifactStore(
            baseDirectory: support.appendingPathComponent("EpisodeAnalysisArtifacts", isDirectory: true)
        )
    }

    func load(episodeID: String) -> EpisodeAnalysisArtifact? {
        guard let data = try? Data(contentsOf: fileURL(episodeID: episodeID)) else { return nil }
        return try? JSONDecoder().decode(EpisodeAnalysisArtifact.self, from: data)
    }

    func store(_ artifact: EpisodeAnalysisArtifact) throws {
        try FileManager.default.createDirectory(at: baseDirectory, withIntermediateDirectories: true)
        try JSONEncoder().encode(artifact).write(to: fileURL(episodeID: artifact.episodeID), options: .atomic)
    }

    func remove(episodeID: String) throws {
        let url = fileURL(episodeID: episodeID)
        guard FileManager.default.fileExists(atPath: url.path) else { return }
        try FileManager.default.removeItem(at: url)
    }

    /// One-time best-effort bridge for pre-artifact completed cache records. Profanity
    /// intervals are intentionally ignored because they depend on listener settings.
    func migrateLegacyArtifactsIfNeeded(intervalCache: IntervalCache, episodeIDs: [String] = []) {
        guard !defaults.bool(forKey: migrationKey) else { return }
        for legacy in intervalCache.completedRecords(episodeIDs: episodeIDs) {
            guard load(episodeID: legacy.episodeID) == nil else { continue }
            let spans = legacy.record.intervals.compactMap { interval -> ContentSegment? in
                guard interval.source == .unrelatedContent else { return nil }
                return ContentSegment(start: interval.start, end: interval.end)
            }
            try? store(EpisodeAnalysisArtifact(
                episodeID: legacy.episodeID,
                adSpans: spans,
                analysisFingerprint: legacy.fingerprint,
                completedAt: legacy.modifiedAt
            ))
        }
        defaults.set(true, forKey: migrationKey)
    }

    private func fileURL(episodeID: String) -> URL {
        baseDirectory.appendingPathComponent("\(DownloadPaths.fileNameStem(for: episodeID)).json")
    }
}
