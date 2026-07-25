//
//  CloudAdSpanClient.swift
//  PodWash
//
//  The app sends text derived from its local Whisper transcript, never audio.
//

import Foundation

enum CloudAdDetectionError: LocalizedError, Equatable {
    case consentRequired
    case unavailable
    case invalidResponse

    var errorDescription: String? {
        switch self {
        case .consentRequired: return "Cloud transcript processing is not enabled."
        case .unavailable: return "Cloud ad detection is unavailable."
        case .invalidResponse: return "Cloud ad detection returned an invalid result."
        }
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
    let endpoint: URL?
    let consentGranted: @Sendable () -> Bool

    static func applicationDefault(consentGranted: @escaping @Sendable () -> Bool) -> Self {
        let raw = Bundle.main.object(forInfoDictionaryKey: "PodWashCloudAdEndpoint") as? String
        return Self(endpoint: raw.flatMap(URL.init(string:)), consentGranted: consentGranted)
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
        guard let http = response as? HTTPURLResponse, (200..<300).contains(http.statusCode) else {
            throw CloudAdDetectionError.unavailable
        }
        let body: ResponseBody
        do { body = try JSONDecoder().decode(ResponseBody.self, from: data) }
        catch { throw CloudAdDetectionError.invalidResponse }
        guard body.status == "complete" else { throw CloudAdDetectionError.unavailable }
        return body.spans.compactMap { span in
            guard span.start.isFinite, span.end.isFinite, span.end > span.start else { return nil }
            return ContentSegment(start: span.start, end: span.end)
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
