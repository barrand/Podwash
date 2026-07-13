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
