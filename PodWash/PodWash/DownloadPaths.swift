//
//  DownloadPaths.swift
//  PodWash
//
//  Slice 10 — Deterministic sandbox paths for episode downloads (ADR-008 §2).
//

import CryptoKit
import Foundation

enum DownloadPaths: Sendable {
    /// Stable on-disk filename stem for `Episode.id`. RSS GUIDs may contain `:` and `/`
    /// (e.g. This American Life); those must not be passed raw to `appendingPathComponent`.
    nonisolated static func fileNameStem(for episodeID: String) -> String {
        guard isPathSafeFileNameStem(episodeID) else {
            return hashedFileNameStem(for: episodeID)
        }
        return episodeID
    }

    nonisolated static func localFileURL(episodeID: String, downloadsDirectory: URL) -> URL {
        downloadsDirectory.appendingPathComponent("\(fileNameStem(for: episodeID)).m4a", isDirectory: false)
    }

    /// Pre–hashing install path: raw `episodeID.m4a` (RSS GUIDs may include `:`).
    nonisolated static func legacyRawLocalFileURL(episodeID: String, downloadsDirectory: URL) -> URL {
        downloadsDirectory.appendingPathComponent("\(episodeID).m4a", isDirectory: false)
    }

    /// Canonical on-disk file when present, otherwise a legacy raw-name install.
    nonisolated static func existingLocalFileURL(
        episodeID: String,
        downloadsDirectory: URL,
        fileManager: FileManager = .default
    ) -> URL? {
        let canonical = localFileURL(episodeID: episodeID, downloadsDirectory: downloadsDirectory)
        if fileManager.fileExists(atPath: canonical.path) {
            return canonical
        }
        return discoverLegacyLocalFileURL(
            episodeID: episodeID,
            downloadsDirectory: downloadsDirectory,
            fileManager: fileManager
        )
    }

    /// Locates pre-sanitization installs: flat `episodeID.m4a` or nested paths when `/`
    /// in the RSS GUID was interpreted as directories during `moveItem`.
    nonisolated static func discoverLegacyLocalFileURL(
        episodeID: String,
        downloadsDirectory: URL,
        fileManager: FileManager = .default
    ) -> URL? {
        guard !isPathSafeFileNameStem(episodeID) else { return nil }

        let flat = legacyRawLocalFileURL(episodeID: episodeID, downloadsDirectory: downloadsDirectory)
        if fileManager.fileExists(atPath: flat.path) {
            return flat
        }

        let suffix = legacyNestedFileNameSuffix(for: episodeID)
        guard let enumerator = fileManager.enumerator(
            at: downloadsDirectory,
            includingPropertiesForKeys: [.isRegularFileKey],
            options: [.skipsHiddenFiles]
        ) else { return nil }

        let canonical = localFileURL(episodeID: episodeID, downloadsDirectory: downloadsDirectory)
        var matches: [URL] = []
        for case let url as URL in enumerator {
            guard url.pathExtension.lowercased() == "m4a" else { continue }
            guard url.path != canonical.path else { continue }
            if url.lastPathComponent == suffix {
                matches.append(url)
            }
        }
        return matches.count == 1 ? matches[0] : nil
    }

    nonisolated private static func legacyNestedFileNameSuffix(for episodeID: String) -> String {
        let rawName = "\(episodeID).m4a"
        if let last = rawName.split(separator: "/").last {
            return String(last)
        }
        return rawName
    }

    /// Moves a legacy raw-name install onto the canonical hashed path when needed.
    @discardableResult
    nonisolated static func migrateLegacyLocalFileIfNeeded(
        episodeID: String,
        downloadsDirectory: URL,
        fileManager: FileManager = .default
    ) throws -> URL? {
        guard let existing = existingLocalFileURL(
            episodeID: episodeID,
            downloadsDirectory: downloadsDirectory,
            fileManager: fileManager
        ) else { return nil }

        let canonical = localFileURL(episodeID: episodeID, downloadsDirectory: downloadsDirectory)
        if existing.path == canonical.path {
            return existing
        }

        try fileManager.createDirectory(at: downloadsDirectory, withIntermediateDirectories: true)
        if fileManager.fileExists(atPath: canonical.path) {
            try fileManager.removeItem(at: existing)
            return canonical
        }
        try fileManager.moveItem(at: existing, to: canonical)
        return canonical
    }

    nonisolated static func partialFileURL(episodeID: String, downloadsDirectory: URL) -> URL {
        downloadsDirectory.appendingPathComponent("\(fileNameStem(for: episodeID)).m4a.part", isDirectory: false)
    }

    nonisolated static func isPathSafeFileNameStem(_ episodeID: String) -> Bool {
        guard !episodeID.isEmpty, episodeID.count <= 128, !episodeID.contains("..") else {
            return false
        }
        let forbidden = CharacterSet(charactersIn: "/:\\")
        return episodeID.rangeOfCharacter(from: forbidden) == nil
    }

    nonisolated private static func hashedFileNameStem(for episodeID: String) -> String {
        let digest = SHA256.hash(data: Data(episodeID.utf8))
        let hex = digest.map { String(format: "%02x", $0) }.joined()
        return "ep-\(hex)"
    }

    nonisolated static var productionDownloadsDirectory: URL {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
            .appendingPathComponent("Downloads", isDirectory: true)
    }
}
