//
//  WhisperModelLocator.swift
//  PodWash
//
//  Slice 24 — Resolves bundled openai_whisper-tiny.en (ADR-020 §3).
//

import Foundation

enum WhisperModelLocatorError: Error, LocalizedError {
    case folderMissing(resourceName: String)
    case incomplete(missing: [String], folder: URL)

    var errorDescription: String? {
        let setup =
            "Run scripts/setup-asr-models.sh and ensure the app target copies openai_whisper-tiny.en per ADR-020."
        switch self {
        case .folderMissing(let resourceName):
            return "Bundled Whisper model folder '\(resourceName)' is missing. \(setup)"
        case .incomplete(let missing, let folder):
            let list = missing.joined(separator: ", ")
            return "Bundled Whisper model at \(folder.path) is incomplete (missing: \(list)). \(setup)"
        }
    }
}

enum WhisperModelLocator {
    static let modelFolderResourceName = "openai_whisper-tiny.en"
    static let requiredMLModelcNames = [
        "AudioEncoder.mlmodelc",
        "TextDecoder.mlmodelc",
        "MelSpectrogram.mlmodelc",
    ]

    /// Returns the bundled model folder URL. Throws if the folder or any required
    /// `.mlmodelc` subdirectory is missing. Error text cites setup script + ADR-020.
    static func resolvedModelFolder(in bundle: Bundle = .main) throws -> URL {
        let folder: URL
        if let url = bundle.url(forResource: modelFolderResourceName, withExtension: nil) {
            folder = url
        } else if let resourceURL = bundle.resourceURL {
            let candidate = resourceURL.appendingPathComponent(modelFolderResourceName, isDirectory: true)
            guard FileManager.default.fileExists(atPath: candidate.path) else {
                throw WhisperModelLocatorError.folderMissing(resourceName: modelFolderResourceName)
            }
            folder = candidate
        } else {
            throw WhisperModelLocatorError.folderMissing(resourceName: modelFolderResourceName)
        }

        let status = requiredSubdirectories(in: folder)
        let missing = requiredMLModelcNames.filter { status[$0] != true }
        guard missing.isEmpty else {
            throw WhisperModelLocatorError.incomplete(missing: missing, folder: folder)
        }
        return folder
    }

    /// Non-throwing completeness check for tests (AC1).
    static func requiredSubdirectories(in modelFolder: URL) -> [String: Bool] {
        var result: [String: Bool] = [:]
        for name in requiredMLModelcNames {
            let url = modelFolder.appendingPathComponent(name, isDirectory: true)
            var isDirectory: ObjCBool = false
            let exists = FileManager.default.fileExists(atPath: url.path, isDirectory: &isDirectory)
            result[name] = exists && isDirectory.boolValue
        }
        return result
    }
}
