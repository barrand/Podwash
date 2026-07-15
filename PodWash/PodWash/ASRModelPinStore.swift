//
//  ASRModelPinStore.swift
//  PodWash
//
//  Slice 28 — One-shot pin reconciliation wipe (ADR-024 §5).
//

import Foundation

/// Persists the last-applied ASR logical pin and wipes interval + transcript caches
/// when the bundled pin changes (or no stored pin exists yet).
enum ASRModelPinStore {
    static let storedPinFileName = "asr-model-pin-applied.txt"

    /// Application Support file holding the last-applied logical pin.
    static func storedPinURL(applicationSupport: URL) -> URL {
        applicationSupport.appendingPathComponent(storedPinFileName, isDirectory: false)
    }

    /// If stored pin ≠ `bundledPin` (or stored missing): delete the interval and
    /// transcript cache directories (if present), then write `bundledPin`.
    /// If equal: no-op (do not wipe).
    static func reconcile(
        bundledPin: String,
        storedPinURL: URL,
        intervalCacheDirectory: URL,
        transcriptCacheDirectory: URL,
        fileManager: FileManager = .default
    ) throws {
        let stored: String?
        if fileManager.fileExists(atPath: storedPinURL.path),
           let raw = try? String(contentsOf: storedPinURL, encoding: .utf8) {
            let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
            stored = trimmed.isEmpty ? nil : trimmed
        } else {
            stored = nil
        }

        if stored == bundledPin {
            return
        }

        if fileManager.fileExists(atPath: intervalCacheDirectory.path) {
            try fileManager.removeItem(at: intervalCacheDirectory)
        }
        if fileManager.fileExists(atPath: transcriptCacheDirectory.path) {
            try fileManager.removeItem(at: transcriptCacheDirectory)
        }

        try fileManager.createDirectory(
            at: storedPinURL.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        try Data("\(bundledPin)\n".utf8).write(to: storedPinURL, options: .atomic)
    }
}
