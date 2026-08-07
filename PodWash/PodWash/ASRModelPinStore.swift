//
//  ASRModelPinStore.swift
//  PodWash
//
//  Slice 28 — One-shot pin reconciliation wipe (ADR-024 §5).
//

import Foundation

/// Persists the last-applied ASR logical pin without deleting listener-visible data.
enum ASRModelPinStore {
    static let storedPinFileName = "asr-model-pin-applied.txt"

    /// Application Support file holding the last-applied logical pin.
    static func storedPinURL(applicationSupport: URL) -> URL {
        applicationSupport.appendingPathComponent(storedPinFileName, isDirectory: false)
    }

    /// Records `bundledPin`. The directory arguments remain for factory compatibility
    /// but must never be removed merely because an analysis implementation changed.
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

        _ = intervalCacheDirectory
        _ = transcriptCacheDirectory
        if stored == bundledPin { return }

        try fileManager.createDirectory(
            at: storedPinURL.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        try Data("\(bundledPin)\n".utf8).write(to: storedPinURL, options: .atomic)
    }
}
