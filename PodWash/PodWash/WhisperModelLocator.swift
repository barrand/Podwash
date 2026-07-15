//
//  WhisperModelLocator.swift
//  PodWash
//
//  Slice 28 — Resolves bundled openai_whisper-bundled + asr-model-pin.txt (ADR-024).
//

import Foundation

enum WhisperModelLocatorError: Error, LocalizedError {
    case folderMissing(resourceName: String)
    case incomplete(missing: [String], folder: URL)
    case pinMissing(resourceName: String)
    case pinBlank(resourceName: String)

    var errorDescription: String? {
        let setup =
            "Run scripts/setup-asr-models.sh and ensure the app target copies the PLATFORM-selected model into openai_whisper-bundled per ADR-024."
        switch self {
        case .folderMissing(let resourceName):
            return "Bundled Whisper model folder '\(resourceName)' is missing. \(setup)"
        case .incomplete(let missing, let folder):
            let list = missing.joined(separator: ", ")
            return "Bundled Whisper model at \(folder.path) is incomplete (missing: \(list)). \(setup)"
        case .pinMissing(let resourceName):
            return "Bundled ASR model pin file '\(resourceName)' is missing. \(setup)"
        case .pinBlank(let resourceName):
            return "Bundled ASR model pin file '\(resourceName)' is blank. \(setup)"
        }
    }
}

enum WhisperModelLocator {
    static let modelFolderResourceName = "openai_whisper-bundled"
    static let pinResourceName = "asr-model-pin.txt"
    static let requiredMLModelcNames = [
        "AudioEncoder.mlmodelc",
        "TextDecoder.mlmodelc",
        "MelSpectrogram.mlmodelc",
    ]

    /// Returns the bundled model folder URL. Throws if the folder or any required
    /// `.mlmodelc` subdirectory is missing.
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

    /// Logical pin string from sibling `asr-model-pin.txt` (trimmed first line).
    static func logicalPin(in bundle: Bundle = .main) throws -> String {
        let pinURL: URL
        if let url = bundle.url(forResource: "asr-model-pin", withExtension: "txt") {
            pinURL = url
        } else if let resourceURL = bundle.resourceURL {
            let candidate = resourceURL.appendingPathComponent(pinResourceName, isDirectory: false)
            guard FileManager.default.fileExists(atPath: candidate.path) else {
                throw WhisperModelLocatorError.pinMissing(resourceName: pinResourceName)
            }
            pinURL = candidate
        } else {
            throw WhisperModelLocatorError.pinMissing(resourceName: pinResourceName)
        }

        let raw = try String(contentsOf: pinURL, encoding: .utf8)
        let firstLine = raw.split(whereSeparator: \.isNewline).first.map(String.init) ?? ""
        let trimmed = firstLine.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            throw WhisperModelLocatorError.pinBlank(resourceName: pinResourceName)
        }
        return trimmed
    }

    /// Non-throwing completeness check for tests (AC1 / AC2).
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
