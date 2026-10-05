import XCTest
@testable import PodWash

private struct CloudCredentialsStub: CloudCredentialProviding {
    func authorizationHeaders() async throws -> [String: String] {
        ["Authorization": "Bearer fixture", "X-Firebase-AppCheck": "fixture"]
    }
}

private final class CloudAdURLProtocol: URLProtocol {
    nonisolated(unsafe) static var handler: ((URLRequest) throws -> (HTTPURLResponse, Data))?

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        do {
            guard let handler = Self.handler else { throw URLError(.unknown) }
            let (response, data) = try handler(request)
            client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
            client?.urlProtocol(self, didLoad: data)
            client?.urlProtocolDidFinishLoading(self)
        } catch {
            client?.urlProtocol(self, didFailWithError: error)
        }
    }

    override func stopLoading() {}

    static func bodyData(from request: URLRequest) throws -> Data {
        if let body = request.httpBody { return body }
        guard let stream = request.httpBodyStream else { throw URLError(.cannotDecodeContentData) }
        stream.open()
        defer { stream.close() }
        var result = Data()
        var buffer = [UInt8](repeating: 0, count: 4_096)
        while stream.hasBytesAvailable {
            let count = stream.read(&buffer, maxLength: buffer.count)
            if count < 0 { throw stream.streamError ?? URLError(.cannotDecodeContentData) }
            if count == 0 { break }
            result.append(buffer, count: count)
        }
        return result
    }
}

@MainActor
final class CloudAdSpanClientTests: XCTestCase {
    override func tearDown() {
        CloudAdURLProtocol.handler = nil
        super.tearDown()
    }

    private func client() -> CloudAdSpanClient {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [CloudAdURLProtocol.self]
        return CloudAdSpanClient(
            configuration: CloudAdDetectionConfiguration(
                endpoint: URL(string: "https://fixture.podwash.tests")!,
                consentGranted: { true }
            ),
            credentials: CloudCredentialsStub(),
            session: URLSession(configuration: configuration)
        )
    }

    func testSchemaV2RequestCarriesContextAndDecodesTypedSegment() async throws {
        CloudAdURLProtocol.handler = { request in
            XCTAssertEqual(request.url?.path, "/v1/ad-spans")
            XCTAssertEqual(request.value(forHTTPHeaderField: "Authorization"), "Bearer fixture")
            let data = try CloudAdURLProtocol.bodyData(from: request)
            let json = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
            let episode = try XCTUnwrap(json["episode"] as? [String: Any])
            XCTAssertEqual(episode["show"] as? String, "Fixture Show")
            XCTAssertEqual(episode["title"] as? String, "Fixture Episode")
            let sentences = try XCTUnwrap(json["sentences"] as? [[String: Any]])
            XCTAssertEqual(sentences.count, 2, "punctuation and the 18-second cap must bound sentences")

            let payload = Data("""
            {"status":"complete","schema_version":2,"pipeline_version":"jev-1.13.0:typed-blocks-v7.1:2","segments":[{"start_sentence_id":0,"end_sentence_id":0,"start":0.0,"end":2.0,"reasons":["paid_ad"]}],"job_id":"fixture"}
            """.utf8)
            return (HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!, payload)
        }

        let segments = try await client().detectAdSpans(
            in: [
                TimedWord(word: "First", start: 0, end: 1),
                TimedWord(word: "sentence.", start: 1.1, end: 2),
                TimedWord(word: "Long", start: 2.1, end: 10),
                TimedWord(word: "sentence", start: 10.1, end: 20.2),
            ],
            episodeID: "episode",
            context: SegmentationContext(
                showTitle: "Fixture Show",
                showDescription: "Description",
                episodeTitle: "Fixture Episode",
                episodeDescription: "Episode description"
            )
        )

        XCTAssertEqual(segments, [ContentSegment(
            start: 0,
            end: 2,
            startSentenceID: 0,
            endSentenceID: 0,
            reasons: [.paidAd]
        )])
    }

    func testRejectsOldSchemaResponse() async {
        CloudAdURLProtocol.handler = { request in
            let payload = Data("""
            {"status":"complete","schema_version":1,"pipeline_version":"cloud-gemini-v1","segments":[],"job_id":"fixture"}
            """.utf8)
            return (HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!, payload)
        }

        do {
            _ = try await client().detectAdSpans(
                in: [TimedWord(word: "Hello.", start: 0, end: 1)],
                episodeID: "episode"
            )
            XCTFail("Old response schema should be rejected")
        } catch {
            XCTAssertEqual(error as? CloudAdDetectionError, .invalidResponse)
        }
    }
}
