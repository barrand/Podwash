//
//  WhisperModelLocatorTests.swift
//  PodWashTests
//
//  Slice 28 — Device Whisper base.en dual-SDK pin (ADR-024). AC2: logical pin from
//  injected temp bundles; no live ASR. Fixture provenance: pin strings pinned in
//  slice-28 product table and ADR-024 §1 (independent of locator implementation).
//
//  Until WhisperModelLocator.logicalPin(in:) and bundled layout exist (Engineer),
//  this file fails to compile — intended TDD red state.
//

import XCTest
@testable import PodWash

final class WhisperModelLocatorTests: XCTestCase {

    private let devicePin = "openai_whisper-base.en"
    private let simulatorPin = "openai_whisper-tiny.en"

    private var tempBundles: [URL] = []

    override func tearDown() {
        for url in tempBundles {
            try? FileManager.default.removeItem(at: url)
        }
        tempBundles = []
        super.tearDown()
    }

    // MARK: - Injected bundle helper

    /// Builds a minimal bundle with `openai_whisper-bundled/` + sibling `asr-model-pin.txt`.
    private func makeInjectedBundle(
        pin: String,
        file: StaticString = #filePath,
        line: UInt = #line
    ) throws -> Bundle {
        let base = FileManager.default.temporaryDirectory
            .appendingPathComponent("WhisperLocator-\(UUID().uuidString)", isDirectory: true)
        let bundled = base.appendingPathComponent(
            WhisperModelLocator.modelFolderResourceName,
            isDirectory: true
        )
        try FileManager.default.createDirectory(at: bundled, withIntermediateDirectories: true)
        for name in WhisperModelLocator.requiredMLModelcNames {
            try FileManager.default.createDirectory(
                at: bundled.appendingPathComponent(name, isDirectory: true),
                withIntermediateDirectories: true
            )
        }
        let pinURL = base.appendingPathComponent(WhisperModelLocator.pinResourceName)
        try Data("\(pin)\n".utf8).write(to: pinURL, options: .atomic)
        tempBundles.append(base)
        guard let bundle = Bundle(url: base) else {
            XCTFail("Could not create temp bundle at \(base.path)", file: file, line: line)
            throw CocoaError(.fileReadUnknown)
        }
        return bundle
    }

    // MARK: - AC2: injected logical pin (no live ASR)

    func testLogicalPinDeviceVsSimulator() throws {
        let deviceBundle = try makeInjectedBundle(pin: devicePin)
        XCTAssertEqual(
            try WhisperModelLocator.logicalPin(in: deviceBundle),
            devicePin,
            "Injected device pin file must resolve to openai_whisper-base.en"
        )

        let simulatorBundle = try makeInjectedBundle(pin: simulatorPin)
        XCTAssertEqual(
            try WhisperModelLocator.logicalPin(in: simulatorBundle),
            simulatorPin,
            "Injected simulator pin file must resolve to openai_whisper-tiny.en"
        )
    }

    func testLogicalPinTrimsWhitespaceAndIgnoresExtraLines() throws {
        let base = FileManager.default.temporaryDirectory
            .appendingPathComponent("WhisperLocator-trim-\(UUID().uuidString)", isDirectory: true)
        let bundled = base.appendingPathComponent(
            WhisperModelLocator.modelFolderResourceName,
            isDirectory: true
        )
        try FileManager.default.createDirectory(at: bundled, withIntermediateDirectories: true)
        for name in WhisperModelLocator.requiredMLModelcNames {
            try FileManager.default.createDirectory(
                at: bundled.appendingPathComponent(name, isDirectory: true),
                withIntermediateDirectories: true
            )
        }
        let pinURL = base.appendingPathComponent(WhisperModelLocator.pinResourceName)
        try Data("  \(simulatorPin)  \n\n".utf8).write(to: pinURL, options: .atomic)
        tempBundles.append(base)
        let bundle = try XCTUnwrap(Bundle(url: base))
        XCTAssertEqual(try WhisperModelLocator.logicalPin(in: bundle), simulatorPin)
    }

    func testResolvedModelFolderUsesStableBundledResourceName() throws {
        let bundle = try makeInjectedBundle(pin: simulatorPin)
        let folder = try WhisperModelLocator.resolvedModelFolder(in: bundle)
        XCTAssertTrue(
            folder.lastPathComponent == WhisperModelLocator.modelFolderResourceName,
            "Locator must resolve the stable bundled folder name, not the logical pin id"
        )
        let status = WhisperModelLocator.requiredSubdirectories(in: folder)
        for name in WhisperModelLocator.requiredMLModelcNames {
            XCTAssertEqual(status[name], true, "Missing required subdirectory \(name)")
        }
    }

    func testMainBundleExposesSimulatorLogicalPin() throws {
        #if targetEnvironment(simulator)
        let pin = try WhisperModelLocator.logicalPin(in: .main)
        XCTAssertEqual(
            pin,
            simulatorPin,
            "Simulator .app must ship asr-model-pin.txt with openai_whisper-tiny.en per ADR-024"
        )
        #endif
    }
}
