//
//  EpisodeAnalysisArtifactStore.swift
//  PodWash
//
//  Durable listener-facing ad analysis, independent of the derived cache key.
//

import Foundation

struct EpisodeAnalysisArtifact: Codable, Equatable, Sendable {
    let episodeID: String
    let schemaVersion: Int
    let pipelineVersion: String
    let segments: [ContentSegment]
    let analysisFingerprint: String
    let completedAt: Date

    var adSpans: [ContentSegment] { segments }

    init(
        episodeID: String,
        adSpans: [ContentSegment],
        analysisFingerprint: String,
        completedAt: Date,
        schemaVersion: Int = ContentSegment.schemaVersion,
        pipelineVersion: String = ContentSegment.pipelineVersion
    ) {
        self.episodeID = episodeID
        self.schemaVersion = schemaVersion
        self.pipelineVersion = pipelineVersion
        self.segments = adSpans
        self.analysisFingerprint = analysisFingerprint
        self.completedAt = completedAt
    }
}

/// Stores the last completed ad result by episode id. Unlike `IntervalCache`, this
/// is intentionally not invalidated when the implementation changes.
struct EpisodeAnalysisArtifactStore: Sendable {
    let baseDirectory: URL

    init(baseDirectory: URL, defaults: UserDefaults = .standard) {
        self.baseDirectory = baseDirectory
        _ = defaults // Retained for source compatibility with existing injected tests.
    }

    static var applicationSupport: EpisodeAnalysisArtifactStore {
        let support = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
        return EpisodeAnalysisArtifactStore(
            baseDirectory: support.appendingPathComponent("EpisodeAnalysisArtifacts", isDirectory: true)
        )
    }

    func load(episodeID: String) -> EpisodeAnalysisArtifact? {
        guard let data = try? Data(contentsOf: fileURL(episodeID: episodeID)) else { return nil }
        guard let artifact = try? JSONDecoder().decode(EpisodeAnalysisArtifact.self, from: data),
              artifact.schemaVersion == ContentSegment.schemaVersion,
              artifact.pipelineVersion == ContentSegment.pipelineVersion
        else { return nil }
        return artifact
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

    private func fileURL(episodeID: String) -> URL {
        baseDirectory.appendingPathComponent("\(DownloadPaths.fileNameStem(for: episodeID)).json")
    }
}
