//
//  DownloadManagerTests.swift
//  PodWashTests
//
//  Slice 10 — Episode download unit tests (ADR-008). AC1–AC4.
//
//  Empirical validation checklist (ADR-008 § "Empirical validation"):
//  Pending first green CI run with Engineer implementation — AC2/AC3 depend on
//  StubDownloadURLProtocol async 4-chunk contract; anti-pattern control optional.
//

import XCTest
@testable import PodWash

@MainActor
final class DownloadManagerTests: XCTestCase {

    // Hand-transcribed from sample_feed.xml row 0 (independent of parser output).
    private static let fixtureEpisodeID = "fixture-ep-001"
    private static let fixtureRemoteURL = URL(string: "https://fixture.podwash.tests/audio/alpha.m4a")!
    private static let fixtureRemoteURLString = "https://fixture.podwash.tests/audio/alpha.m4a"
    /// Stub contract: HTTP 302 → `fixtureRemoteURL`, then normative 200 chunked body.
    private static let redirectRemoteURL = URL(
        string: "https://fixture.podwash.tests/audio/redirect/alpha.m4a"
    )!
    /// Stub contract: non-recoverable HTTP 500 with no body.
    private static let transportErrorRemoteURL = URL(
        string: "https://fixture.podwash.tests/audio/transport-error.m4a"
    )!
    private static let expectedByteCount = 1024

    private var downloadsDirectory: URL!
    private var stateStore: InMemoryDownloadStateStore!
    private var manager: DownloadManager!

    override func setUp() async throws {
        downloadsDirectory = FileManager.default.temporaryDirectory
            .appendingPathComponent("DownloadTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: downloadsDirectory, withIntermediateDirectories: true)

        StubDownloadURLProtocol.reset()

        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [StubDownloadURLProtocol.self]

        stateStore = InMemoryDownloadStateStore()
        manager = DownloadManager(
            sessionConfiguration: config,
            downloadsDirectory: downloadsDirectory,
            stateStore: stateStore
        )
    }

    override func tearDown() async throws {
        manager = nil
        stateStore = nil
        StubDownloadURLProtocol.reset()
        if let downloadsDirectory {
            try? FileManager.default.removeItem(at: downloadsDirectory)
        }
        downloadsDirectory = nil
    }

    // MARK: - Helpers

    private func expectedLocalFileURL() -> URL {
        DownloadPaths.localFileURL(
            episodeID: Self.fixtureEpisodeID,
            downloadsDirectory: downloadsDirectory
        )
    }

    private func fixtureEpisode() -> Episode {
        Episode(
            id: Self.fixtureEpisodeID,
            title: "Alpha Signal — Pilot Launch",
            pubDate: ISO8601DateFormatter().date(from: "2026-01-15T08:00:00Z")!,
            artworkURL: URL(string: "file:///fixtures/feeds/episode-0-art.png"),
            showNotes: "<p>Welcome to the pilot.</p>",
            audioURL: Self.fixtureRemoteURL
        )
    }

    private func waitUntilAtLeastTwoProgressSignals(
        progressValues: [Double],
        timeout: TimeInterval = 10
    ) async throws {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if progressValues.count >= 2 || StubDownloadURLProtocol.chunksDelivered >= 2 {
                return
            }
            try await Task.sleep(nanoseconds: 10_000_000)
        }
        XCTFail(
            "Timed out waiting for ≥ 2 progress callbacks or stub chunksDelivered ≥ 2 "
                + "(callbacks=\(progressValues.count), chunks=\(StubDownloadURLProtocol.chunksDelivered))"
        )
    }

    // MARK: - AC1: sandbox write + return URL

    func testDownloadWritesToSandbox() async throws {
        let localURL = expectedLocalFileURL()

        let returnedURL = try await manager.download(
            episodeID: Self.fixtureEpisodeID,
            from: Self.fixtureRemoteURL
        ) { _ in }

        XCTAssertEqual(returnedURL.scheme, "file")
        XCTAssertEqual(returnedURL.path, localURL.path)
        XCTAssertTrue(FileManager.default.fileExists(atPath: localURL.path))

        let onDisk = try Data(contentsOf: localURL)
        XCTAssertEqual(onDisk.count, Self.expectedByteCount)
        XCTAssertTrue(localURL.path.hasSuffix("\(Self.fixtureEpisodeID).m4a"))
    }

    // MARK: - AC2: monotonic progress, 4 callbacks, final 1.0

    func testProgressMonotonicEndsAtOne() async throws {
        var progressValues: [Double] = []

        _ = try await manager.download(
            episodeID: Self.fixtureEpisodeID,
            from: Self.fixtureRemoteURL
        ) { progress in
            progressValues.append(progress)
        }

        XCTAssertEqual(
            progressValues.count,
            4,
            "Expected exactly 4 progress callbacks with normative 4-chunk stub"
        )

        for index in 1 ..< progressValues.count {
            XCTAssertGreaterThanOrEqual(
                progressValues[index],
                progressValues[index - 1],
                "Progress must be monotonic non-decreasing at index \(index)"
            )
        }

        XCTAssertEqual(progressValues.last!, 1.0, accuracy: 0.0001)
    }

    // MARK: - AC3: cancel removes partial file, retains resume data

    func testCancelRemovesPartialAndRetainsResumeData() async throws {
        let localURL = expectedLocalFileURL()
        var progressValues: [Double] = []

        let downloadTask = Task { @MainActor in
            try await manager.download(
                episodeID: Self.fixtureEpisodeID,
                from: Self.fixtureRemoteURL
            ) { progress in
                progressValues.append(progress)
            }
        }

        try await waitUntilAtLeastTwoProgressSignals(progressValues: progressValues)

        await manager.cancel(episodeID: Self.fixtureEpisodeID)
        downloadTask.cancel()

        XCTAssertFalse(
            FileManager.default.fileExists(atPath: localURL.path),
            "Final .m4a must not exist after cancel"
        )

        let resume = manager.resumeData(for: Self.fixtureEpisodeID)
        XCTAssertNotNil(resume, "Resume data must be retained after cancel following ≥ 2 callbacks")
        XCTAssertGreaterThanOrEqual(resume!.count, 1)
    }

    // MARK: - AC4: PlaybackSourceResolver local vs remote + delete

    func testSourceResolutionAndDelete() async throws {
        let episode = fixtureEpisode()
        let resolver = PlaybackSourceResolver(
            downloadsDirectory: downloadsDirectory,
            fileManager: .default
        )

        let remoteOnly = resolver.playbackURL(for: episode)
        XCTAssertEqual(remoteOnly?.absoluteString, Self.fixtureRemoteURLString)

        _ = try await manager.download(
            episodeID: Self.fixtureEpisodeID,
            from: Self.fixtureRemoteURL
        ) { _ in }

        let localURL = expectedLocalFileURL()
        let localPlayback = resolver.playbackURL(for: episode)
        XCTAssertEqual(localPlayback?.scheme, "file")
        XCTAssertEqual(localPlayback?.path, localURL.path)

        try manager.deleteDownload(episodeID: Self.fixtureEpisodeID)

        let afterDelete = resolver.playbackURL(for: episode)
        XCTAssertEqual(afterDelete?.absoluteString, Self.fixtureRemoteURLString)
        XCTAssertFalse(FileManager.default.fileExists(atPath: localURL.path))
    }

    // MARK: - Task 001 AC1: HTTP redirect then 200 completes download

    func testDownloadCompletesAfterHTTPRedirect() async throws {
        let localURL = expectedLocalFileURL()

        let returnedURL = try await manager.download(
            episodeID: Self.fixtureEpisodeID,
            from: Self.redirectRemoteURL
        ) { _ in }

        XCTAssertEqual(manager.state(for: Self.fixtureEpisodeID), .downloaded)
        XCTAssertEqual(returnedURL.path, localURL.path)
        XCTAssertTrue(FileManager.default.fileExists(atPath: localURL.path))

        let onDisk = try Data(contentsOf: localURL)
        XCTAssertGreaterThanOrEqual(onDisk.count, 1)
    }

    // MARK: - Task 001 AC2: transport error marks failed, no final file

    func testDownloadMarksFailedOnTransportError() async throws {
        let localURL = expectedLocalFileURL()

        do {
            _ = try await manager.download(
                episodeID: Self.fixtureEpisodeID,
                from: Self.transportErrorRemoteURL
            ) { _ in }
            XCTFail("Expected download to throw DownloadError.transportFailure")
        } catch let error as DownloadError {
            XCTAssertEqual(error, .transportFailure)
        }

        XCTAssertEqual(manager.state(for: Self.fixtureEpisodeID), .failed)
        XCTAssertFalse(FileManager.default.fileExists(atPath: localURL.path))
    }

    // MARK: - Task 007 AC1: transport failure retains non-empty diagnostic

    func testFailedDownloadExposesNonEmptyDiagnostic() async throws {
        let underlyingError = DownloadError.transportFailure

        do {
            _ = try await manager.download(
                episodeID: Self.fixtureEpisodeID,
                from: Self.transportErrorRemoteURL
            ) { _ in }
            XCTFail("Expected download to throw DownloadError.transportFailure")
        } catch let error as DownloadError {
            XCTAssertEqual(error, .transportFailure)
        }

        XCTAssertEqual(manager.state(for: Self.fixtureEpisodeID), .failed)
        assertNonEmptyFailureDiagnostic(
            for: Self.fixtureEpisodeID,
            underlyingError: underlyingError
        )
    }

    // MARK: - Task 007 AC2: successful download leaves no failure diagnostic

    func testSuccessfulDownloadClearsFailureDiagnostic() async throws {
        _ = try await manager.download(
            episodeID: Self.fixtureEpisodeID,
            from: Self.redirectRemoteURL
        ) { _ in }

        XCTAssertEqual(manager.state(for: Self.fixtureEpisodeID), .downloaded)
        XCTAssertNilOrEmpty(manager.lastFailureDiagnostic(for: Self.fixtureEpisodeID))
    }

    // MARK: - Download path sanitization (RSS GUIDs with URL characters)

    func testLocalFileURLSanitizesGUIDWithURLCharacters() {
        let unsafeID = "46176 at https://www.thisamericanlife.org"
        let url = DownloadPaths.localFileURL(episodeID: unsafeID, downloadsDirectory: downloadsDirectory)

        XCTAssertFalse(url.path.contains("://"))
        XCTAssertFalse(url.path.contains("/www."))
        XCTAssertTrue(url.lastPathComponent.hasPrefix("ep-"))
        XCTAssertTrue(url.lastPathComponent.hasSuffix(".m4a"))

        let again = DownloadPaths.localFileURL(episodeID: unsafeID, downloadsDirectory: downloadsDirectory)
        XCTAssertEqual(url.path, again.path, "Sanitized path must be stable for the same episode ID")
    }

    func testLocalFileURLPreservesSafeFixtureEpisodeID() {
        let url = DownloadPaths.localFileURL(
            episodeID: Self.fixtureEpisodeID,
            downloadsDirectory: downloadsDirectory
        )
        XCTAssertEqual(url.lastPathComponent, "\(Self.fixtureEpisodeID).m4a")
    }

    func testPreferredFileExtensionUsesRemoteEnclosureExtension() {
        let mp3 = URL(string: "https://example.com/episodes/alpha.mp3?query=1")!
        XCTAssertEqual(DownloadPaths.preferredFileExtension(for: mp3), "mp3")

        let m4a = URL(string: "https://example.com/episodes/alpha.m4a")!
        XCTAssertEqual(DownloadPaths.preferredFileExtension(for: m4a), "m4a")

        let unknown = URL(string: "https://example.com/episodes/alpha")!
        XCTAssertEqual(DownloadPaths.preferredFileExtension(for: unknown), "m4a")
    }

    func testExistingLocalFileURLFindsMP3Install() throws {
        let episodeID = Self.fixtureEpisodeID
        let mp3URL = DownloadPaths.localFileURL(
            episodeID: episodeID,
            downloadsDirectory: downloadsDirectory,
            fileExtension: "mp3"
        )
        try Data([0x00]).write(to: mp3URL)

        let found = DownloadPaths.existingLocalFileURL(
            episodeID: episodeID,
            downloadsDirectory: downloadsDirectory
        )
        XCTAssertEqual(found?.path, mp3URL.path)
    }

    func testDownloadCompletesForEpisodeIDContainingURLCharacters() async throws {
        let unsafeID = "46176 at https://www.thisamericanlife.org"

        let returnedURL = try await manager.download(
            episodeID: unsafeID,
            from: Self.fixtureRemoteURL
        ) { _ in }

        XCTAssertEqual(manager.state(for: unsafeID), .downloaded)
        XCTAssertTrue(FileManager.default.fileExists(atPath: returnedURL.path))
        XCTAssertFalse(returnedURL.path.contains("://"))
        XCTAssertTrue(returnedURL.lastPathComponent.hasPrefix("ep-"))
        XCTAssertEqual(returnedURL.path, expectedLocalFileURL(for: unsafeID).path)
    }

    func testPlaybackMigratesLegacyDownloadPathWithURLCharacters() throws {
        let unsafeID = "46176 at https://www.thisamericanlife.org"
        let legacyURL = try installNestedLegacyDownload(for: unsafeID)
        let canonicalURL = expectedLocalFileURL(for: unsafeID)

        XCTAssertTrue(FileManager.default.fileExists(atPath: legacyURL.path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: canonicalURL.path))

        let episode = Episode(
            id: unsafeID,
            title: "Legacy Path Episode",
            pubDate: Date(timeIntervalSince1970: 0),
            artworkURL: nil,
            showNotes: nil,
            audioURL: Self.fixtureRemoteURL
        )
        let resolver = PlaybackSourceResolver(
            downloadsDirectory: downloadsDirectory,
            fileManager: .default
        )

        let playbackURL = resolver.playbackURL(for: episode)
        XCTAssertEqual(playbackURL?.path, canonicalURL.path)
        XCTAssertTrue(FileManager.default.fileExists(atPath: canonicalURL.path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: legacyURL.path))
    }

    func testLocalFileURLMigratesLegacyInstallOnLookup() throws {
        let unsafeID = "46176 at https://www.thisamericanlife.org"
        let legacyURL = try installNestedLegacyDownload(for: unsafeID)
        let canonicalURL = expectedLocalFileURL(for: unsafeID)

        let resolved = manager.localFileURL(for: unsafeID)
        XCTAssertEqual(resolved?.path, canonicalURL.path)
        XCTAssertTrue(FileManager.default.fileExists(atPath: canonicalURL.path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: legacyURL.path))
    }

    private func installNestedLegacyDownload(for episodeID: String) throws -> URL {
        let nested = downloadsDirectory
            .appendingPathComponent("46176 at https:", isDirectory: true)
            .appendingPathComponent("www.thisamericanlife.org.m4a", isDirectory: false)
        try FileManager.default.createDirectory(
            at: nested.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        try Data([0x00, 0x01, 0x02, 0x03]).write(to: nested)
        return nested
    }

    private func expectedLocalFileURL(for episodeID: String) -> URL {
        DownloadPaths.localFileURL(episodeID: episodeID, downloadsDirectory: downloadsDirectory)
    }

    // MARK: - Task 007 helpers

    private func assertNonEmptyFailureDiagnostic(
        for episodeID: String,
        underlyingError: Error,
        file: StaticString = #filePath,
        line: UInt = #line
    ) {
        let diagnostic = manager.lastFailureDiagnostic(for: episodeID)
        XCTAssertNotNil(diagnostic, file: file, line: line)
        guard let text = diagnostic, !text.isEmpty else {
            XCTFail("Expected non-empty failure diagnostic", file: file, line: line)
            return
        }

        let nsError = underlyingError as NSError
        let mentionsDescription = text.contains(nsError.localizedDescription)
        let mentionsDomainCode = text.contains(nsError.domain)
            && text.range(of: String(nsError.code)) != nil
        XCTAssertTrue(
            mentionsDescription || mentionsDomainCode,
            "Diagnostic should include localizedDescription or NSError domain+code; got: \(text)",
            file: file,
            line: line
        )
    }

    private func XCTAssertNilOrEmpty(
        _ value: String?,
        file: StaticString = #filePath,
        line: UInt = #line
    ) {
        if let value, !value.isEmpty {
            XCTFail("Expected nil or empty failure diagnostic, got: \(value)", file: file, line: line)
        }
    }
}
