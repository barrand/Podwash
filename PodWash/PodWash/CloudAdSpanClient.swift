//
//  CloudAdSpanClient.swift
//  PodWash
//
//  The app sends text derived from its local Whisper transcript, never audio.
//

import Foundation

enum CloudAdDetectionError: LocalizedError, Equatable {
    case consentRequired
    case firebaseNotConfigured
    case firebaseAuth
    case appCheck
    case unavailable
    case unauthorized
    case rateLimited
    case serviceUnavailable
    case invalidResponse
    case processing

    var errorDescription: String? {
        switch self {
        case .consentRequired: return "Cloud transcript processing is not enabled."
        case .firebaseNotConfigured: return "Firebase is not configured in this build."
        case .firebaseAuth: return "Firebase anonymous authentication failed."
        case .appCheck: return "Firebase App Check could not create a token."
        case .unavailable: return "Cloud ad detection is unavailable."
        case .unauthorized: return "Cloud ad detection credentials were rejected."
        case .rateLimited: return "Cloud ad detection is temporarily rate limited."
        case .serviceUnavailable: return "Cloud ad detection is temporarily unavailable."
        case .invalidResponse: return "Cloud ad detection returned an invalid result."
        case .processing: return "Cloud ad detection is still processing."
        }
    }
}

/// Stable, transcript-free diagnostic category exposed to preparation UI and logs.
enum CloudAdDetectionFailureCategory: String, Codable, Equatable, Sendable {
    case disabled
    case configuration
    case firebaseAuth
    case appCheck
    case credentials
    case unauthorized
    case network
    case rateLimited
    case serviceUnavailable
    case invalidResponse
    case timeout

    static func classify(_ error: Error) -> Self {
        if let cloud = error as? CloudAdDetectionError {
            switch cloud {
            case .consentRequired: return .disabled
            case .firebaseNotConfigured: return .configuration
            case .firebaseAuth: return .firebaseAuth
            case .appCheck: return .appCheck
            case .unauthorized: return .unauthorized
            case .rateLimited: return .rateLimited
            case .serviceUnavailable: return .serviceUnavailable
            case .invalidResponse: return .invalidResponse
            case .processing: return .timeout
            case .unavailable: return .credentials
            }
        }
        if let url = error as? URLError {
            return url.code == .timedOut ? .timeout : .network
        }
        return .network
    }
}

nonisolated protocol CloudAdSpanDetecting: Sendable {
    func detectAdSpans(in transcript: [TimedWord], episodeID: String) async throws -> [ContentSegment]
}

nonisolated protocol CloudCredentialProviding: Sendable {
    func authorizationHeaders() async throws -> [String: String]
}

nonisolated struct UnavailableCloudCredentials: CloudCredentialProviding {
    func authorizationHeaders() async throws -> [String: String] { throw CloudAdDetectionError.unavailable }
}

nonisolated struct CloudAdDetectionConfiguration: Sendable {
    /// Build settings should inject this into Info.plist. Keep the deployed
    /// gateway as a code fallback because Xcode can omit custom Info keys when a
    /// hand-authored plist and generated keys are combined.
    private static let productionEndpoint = "https://podwash-gemini-155728924073.us-central1.run.app"

    let endpoint: URL?
    let consentGranted: @Sendable () -> Bool

    static func applicationDefault(consentGranted: @escaping @Sendable () -> Bool) -> Self {
        let raw = Bundle.main.object(forInfoDictionaryKey: "PodWashCloudAdEndpoint") as? String
        let endpoint = raw.flatMap(URL.init(string:)) ?? URL(string: productionEndpoint)
        return Self(endpoint: endpoint, consentGranted: consentGranted)
    }
}

nonisolated struct CloudAdSpanClient: CloudAdSpanDetecting {
    private struct Sentence: Codable, Sendable {
        let id: Int
        let start: Double
        let end: Double
        let text: String
    }

    private struct RequestBody: Codable, Sendable {
        let requestID: String
        let episodeID: String
        let sentences: [Sentence]

        enum CodingKeys: String, CodingKey { case requestID = "request_id", episodeID = "episode_id", sentences }
    }

    private struct ResponseBody: Decodable, Sendable {
        struct Span: Decodable, Sendable {
            let start: Double
            let end: Double
        }
        let status: String
        let spans: [Span]
        let jobID: String?

        enum CodingKeys: String, CodingKey {
            case status, spans
            case jobID = "job_id"
        }
    }

    private let configuration: CloudAdDetectionConfiguration
    private let credentials: any CloudCredentialProviding
    private let session: URLSession

    init(
        configuration: CloudAdDetectionConfiguration,
        credentials: any CloudCredentialProviding = FirebaseCloudCredentials(),
        session: URLSession = .shared
    ) {
        self.configuration = configuration
        self.credentials = credentials
        self.session = session
    }

    func detectAdSpans(in transcript: [TimedWord], episodeID: String) async throws -> [ContentSegment] {
        guard configuration.consentGranted() else { throw CloudAdDetectionError.consentRequired }
        guard let endpoint = configuration.endpoint else { throw CloudAdDetectionError.unavailable }
        let sentences = Self.sentences(from: transcript)
        guard !sentences.isEmpty else { return [] }
        var request = URLRequest(url: endpoint.appendingPathComponent("v1/ad-spans"))
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        for (name, value) in try await credentials.authorizationHeaders() {
            request.setValue(value, forHTTPHeaderField: name)
        }
        request.httpBody = try JSONEncoder().encode(RequestBody(
            requestID: UUID().uuidString,
            episodeID: episodeID,
            sentences: sentences
        ))
        let (data, response) = try await session.data(for: request)
        guard let http = response as? HTTPURLResponse else { throw CloudAdDetectionError.unavailable }
        guard (200..<300).contains(http.statusCode) else { throw Self.httpError(http.statusCode) }
        var body: ResponseBody
        do { body = try JSONDecoder().decode(ResponseBody.self, from: data) }
        catch { throw CloudAdDetectionError.invalidResponse }
        if body.status == "processing" {
            guard let jobID = body.jobID, !jobID.isEmpty else { throw CloudAdDetectionError.invalidResponse }
            body = try await poll(jobID: jobID, endpoint: endpoint)
        }
        guard body.status == "complete" else { throw CloudAdDetectionError.processing }
        return body.spans.compactMap { span in
            guard span.start.isFinite, span.end.isFinite, span.end > span.start else { return nil }
            return ContentSegment(start: span.start, end: span.end)
        }
    }

    /// A duplicate request can be owned by another Cloud Run instance. Poll the
    /// server-owned job instead of converting that normal condition into a failure.
    private func poll(jobID: String, endpoint: URL) async throws -> ResponseBody {
        // A duplicate POST can legitimately be owned by Cloud Run for longer than a
        // few seconds. Keep the same server job ID and use bounded backoff instead
        // of turning normal work into an invisible no-ad result.
        let delays: [TimeInterval] = [1, 2, 5, 10, 20]
        for delay in delays {
            try await Task.sleep(for: .seconds(delay))
            var request = URLRequest(
                url: endpoint
                    .appendingPathComponent("v1/ad-spans")
                    .appendingPathComponent(jobID)
            )
            request.httpMethod = "GET"
            for (name, value) in try await credentials.authorizationHeaders() {
                request.setValue(value, forHTTPHeaderField: name)
            }
            let (data, response) = try await session.data(for: request)
            guard let http = response as? HTTPURLResponse else { throw CloudAdDetectionError.unavailable }
            guard (200..<300).contains(http.statusCode) else { throw Self.httpError(http.statusCode) }
            guard let body = try? JSONDecoder().decode(ResponseBody.self, from: data) else {
                throw CloudAdDetectionError.invalidResponse
            }
            if body.status == "complete" { return body }
        }
        throw CloudAdDetectionError.processing
    }

    private static func httpError(_ status: Int) -> CloudAdDetectionError {
        switch status {
        case 401, 403: return .unauthorized
        case 429: return .rateLimited
        case 500...599: return .serviceUnavailable
        default: return .unavailable
        }
    }

    private static func sentences(from transcript: [TimedWord]) -> [Sentence] {
        var result: [Sentence] = []
        var words: [TimedWord] = []
        func finish() {
            guard let first = words.first, let last = words.last else { return }
            let text = words.map(\.word).joined(separator: " ").trimmingCharacters(in: .whitespacesAndNewlines)
            guard !text.isEmpty else { words = []; return }
            result.append(Sentence(id: result.count, start: first.start, end: last.end, text: text))
            words = []
        }
        for word in transcript where word.start.isFinite && word.end.isFinite && word.end > word.start {
            if let prior = words.last, word.start - prior.end >= 18 { finish() }
            words.append(word)
            if word.word.rangeOfCharacter(from: CharacterSet(charactersIn: ".?!")) != nil || words.count >= 80 { finish() }
        }
        finish()
        return result
    }
}
