//
//  ASRModelSetupCopyContractTests.swift
//  PodWashTests
//
//  Slice 28 — Setup/copy script contract (ADR-024 §3.2–§3.3). AC1: both models pinned;
//  setup idempotency requires both trees; copy script branches on PLATFORM_NAME and
//  fails when the selected source model is incomplete. Script subprocess asserts use
//  temp dirs — independent of app implementation.
//

import Darwin
import XCTest

final class ASRModelSetupCopyContractTests: XCTestCase {

    private let hfRevision = "97a5bf9bbc74c7d9c12c755d04dea59e672e3808"
    private let tinyModel = "openai_whisper-tiny.en"
    private let baseModel = "openai_whisper-base.en"
    private let bundledFolder = "openai_whisper-bundled"
    private let pinFile = "asr-model-pin.txt"
    private let requiredMLModelc = [
        "AudioEncoder.mlmodelc",
        "TextDecoder.mlmodelc",
        "MelSpectrogram.mlmodelc",
    ]

    private var innerProjectDir: URL {
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
    }

    private var repoRoot: URL {
        innerProjectDir.deletingLastPathComponent()
    }

    private var setupScriptURL: URL {
        repoRoot.appendingPathComponent("scripts/setup-asr-models.sh")
    }

    private var copyScriptURL: URL {
        repoRoot.appendingPathComponent("scripts/copy-bundled-whisper-model.sh")
    }

    // MARK: - AC1: documented pins + dual-model setup contract

    func testSetupScriptEnsuresBothModelsAtPinnedRevision() throws {
        XCTAssertTrue(
            FileManager.default.fileExists(atPath: setupScriptURL.path),
            "scripts/setup-asr-models.sh missing"
        )
        let script = try String(contentsOf: setupScriptURL, encoding: .utf8)
        XCTAssertTrue(script.contains(hfRevision), "setup script must pin the exact HF revision")
        XCTAssertTrue(script.contains(tinyModel), "setup script must reference tiny.en")
        XCTAssertTrue(script.contains(baseModel), "setup script must reference base.en")
        XCTAssertTrue(
            script.contains("AudioEncoder.mlmodelc") && script.contains("MelSpectrogram.mlmodelc"),
            "setup script must integrity-check the three .mlmodelc dirs"
        )
        // Early exit must require BOTH models — not tiny-only.
        let referencesBothModels = script.contains(tinyModel) && script.contains(baseModel)
        let iteratesModels = script.contains("for ") || script.contains("MODELS") || script.contains("both")
        XCTAssertTrue(
            referencesBothModels && iteratesModels,
            "setup early-exit must verify both tiny.en and base.en are complete"
        )
    }

    func testCopyScriptDocumentsDualSDKSelectionAndStableBundleLayout() throws {
        XCTAssertTrue(
            FileManager.default.fileExists(atPath: copyScriptURL.path),
            "scripts/copy-bundled-whisper-model.sh missing"
        )
        let script = try String(contentsOf: copyScriptURL, encoding: .utf8)
        XCTAssertTrue(
            script.contains("PLATFORM_NAME"),
            "copy script must branch on PLATFORM_NAME for dual-SDK model selection"
        )
        XCTAssertTrue(
            script.contains(baseModel),
            "copy script must select base.en for device builds"
        )
        XCTAssertTrue(
            script.contains(tinyModel),
            "copy script must select tiny.en for simulator builds"
        )
        XCTAssertTrue(
            script.contains(bundledFolder),
            "copy script must install into stable openai_whisper-bundled/"
        )
        XCTAssertTrue(
            script.contains(pinFile),
            "copy script must write sibling asr-model-pin.txt"
        )
        for name in requiredMLModelc {
            XCTAssertTrue(
                script.contains(name),
                "copy script must assert presence of \(name)"
            )
        }
    }

    func testCopyScriptFailsWhenSelectedModelIncomplete() throws {
        let layout = try makeTempRepoLayout(simulatorModelComplete: false)
        defer { try? FileManager.default.removeItem(at: layout.root) }

        let status = try runCopyScript(
            srcRoot: layout.podWashDir,
            targetBuildDir: layout.buildDir,
            resourcesFolder: ".",
            platformName: "iphonesimulator"
        )
        XCTAssertNotEqual(
            status,
            0,
            "copy script must fail the build when the selected simulator model tree is incomplete"
        )
    }

    func testCopyScriptSucceedsWhenSelectedModelComplete() throws {
        let layout = try makeTempRepoLayout(simulatorModelComplete: true)
        defer { try? FileManager.default.removeItem(at: layout.root) }

        let status = try runCopyScript(
            srcRoot: layout.podWashDir,
            targetBuildDir: layout.buildDir,
            resourcesFolder: ".",
            platformName: "iphonesimulator"
        )
        XCTAssertEqual(
            status,
            0,
            "copy script must succeed when the selected model has all three .mlmodelc dirs"
        )
        let bundledDest = layout.buildDir.appendingPathComponent(bundledFolder, isDirectory: true)
        let pinDest = layout.buildDir.appendingPathComponent(pinFile)
        XCTAssertTrue(FileManager.default.fileExists(atPath: bundledDest.path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: pinDest.path))
        let pin = try String(contentsOf: pinDest, encoding: .utf8)
            .trimmingCharacters(in: .whitespacesAndNewlines)
        XCTAssertEqual(pin, tinyModel)
        for name in requiredMLModelc {
            var isDir: ObjCBool = false
            let path = bundledDest.appendingPathComponent(name).path
            XCTAssertTrue(FileManager.default.fileExists(atPath: path, isDirectory: &isDir) && isDir.boolValue)
        }
    }

    // MARK: - Temp layout + subprocess helpers

    private struct TempRepoLayout {
        let root: URL
        let podWashDir: URL
        let buildDir: URL
    }

    private func makeTempRepoLayout(simulatorModelComplete: Bool) throws -> TempRepoLayout {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("ASRSetupCopy-\(UUID().uuidString)", isDirectory: true)
        let podWashDir = root.appendingPathComponent("PodWash", isDirectory: true)
        let modelsDir = root.appendingPathComponent("Models/whisperkit-coreml", isDirectory: true)
        let modelDir = modelsDir.appendingPathComponent(tinyModel, isDirectory: true)
        let buildDir = root.appendingPathComponent("out", isDirectory: true)
        // SRCROOT must exist: macOS will not resolve `$SRCROOT/../Models/...` through a
        // missing intermediate directory (copy script uses `${SRCROOT}/../Models/...`).
        try FileManager.default.createDirectory(at: podWashDir, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: modelDir, withIntermediateDirectories: true)

        if simulatorModelComplete {
            for name in requiredMLModelc {
                try FileManager.default.createDirectory(
                    at: modelDir.appendingPathComponent(name, isDirectory: true),
                    withIntermediateDirectories: true
                )
            }
            try Data("{}".utf8).write(to: modelDir.appendingPathComponent("config.json"))
            try Data("{}".utf8).write(to: modelDir.appendingPathComponent("generation_config.json"))
        } else {
            try FileManager.default.createDirectory(
                at: modelDir.appendingPathComponent(requiredMLModelc[0], isDirectory: true),
                withIntermediateDirectories: true
            )
        }

        try FileManager.default.createDirectory(at: buildDir, withIntermediateDirectories: true)
        return TempRepoLayout(root: root, podWashDir: podWashDir, buildDir: buildDir)
    }

    @discardableResult
    private func runCopyScript(
        srcRoot: URL,
        targetBuildDir: URL,
        resourcesFolder: String,
        platformName: String
    ) throws -> Int32 {
        // Foundation.Process is macOS-only; iOS XCTest uses posix_spawn (simulator).
        var environment = ProcessInfo.processInfo.environment
        environment["SRCROOT"] = srcRoot.path
        environment["TARGET_BUILD_DIR"] = targetBuildDir.path
        environment["UNLOCALIZED_RESOURCES_FOLDER_PATH"] = resourcesFolder
        environment["PLATFORM_NAME"] = platformName
        // Prefer host tool paths if the script still uses bare names; ADR-024 copy
        // script uses /bin/* absolutes, but keep PATH sane for simulator RuntimeRoot.
        let path = environment["PATH"] ?? ""
        if !path.split(separator: ":").contains(where: { $0 == "/bin" || $0 == "/usr/bin" }) {
            environment["PATH"] = "/usr/bin:/bin:/usr/sbin:/sbin" + (path.isEmpty ? "" : ":\(path)")
        }
        return try spawnAndWait(
            executable: "/bin/sh",
            arguments: ["/bin/sh", copyScriptURL.path],
            environment: environment
        )
    }

    private func spawnAndWait(
        executable: String,
        arguments: [String],
        environment: [String: String]
    ) throws -> Int32 {
        // Null-terminated C argv/envp; pass buffer baseAddress (not &Array).
        var argv: [UnsafeMutablePointer<CChar>?] = arguments.map { strdup($0) }
        argv.append(nil)
        defer { for ptr in argv { free(ptr) } }

        var envp: [UnsafeMutablePointer<CChar>?] = environment.map {
            strdup("\($0.key)=\($0.value)")
        }
        envp.append(nil)
        defer { for ptr in envp { free(ptr) } }

        var pid: pid_t = 0
        let spawnError: Int32 = argv.withUnsafeMutableBufferPointer { argvBuf in
            envp.withUnsafeMutableBufferPointer { envBuf in
                executable.withCString { exePath in
                    posix_spawn(
                        &pid,
                        exePath,
                        nil,
                        nil,
                        argvBuf.baseAddress,
                        envBuf.baseAddress
                    )
                }
            }
        }
        guard spawnError == 0 else {
            throw NSError(
                domain: NSPOSIXErrorDomain,
                code: Int(spawnError),
                userInfo: [NSLocalizedDescriptionKey: "posix_spawn(\(executable)) failed"]
            )
        }

        var status: Int32 = 0
        let waited = waitpid(pid, &status, 0)
        guard waited == pid else {
            throw NSError(
                domain: NSPOSIXErrorDomain,
                code: Int(errno),
                userInfo: [NSLocalizedDescriptionKey: "waitpid failed"]
            )
        }

        // Darwin sys/wait.h macros are not imported into Swift; mirror their semantics.
        if Self.waitIfExited(status) {
            return Self.waitExitStatus(status)
        }
        if Self.waitIfSignaled(status) {
            return 128 + Self.waitTermSig(status)
        }
        return status
    }

    /// `_WSTATUS` / `WIFEXITED` from Darwin `sys/wait.h`.
    private static func waitStatusBits(_ status: Int32) -> Int32 { status & 0o177 }
    private static func waitIfExited(_ status: Int32) -> Bool { waitStatusBits(status) == 0 }
    private static func waitExitStatus(_ status: Int32) -> Int32 { (status >> 8) & 0xff }
    private static func waitIfSignaled(_ status: Int32) -> Bool {
        let bits = waitStatusBits(status)
        return bits != 0 && bits != 0o177
    }
    private static func waitTermSig(_ status: Int32) -> Int32 { waitStatusBits(status) }
}
