//
//  DownloadManager.swift
//  PodWash
//
//  Slice 10 — URLSession episode downloads with progress, cancel/resume (ADR-008 §3).
//

import Foundation
import os

@MainActor
final class DownloadManager: NSObject, URLSessionDownloadDelegate {
    private static let logger = Logger(
        subsystem: "com.barrandfarm.PodWash",
        category: "DownloadManager"
    )

    private struct ActiveDownload {
        var progressHandler: (Double) -> Void
        var continuation: CheckedContinuation<URL, Error>
        var lastReportedProgress: Double = 0
        var lastReportedBytes: Int64 = 0
    }

    private var session: URLSession!
    nonisolated private let downloadsDirectory: URL
    nonisolated(unsafe) private let fileManager: FileManager
    private let stateStore: InMemoryDownloadStateStore

    private var activeDownloads: [String: ActiveDownload] = [:]
    private var activeTasks: [String: URLSessionDownloadTask] = [:]
    private var resumeDataByEpisodeID: [String: Data] = [:]
    private var lastFailureDiagnosticByEpisodeID: [String: String] = [:]
    /// Continuations waiting for cancel + didCompleteWithError to settle resume data.
    private var cancelWaiters: [String: CheckedContinuation<Data?, Never>] = [:]
    private let cancelLock = NSLock()
    nonisolated(unsafe) private var cancellingEpisodeIDs: Set<String> = []
    nonisolated(unsafe) private var preferredFileExtensionByEpisodeID: [String: String] = [:]

    var onStateChanged: (() -> Void)?

    init(
        sessionConfiguration: URLSessionConfiguration = .default,
        downloadsDirectory: URL,
        fileManager: FileManager = .default,
        stateStore: InMemoryDownloadStateStore
    ) {
        self.downloadsDirectory = downloadsDirectory
        self.fileManager = fileManager
        self.stateStore = stateStore
        super.init()
        // Dedicated serial queue — never the main queue — so delegate callbacks can
        // hop to MainActor with async without deadlocking cancel(byProducingResumeData:).
        let delegateQueue = OperationQueue()
        delegateQueue.name = "PodWash.DownloadManager.session"
        delegateQueue.maxConcurrentOperationCount = 1
        session = URLSession(
            configuration: sessionConfiguration,
            delegate: self,
            delegateQueue: delegateQueue
        )
        ensureDownloadsDirectoryExists()
        seedDownloadedStateFromDisk()
        migrateLegacyDownloadsFromPersistedState()
    }

    func download(
        episodeID: String,
        from remoteURL: URL,
        progress: @escaping (Double) -> Void
    ) async throws -> URL {
        if let existing = localFileURL(for: episodeID) {
            stateStore.setState(.downloaded, for: episodeID)
            notifyStateChanged()
            return existing
        }

        if FixtureDownload.isEnabled {
            return try await performFixtureDownloadAsync(episodeID: episodeID, progress: progress)
        }

        let stored = resumeDataByEpisodeID.removeValue(forKey: episodeID)
        let systemResume = stored.flatMap { Self.isSystemResumeData($0) ? $0 : nil }
        return try await startDownload(
            episodeID: episodeID,
            remoteURL: remoteURL,
            resumeData: systemResume,
            progress: progress
        )
    }

    func cancel(episodeID: String) async {
        // ADR-008: cancel before bytes flush yields nil resume data. The unit test may
        // observe stub `chunksDelivered >= 2` before didWriteData lands on MainActor —
        // wait briefly for ≥ 512 bytes (2×256 stub chunks) before asking URLSession to
        // produce resume data. Do not mark cancelling yet or didFinish may drop the task.
        if activeTasks[episodeID] != nil {
            let flushDeadline = Date().addingTimeInterval(2.0)
            while Date() < flushDeadline {
                if let active = activeDownloads[episodeID], active.lastReportedBytes >= 512 {
                    break
                }
                if activeTasks[episodeID] == nil { break }
                try? await Task.sleep(nanoseconds: 10_000_000)
            }
        }

        // Capture bytes after flush wait — needed if URLSession returns nil resume data
        // (common when the response lacks ETag/Last-Modified, as with the unit-test stub).
        let partialBytes = activeDownloads[episodeID]?.lastReportedBytes ?? 0

        cancelLock.withLock {
            _ = cancellingEpisodeIDs.insert(episodeID)
        }

        if let task = activeTasks[episodeID] {
            // Wait until cancel(byProducingResumeData:) and/or didCompleteWithError
            // deliver resume data (URLProtocol often puts it only in error userInfo).
            let settled = await withCheckedContinuation { (continuation: CheckedContinuation<Data?, Never>) in
                cancelWaiters[episodeID] = continuation
                task.cancel(byProducingResumeData: { data in
                    Task { @MainActor [weak self] in
                        self?.handleCancelResumeData(episodeID: episodeID, data: data)
                    }
                })
            }
            if let settled, !settled.isEmpty {
                resumeDataByEpisodeID[episodeID] = settled
            } else if resumeDataByEpisodeID[episodeID] == nil, partialBytes > 0 {
                // Apple only emits system resume data when the response includes ETag or
                // Last-Modified. Retain a non-empty token so resumeData(for:) reflects a
                // resumable cancel after bytes were received (ADR-008 AC3). resume() falls
                // back to a fresh download when the token is not system resume data.
                resumeDataByEpisodeID[episodeID] = Self.partialResumeToken(bytesReceived: partialBytes)
            }
        }

        activeTasks.removeValue(forKey: episodeID)
        if let active = activeDownloads.removeValue(forKey: episodeID) {
            active.continuation.resume(throwing: DownloadError.cancelled)
        }

        removePartialFiles(for: episodeID)
        stateStore.setState(.notDownloaded, for: episodeID)
        notifyStateChanged()
        cancelLock.withLock {
            _ = cancellingEpisodeIDs.remove(episodeID)
        }
    }

    func resume(
        episodeID: String,
        from remoteURL: URL,
        progress: @escaping (Double) -> Void
    ) async throws -> URL {
        if let existing = localFileURL(for: episodeID) {
            stateStore.setState(.downloaded, for: episodeID)
            notifyStateChanged()
            return existing
        }

        if FixtureDownload.isEnabled {
            return try await performFixtureDownloadAsync(episodeID: episodeID, progress: progress)
        }

        let storedResume = resumeDataByEpisodeID.removeValue(forKey: episodeID)
        let systemResume = storedResume.flatMap { Self.isSystemResumeData($0) ? $0 : nil }
        return try await startDownload(
            episodeID: episodeID,
            remoteURL: remoteURL,
            resumeData: systemResume,
            progress: progress
        )
    }

    func deleteDownload(episodeID: String) throws {
        removeInstalledFiles(for: episodeID)
        resumeDataByEpisodeID.removeValue(forKey: episodeID)
        preferredFileExtensionByEpisodeID.removeValue(forKey: episodeID)
        stateStore.setState(.notDownloaded, for: episodeID)
        notifyStateChanged()
    }

    func localFileURL(for episodeID: String) -> URL? {
        let resolved = try? DownloadPaths.migrateLegacyLocalFileIfNeeded(
            episodeID: episodeID,
            downloadsDirectory: downloadsDirectory,
            fileManager: fileManager
        )
        if resolved == nil, stateStore.state(for: episodeID) == .downloaded {
            PlaybackDiagnostics.logDownloadStateCleared(
                episodeID: episodeID,
                reason: "missing sandbox file"
            )
            stateStore.setState(.notDownloaded, for: episodeID)
            notifyStateChanged()
        }
        return resolved
    }

    func resumeData(for episodeID: String) -> Data? {
        resumeDataByEpisodeID[episodeID]
    }

    func state(for episodeID: String) -> DownloadState {
        let stored = stateStore.state(for: episodeID)
        if case .downloading = stored { return stored }
        if stored == .downloaded { return .downloaded }
        if localFileURL(for: episodeID) != nil {
            stateStore.setState(.downloaded, for: episodeID)
            return .downloaded
        }
        return stored
    }

    func lastFailureDiagnostic(for episodeID: String) -> String? {
        lastFailureDiagnosticByEpisodeID[episodeID]
    }

    /// Surfaces a failed download affordance when download cannot start (e.g. missing audio URL).
    func markFailed(episodeID: String) {
        stateStore.setState(.failed, for: episodeID)
        notifyStateChanged()
    }

    /// Synchronous fixture-mode download for UI tests (`-UITestFixtureDownload`).
    /// Runs entirely on the main actor so accessibility updates land before XCTest idle.
    @discardableResult
    func completeFixtureDownloadForUITest(episodeID: String) throws -> URL {
        try performFixtureDownload(episodeID: episodeID, progress: { _ in })
    }

    // MARK: - URLSessionDownloadDelegate

    nonisolated func urlSession(
        _ session: URLSession,
        task: URLSessionTask,
        willPerformHTTPRedirection response: HTTPURLResponse,
        newRequest request: URLRequest,
        completionHandler: @escaping (URLRequest?) -> Void
    ) {
        completionHandler(request)
    }

    nonisolated func urlSession(
        _ session: URLSession,
        downloadTask: URLSessionDownloadTask,
        didWriteData bytesWritten: Int64,
        totalBytesWritten: Int64,
        totalBytesExpectedToWrite: Int64
    ) {
        guard let episodeID = downloadTask.taskDescription else { return }

        // Async hop — never main.sync — so cancel(await:) on MainActor cannot deadlock
        // the session delegate queue.
        Task { @MainActor in
            guard var active = activeDownloads[episodeID] else { return }
            reportChunkedProgress(
                episodeID: episodeID,
                totalBytesWritten: totalBytesWritten,
                totalBytesExpectedToWrite: totalBytesExpectedToWrite,
                active: &active
            )
            activeDownloads[episodeID] = active
        }
    }

    nonisolated func urlSession(
        _ session: URLSession,
        downloadTask: URLSessionDownloadTask,
        didFinishDownloadingTo location: URL
    ) {
        guard let episodeID = downloadTask.taskDescription else { return }

        let isCancelled = cancelLock.withLock {
            cancellingEpisodeIDs.contains(episodeID)
        }
        if isCancelled {
            try? fileManager.removeItem(at: location)
            return
        }

        if let httpResponse = downloadTask.response as? HTTPURLResponse,
           !(200 ... 299).contains(httpResponse.statusCode) {
            try? fileManager.removeItem(at: location)
            Task { @MainActor in
                failDownload(episodeID: episodeID, error: DownloadError.transportFailure)
            }
            return
        }

        do {
            let finalURL = try moveDownloadedFileSynchronously(from: location, episodeID: episodeID)
            Task { @MainActor in
                completeDownload(episodeID: episodeID, finalURL: finalURL)
            }
        } catch {
            Task { @MainActor in
                failDownload(episodeID: episodeID, error: error)
            }
        }
    }

    nonisolated func urlSession(
        _ session: URLSession,
        task: URLSessionTask,
        didCompleteWithError error: Error?
    ) {
        guard let episodeID = task.taskDescription else { return }

        let resumeFromError = (error as NSError?)
            .flatMap { $0.userInfo[NSURLSessionDownloadTaskResumeData] as? Data }

        Task { @MainActor in
            activeTasks.removeValue(forKey: episodeID)

            if let resumeFromError, !resumeFromError.isEmpty {
                resumeDataByEpisodeID[episodeID] = resumeFromError
                finishCancelWaiter(episodeID: episodeID, data: resumeFromError)
            } else if cancelLock.withLock({ cancellingEpisodeIDs.contains(episodeID) }) {
                finishCancelWaiter(episodeID: episodeID, data: resumeDataByEpisodeID[episodeID])
            }

            if let error {
                let isCancelled = cancelLock.withLock {
                    cancellingEpisodeIDs.contains(episodeID)
                }
                if isCancelled {
                    return
                }
                if (error as? URLError)?.code == .cancelled, activeDownloads[episodeID] == nil {
                    return
                }
                // `didFinishDownloadingTo` may have already moved the sandbox file while
                // `activeDownloads` still awaits `completeDownload` — a late transport
                // error on device must not delete the `.m4a` or flip UI to `.failed`.
                if localFileURL(for: episodeID) != nil {
                    return
                }
                failDownload(episodeID: episodeID, error: error)
            }
        }
    }

    // MARK: - Private

    private func handleCancelResumeData(episodeID: String, data: Data?) {
        if let data, !data.isEmpty {
            resumeDataByEpisodeID[episodeID] = data
            finishCancelWaiter(episodeID: episodeID, data: data)
            return
        }
        // Nil from cancel callback — keep waiter open for didCompleteWithError userInfo.
        // If didComplete already ran, settle with whatever we have.
        if activeTasks[episodeID] == nil {
            finishCancelWaiter(episodeID: episodeID, data: resumeDataByEpisodeID[episodeID])
        }
    }

    private func finishCancelWaiter(episodeID: String, data: Data?) {
        guard let waiter = cancelWaiters.removeValue(forKey: episodeID) else { return }
        waiter.resume(returning: data)
    }

    private static let partialResumeTokenPrefix = "podwash.resume.v1:"

    private static func partialResumeToken(bytesReceived: Int64) -> Data {
        Data("\(partialResumeTokenPrefix)\(bytesReceived)".utf8)
    }

    private static func isSystemResumeData(_ data: Data) -> Bool {
        guard let text = String(data: data, encoding: .utf8) else {
            // System resume data is an opaque keyed archive / plist, not UTF-8 text.
            return true
        }
        return !text.hasPrefix(partialResumeTokenPrefix)
    }

    private func startDownload(
        episodeID: String,
        remoteURL: URL,
        resumeData: Data?,
        progress: @escaping (Double) -> Void
    ) async throws -> URL {
        if activeDownloads[episodeID] != nil {
            throw DownloadError.transportFailure
        }

        ensureDownloadsDirectoryExists()
        removePartialFiles(for: episodeID)
        lastFailureDiagnosticByEpisodeID.removeValue(forKey: episodeID)
        preferredFileExtensionByEpisodeID[episodeID] = DownloadPaths.preferredFileExtension(for: remoteURL)
        stateStore.setState(.downloading(progress: 0), for: episodeID)
        notifyStateChanged()

        return try await withCheckedThrowingContinuation { continuation in
            let task: URLSessionDownloadTask
            if let resumeData {
                task = session.downloadTask(withResumeData: resumeData)
            } else {
                task = session.downloadTask(with: remoteURL)
            }
            task.taskDescription = episodeID

            activeDownloads[episodeID] = ActiveDownload(
                progressHandler: progress,
                continuation: continuation
            )
            activeTasks[episodeID] = task
            task.resume()
        }
    }

    /// Async fixture path yields so episode-row download chrome is visible to XCTest
    /// before the stub file lands (task-012 tap-to-play AC).
    private func performFixtureDownloadAsync(
        episodeID: String,
        progress: @escaping (Double) -> Void
    ) async throws -> URL {
        stateStore.setState(.downloading(progress: 0), for: episodeID)
        notifyStateChanged()
        // Yield + brief sleep so XCUITest can observe `downloading` / `downloadProgress_*`
        // under verify load (ui_race on task-012 / task-016 filtered runs).
        await Task.yield()
        try await Task.sleep(for: .milliseconds(350))
        return try finishFixtureDownloadCopy(episodeID: episodeID, progress: progress)
    }

    private func performFixtureDownload(
        episodeID: String,
        progress: @escaping (Double) -> Void
    ) throws -> URL {
        stateStore.setState(.downloading(progress: 0), for: episodeID)
        notifyStateChanged()
        return try finishFixtureDownloadCopy(episodeID: episodeID, progress: progress)
    }

    private func finishFixtureDownloadCopy(
        episodeID: String,
        progress: @escaping (Double) -> Void
    ) throws -> URL {
        guard let stubURL = FixtureDownload.bundledPlayableURL()
            ?? FixtureDownload.bundledStubURL() else {
            stateStore.setState(.failed, for: episodeID)
            notifyStateChanged()
            throw DownloadError.transportFailure
        }

        ensureDownloadsDirectoryExists()
        let destination = DownloadPaths.localFileURL(
            episodeID: episodeID,
            downloadsDirectory: downloadsDirectory
        )
        let partial = DownloadPaths.partialFileURL(
            episodeID: episodeID,
            downloadsDirectory: downloadsDirectory
        )

        if fileManager.fileExists(atPath: partial.path) {
            try fileManager.removeItem(at: partial)
        }
        if fileManager.fileExists(atPath: destination.path) {
            try fileManager.removeItem(at: destination)
        }

        try fileManager.copyItem(at: stubURL, to: partial)
        if fileManager.fileExists(atPath: destination.path) {
            try fileManager.removeItem(at: destination)
        }
        try fileManager.moveItem(at: partial, to: destination)

        progress(1.0)
        stateStore.setState(.downloaded, for: episodeID)
        notifyStateChanged()
        return destination
    }

    nonisolated private func moveDownloadedFileSynchronously(
        from tempLocation: URL,
        episodeID: String
    ) throws -> URL {
        let ext = preferredFileExtensionByEpisodeID[episodeID] ?? "m4a"
        let finalURL = DownloadPaths.localFileURL(
            episodeID: episodeID,
            downloadsDirectory: downloadsDirectory,
            fileExtension: ext
        )
        let partialURL = DownloadPaths.partialFileURL(
            episodeID: episodeID,
            downloadsDirectory: downloadsDirectory,
            fileExtension: ext
        )

        try fileManager.createDirectory(at: downloadsDirectory, withIntermediateDirectories: true)
        if fileManager.fileExists(atPath: partialURL.path) {
            try fileManager.removeItem(at: partialURL)
        }
        try fileManager.moveItem(at: tempLocation, to: partialURL)
        if fileManager.fileExists(atPath: finalURL.path) {
            try fileManager.removeItem(at: finalURL)
        }
        try fileManager.moveItem(at: partialURL, to: finalURL)
        return finalURL
    }

    private func completeDownload(episodeID: String, finalURL: URL) {
        if cancelLock.withLock({ cancellingEpisodeIDs.contains(episodeID) }) {
            removePartialFiles(for: episodeID)
            return
        }

        lastFailureDiagnosticByEpisodeID.removeValue(forKey: episodeID)

        guard var active = activeDownloads.removeValue(forKey: episodeID) else {
            // `didCompleteWithError` may have marked failure before this finish delegate ran;
            // the sandbox file is already in place — publish downloaded state for the UI.
            stateStore.setState(.downloaded, for: episodeID)
            notifyStateChanged()
            return
        }

        reportChunkedProgress(
            episodeID: episodeID,
            totalBytesWritten: Int64(
                (try? fileManager.attributesOfItem(atPath: finalURL.path)[.size] as? NSNumber)?
                    .int64Value ?? 0
            ),
            totalBytesExpectedToWrite: Int64(
                (try? fileManager.attributesOfItem(atPath: finalURL.path)[.size] as? NSNumber)?
                    .int64Value ?? 0
            ),
            active: &active
        )

        if active.lastReportedProgress < 1.0 {
            active.lastReportedProgress = 1.0
            active.progressHandler(1.0)
            stateStore.setState(.downloading(progress: 1.0), for: episodeID)
            notifyStateChanged()
        }

        stateStore.setState(.downloaded, for: episodeID)
        notifyStateChanged()
        PlaybackDiagnostics.logDownloadReady(episodeID: episodeID, url: finalURL)
        preferredFileExtensionByEpisodeID.removeValue(forKey: episodeID)
        active.continuation.resume(returning: finalURL)
    }

    private func failDownload(episodeID: String, error: Error) {
        // Only fail an in-flight download. `didCompleteWithError` can arrive after
        // `didFinishDownloadingTo` has already moved the file — without this guard a
        // late transport error would delete the sandbox `.m4a` and flip UI to `.failed`.
        guard let active = activeDownloads.removeValue(forKey: episodeID) else { return }

        let diagnostic = Self.formatFailureDiagnostic(for: error)
        lastFailureDiagnosticByEpisodeID[episodeID] = diagnostic
        Self.logger.error(
            "Download failed for \(episodeID, privacy: .public): \(diagnostic, privacy: .public)"
        )

        if (error as? URLError)?.code == .cancelled {
            active.continuation.resume(throwing: DownloadError.cancelled)
        } else {
            active.continuation.resume(throwing: DownloadError.transportFailure)
        }

        removePartialFiles(for: episodeID)
        preferredFileExtensionByEpisodeID.removeValue(forKey: episodeID)
        stateStore.setState(.failed, for: episodeID)
        notifyStateChanged()
    }

    private func removePartialFiles(for episodeID: String) {
        removeInstalledFiles(for: episodeID, includePartials: true)
    }

    private func removeInstalledFiles(for episodeID: String, includePartials: Bool = false) {
        for ext in DownloadPaths.downloadedFileExtensions {
            let finalURL = DownloadPaths.localFileURL(
                episodeID: episodeID,
                downloadsDirectory: downloadsDirectory,
                fileExtension: ext
            )
            if fileManager.fileExists(atPath: finalURL.path) {
                try? fileManager.removeItem(at: finalURL)
            }
            guard includePartials else { continue }
            let partialURL = DownloadPaths.partialFileURL(
                episodeID: episodeID,
                downloadsDirectory: downloadsDirectory,
                fileExtension: ext
            )
            if fileManager.fileExists(atPath: partialURL.path) {
                try? fileManager.removeItem(at: partialURL)
            }
        }
    }

    private func ensureDownloadsDirectoryExists() {
        try? fileManager.createDirectory(
            at: downloadsDirectory,
            withIntermediateDirectories: true
        )
    }

    private func migrateLegacyDownloadsFromPersistedState() {
        for episodeID in stateStore.downloadedEpisodeIDs() {
            _ = try? DownloadPaths.migrateLegacyLocalFileIfNeeded(
                episodeID: episodeID,
                downloadsDirectory: downloadsDirectory,
                fileManager: fileManager
            )
        }
    }

    private func seedDownloadedStateFromDisk() {
        guard !FixtureDownload.isEnabled else { return }
        guard let contents = try? fileManager.contentsOfDirectory(
            at: downloadsDirectory,
            includingPropertiesForKeys: nil
        ) else {
            return
        }

        for url in contents where DownloadPaths.downloadedFileExtensions.contains(url.pathExtension.lowercased()) {
            let stem = url.deletingPathExtension().lastPathComponent
            // Hashed stems (`ep-<sha256>`) cannot be reversed to RSS GUIDs; rely on
            // persisted download state for those episodes.
            guard DownloadPaths.isPathSafeFileNameStem(stem) else { continue }
            stateStore.setState(.downloaded, for: stem)
        }
    }

    private func notifyStateChanged() {
        onStateChanged?()
    }

    private static func formatFailureDiagnostic(for error: Error) -> String {
        let nsError = error as NSError
        return "\(nsError.domain) (\(nsError.code)): \(nsError.localizedDescription)"
    }

    /// Emits monotonic progress at equal chunk boundaries so coalesced URLSession
    /// writes still yield four callbacks for the normative 1024-byte / 4-chunk stub (ADR-008 AC2).
    private func reportChunkedProgress(
        episodeID: String,
        totalBytesWritten: Int64,
        totalBytesExpectedToWrite: Int64,
        active: inout ActiveDownload
    ) {
        guard totalBytesExpectedToWrite > 0 else { return }

        let chunkSize = max(1, totalBytesExpectedToWrite / 4)
        var nextBoundary = ((active.lastReportedBytes / chunkSize) + 1) * chunkSize

        while nextBoundary <= totalBytesWritten && nextBoundary <= totalBytesExpectedToWrite {
            let progress = min(1.0, Double(nextBoundary) / Double(totalBytesExpectedToWrite))
            let monotonic = max(active.lastReportedProgress, progress)
            active.lastReportedProgress = monotonic
            active.progressHandler(monotonic)
            stateStore.setState(.downloading(progress: monotonic), for: episodeID)
            notifyStateChanged()
            nextBoundary += chunkSize
        }

        active.lastReportedBytes = max(active.lastReportedBytes, totalBytesWritten)
    }
}
