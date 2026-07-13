//
//  StubDownloadURLProtocol.swift
//  PodWashTests
//
//  Slice 10 — Normative URLProtocol stub for download unit tests (ADR-008 §8).
//  Serves stub_episode_audio.bin in async HTTP chunks for AC2/AC3 determinism.
//

import Foundation

/// Offline transport stub for fixture enclosure URLs (`fixture.podwash.tests/audio/*`).
/// Contract: async inter-chunk delivery, sync `chunksDelivered` gate, resume offset support.
final class StubDownloadURLProtocol: URLProtocol {

    // MARK: - Normative configuration (ADR-008 §8)

    nonisolated(unsafe) static var chunkCount: Int = 4
    nonisolated(unsafe) static var chunkDelay: TimeInterval = 0.05
    nonisolated(unsafe) private(set) static var chunksDelivered: Int = 0

    private static let syncQueue = DispatchQueue(label: "StubDownloadURLProtocol.sync")
    private static let chunkQueue = DispatchQueue(label: "StubDownloadURLProtocol.chunks")
    nonisolated(unsafe) private static var globalPendingWork: [DispatchWorkItem] = []

    // MARK: - Reset

    static func reset() {
        syncQueue.sync {
            globalPendingWork.forEach { $0.cancel() }
            globalPendingWork.removeAll()
            chunksDelivered = 0
            chunkCount = 4
            chunkDelay = 0.05
        }
    }

    // MARK: - URLProtocol

    override class func canInit(with request: URLRequest) -> Bool {
        guard let url = request.url, let host = url.host else { return false }
        return host == "fixture.podwash.tests" && url.path.hasPrefix("/audio/")
    }

    override class func canonicalRequest(for request: URLRequest) -> URLRequest {
        request
    }

    private var instanceWorkItems: [DispatchWorkItem] = []
    private var cancelled = false

    override func startLoading() {
        guard let client, let url = request.url else { return }

        if url.path.contains("/transport-error") {
            let response = HTTPURLResponse(
                url: url,
                statusCode: 500,
                httpVersion: "HTTP/1.1",
                headerFields: [:]
            )!
            client.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
            client.urlProtocolDidFinishLoading(self)
            return
        }

        if url.path.contains("/redirect/") {
            // URLProtocol must report redirects via wasRedirectedTo — finishing with a
            // bare 302 leaves downloadTask.response at 302 and DownloadManager correctly
            // maps non-2xx to transportFailure (task-001 AC1).
            let locationURL = URL(string: "https://fixture.podwash.tests/audio/alpha.m4a")!
            let response = HTTPURLResponse(
                url: url,
                statusCode: 302,
                httpVersion: "HTTP/1.1",
                headerFields: ["Location": locationURL.absoluteString]
            )!
            var redirectRequest = URLRequest(url: locationURL)
            redirectRequest.httpMethod = request.httpMethod
            client.urlProtocol(self, wasRedirectedTo: redirectRequest, redirectResponse: response)
            return
        }

        let payload: Data
        do {
            payload = try Self.loadPayload()
        } catch {
            client.urlProtocol(self, didFailWithError: error)
            return
        }

        let startOffset = Self.byteOffset(for: request)
        guard startOffset < payload.count else {
            client.urlProtocol(self, didFailWithError: URLError(.badServerResponse))
            return
        }

        let remaining = payload.count - startOffset
        let response = HTTPURLResponse(
            url: url,
            statusCode: 200,
            httpVersion: "HTTP/1.1",
            headerFields: [
                "Content-Length": String(remaining),
                "Accept-Ranges": "bytes",
            ]
        )!

        client.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        scheduleChunkDelivery(payload: payload, startOffset: startOffset, client: client)
    }

    override func stopLoading() {
        cancelled = true
        instanceWorkItems.forEach { $0.cancel() }
        instanceWorkItems.removeAll()
    }

    // MARK: - Chunk delivery

    private func scheduleChunkDelivery(payload: Data, startOffset: Int, client: URLProtocolClient) {
        let totalBytes = payload.count - startOffset
        let chunkSize = max(1, (totalBytes + Self.chunkCount - 1) / Self.chunkCount)

        func deliverChunk(at index: Int) {
            guard !cancelled else { return }

            let chunkStart = startOffset + index * chunkSize
            guard chunkStart < payload.count else {
                client.urlProtocolDidFinishLoading(self)
                return
            }

            let chunkEnd = min(chunkStart + chunkSize, payload.count)
            let chunk = payload.subdata(in: chunkStart ..< chunkEnd)
            client.urlProtocol(self, didLoad: chunk)

            Self.syncQueue.sync {
                Self.chunksDelivered += 1
            }

            let nextIndex = index + 1
            let nextStart = startOffset + nextIndex * chunkSize
            if nextStart >= payload.count {
                client.urlProtocolDidFinishLoading(self)
                return
            }

            let work = DispatchWorkItem { [weak self] in
                guard let self, !self.cancelled else { return }
                deliverChunk(at: nextIndex)
            }
            instanceWorkItems.append(work)
            Self.syncQueue.sync {
                Self.globalPendingWork.append(work)
            }
            Self.chunkQueue.asyncAfter(deadline: .now() + Self.chunkDelay, execute: work)
        }

        deliverChunk(at: 0)
    }

    // MARK: - Payload + resume offset

    private static func loadPayload() throws -> Data {
        let bundle = Bundle(for: StubDownloadURLProtocol.self)
        if let url = bundle.url(
            forResource: "stub_episode_audio",
            withExtension: "bin",
            subdirectory: "Fixtures/downloads"
        ) ?? bundle.url(forResource: "stub_episode_audio", withExtension: "bin") {
            let data = try Data(contentsOf: url)
            guard data.count == 1024 else {
                throw URLError(.badServerResponse)
            }
            return data
        }

        let sourceURL = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .appendingPathComponent("Fixtures/downloads/stub_episode_audio.bin")
        guard FileManager.default.fileExists(atPath: sourceURL.path) else {
            throw URLError(.fileDoesNotExist)
        }
        let data = try Data(contentsOf: sourceURL)
        guard data.count == 1024 else {
            throw URLError(.badServerResponse)
        }
        return data
    }

    private static func byteOffset(for request: URLRequest) -> Int {
        if let range = request.value(forHTTPHeaderField: "Range"),
           range.hasPrefix("bytes=") {
            let spec = String(range.dropFirst("bytes=".count))
            if let dash = spec.firstIndex(of: "-") {
                let startText = spec[..<dash]
                if let start = Int(startText) {
                    return max(0, start)
                }
            }
        }
        return 0
    }
}
