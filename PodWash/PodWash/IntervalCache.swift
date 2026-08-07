//
//  IntervalCache.swift
//  PodWash
//
//  Slice 07 — Analyze-episode pipeline. On-disk JSON cache of merged censor
//  intervals keyed by episode ID + normalized target-word fingerprint (ADR-005 §3).
//  Slice 28 — `asr-model:<pin>` fingerprint token (ADR-024).
//  Task 030 — explicit `analysisCompleted` record (empty interval list ≠ cache miss).
//

import CryptoKit
import Foundation

/// Stable episode identity for cache keys. Slice 11 may replace with persisted model IDs.
struct EpisodeIdentity: Hashable, Codable, Equatable, Sendable {
    let id: String
}

/// On-disk interval-cache payload. `analysisCompleted` distinguishes a finished analyze
/// (including zero ad spans) from a partial profanity-only write after cloud failure.
struct IntervalCacheRecord: Codable, Equatable, Sendable {
    let intervals: [CensorInterval]
    let analysisCompleted: Bool
}

/// On-disk JSON cache of merged censor intervals.
struct IntervalCache: Sendable {

    struct CompletedRecord: Sendable {
        let episodeID: String
        let fingerprint: String
        let record: IntervalCacheRecord
        let modifiedAt: Date
    }

    let baseDirectory: URL
    /// Logical ASR pin included in fingerprint material as `asr-model:<pin>`.
    let asrModelPin: String

    /// - Parameter asrModelPin: Logical pin (e.g. `openai_whisper-tiny.en`). Default keeps
    ///   pre-slice call sites compiling; production factory always passes the bundled pin.
    init(baseDirectory: URL, asrModelPin: String = "openai_whisper-tiny.en") {
        self.baseDirectory = baseDirectory
        self.asrModelPin = asrModelPin
    }

    /// Production cache location under Application Support for a known pin.
    static func applicationSupport(asrModelPin: String) -> IntervalCache {
        let support = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
        return IntervalCache(
            baseDirectory: support.appendingPathComponent("IntervalCache", isDirectory: true),
            asrModelPin: asrModelPin
        )
    }

    /// Production cache using the main-bundle logical pin when available (fixtures / shell defaults).
    static var applicationSupport: IntervalCache {
        let pin = (try? WhisperModelLocator.logicalPin(in: .main)) ?? "openai_whisper-tiny.en"
        return applicationSupport(asrModelPin: pin)
    }

    /// Deterministic fingerprint: sorted, normalized target words joined by `\n`.
    static func fingerprint(for targetWords: Set<String>) -> String {
        WordMatcher.normalizedTargetSet(targetWords)
            .sorted()
            .joined(separator: "\n")
    }

    func loadRecord(episodeID: String, targetWords: Set<String>) -> IntervalCacheRecord? {
        let url = cacheFileURL(episodeID: episodeID, targetWords: targetWords)
        guard let data = try? Data(contentsOf: url) else { return nil }
        let decoder = JSONDecoder()
        if let record = try? decoder.decode(IntervalCacheRecord.self, from: data) {
            return record
        }
        guard let legacy = try? decoder.decode([CensorInterval].self, from: data) else { return nil }
        return IntervalCacheRecord(intervals: legacy, analysisCompleted: true)
    }

    func load(episodeID: String, targetWords: Set<String>) -> [CensorInterval]? {
        loadRecord(episodeID: episodeID, targetWords: targetWords)?.intervals
    }

    func isAnalysisCompleted(episodeID: String, targetWords: Set<String>) -> Bool {
        loadRecord(episodeID: episodeID, targetWords: targetWords)?.analysisCompleted ?? false
    }

    /// Full derived-cache fingerprint for diagnostics and durable artifacts.
    func currentFingerprint(for targetWords: Set<String>) -> String {
        Self.cacheFingerprint(targetWords: targetWords, asrModelPin: asrModelPin)
    }

    /// Migration-only enumeration of completed cache files. Safe identifier stems are
    /// reversible; hashed historical IDs have no durable reverse mapping and skip.
    func completedRecords() -> [CompletedRecord] {
        completedRecords(episodeIDs: [])
    }

    /// Supplying known podcast ids also migrates historical hashed filename stems.
    func completedRecords(episodeIDs: [String]) -> [CompletedRecord] {
        let fm = FileManager.default
        guard let files = try? fm.contentsOfDirectory(
            at: baseDirectory,
            includingPropertiesForKeys: [.contentModificationDateKey],
            options: [.skipsHiddenFiles]
        ) else { return [] }
        var latest: [String: CompletedRecord] = [:]
        for url in files where url.pathExtension == "json" {
            guard let data = try? Data(contentsOf: url) else { continue }
            let decoder = JSONDecoder()
            let record: IntervalCacheRecord?
            if let decoded = try? decoder.decode(IntervalCacheRecord.self, from: data) {
                record = decoded
            } else if let legacy = try? decoder.decode([CensorInterval].self, from: data) {
                record = IntervalCacheRecord(intervals: legacy, analysisCompleted: true)
            } else {
                record = nil
            }
            guard let record, record.analysisCompleted else { continue }
            let stem = url.deletingPathExtension().lastPathComponent
            guard let separator = stem.range(of: "__") else { continue }
            let prefix = String(stem[..<separator.lowerBound])
            let episodeID = episodeIDs.first(where: { DownloadPaths.fileNameStem(for: $0) == prefix }) ?? prefix
            guard !episodeID.isEmpty else { continue }
            let modified = (try? url.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate) ?? .distantPast
            let candidate = CompletedRecord(episodeID: episodeID, fingerprint: stem, record: record, modifiedAt: modified)
            if latest[episodeID]?.modifiedAt ?? .distantPast < modified {
                latest[episodeID] = candidate
            }
        }
        return latest.values.sorted { $0.modifiedAt > $1.modifiedAt }
    }

    func store(
        _ intervals: [CensorInterval],
        episodeID: String,
        targetWords: Set<String>,
        analysisCompleted: Bool = true
    ) throws {
        try FileManager.default.createDirectory(at: baseDirectory, withIntermediateDirectories: true)
        let url = cacheFileURL(episodeID: episodeID, targetWords: targetWords)
        let record = IntervalCacheRecord(intervals: intervals, analysisCompleted: analysisCompleted)
        let data = try JSONEncoder().encode(record)
        try data.write(to: url, options: .atomic)
    }

    /// Episode delete / download+cache purge — removes all fingerprint files for `episodeID`.
    func remove(episodeID: String) throws {
        let stem = DownloadPaths.fileNameStem(for: episodeID)
        let fm = FileManager.default
        guard fm.fileExists(atPath: baseDirectory.path) else { return }
        let contents = try fm.contentsOfDirectory(
            at: baseDirectory,
            includingPropertiesForKeys: nil
        )
        for url in contents where url.lastPathComponent.hasPrefix("\(stem)__") {
            try fm.removeItem(at: url)
        }
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
        // Segmenter revision bumps invalidate stale unions missing unrelated spans.
        // ADR-024 — asr-model pin so pre-upgrade tiny intervals miss after pin change.
        let fp = Self.cacheFingerprint(targetWords: targetWords, asrModelPin: asrModelPin)
        let digest = SHA256.hash(data: Data(fp.utf8))
        let hash = digest.map { String(format: "%02x", $0) }.joined()
        let safeStem = DownloadPaths.fileNameStem(for: episodeID)
        let filename = "\(safeStem)__\(hash).json"
        return baseDirectory.appendingPathComponent(filename, isDirectory: false)
    }

    private static func cacheFingerprint(targetWords: Set<String>, asrModelPin: String) -> String {
        fingerprint(for: targetWords)
            + "\ninterval-format:v2"
            + "\nsegmenter:cloud-gemini-v1"
            + "\nasr-model:\(asrModelPin)"
    }
}
