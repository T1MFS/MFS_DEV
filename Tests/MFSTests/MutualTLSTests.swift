import XCTest

private final class StubProtocol: URLProtocol {
    static var handler: ((URLRequest) -> (Int, Data))?
    static var lastRequest: URLRequest?

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        StubProtocol.lastRequest = request
        let (status, body) = StubProtocol.handler?(request) ?? (500, Data())
        let response = HTTPURLResponse(url: request.url!, statusCode: status, httpVersion: nil, headerFields: nil)!
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: body)
        client?.urlProtocolDidFinishLoading(self)
    }
    override func stopLoading() {}
}

final class MutualTLSTests: XCTestCase {
    private let record: [String: Any] = ["type": "cbg", "time": "2024-10-07T12:34:56Z", "value": 121]

    private func client(base: String = "https://digitalme.example:8443/") -> DigitalMeUploadClient {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [StubProtocol.self]
        return DigitalMeUploadClient(
            connection: ServiceConnection(name: "DigitalMe", baseURL: base, auth: .mutualTLS),
            session: URLSession(configuration: configuration))
    }

    func testUploadURLAppendsPath() {
        XCTAssertEqual(client().uploadURL?.absoluteString, "https://digitalme.example:8443/data/upload")
        XCTAssertNil(client(base: "http://digitalme.example").uploadURL)
    }

    func testNeverUploadsWithoutConfirmation() async {
        StubProtocol.lastRequest = nil
        do {
            _ = try await client().upload(records: [record], userConfirmed: false)
            XCTFail("expected error")
        } catch {
            XCTAssertEqual(error as? DigitalMeUploadError, .notConfirmed)
        }
        XCTAssertNil(StubProtocol.lastRequest)
    }

    func testRejectsRecordsWithoutTypeOrTime() async {
        do {
            _ = try await client().upload(records: [record, ["value": 1]], userConfirmed: true)
            XCTFail("expected error")
        } catch {
            XCTAssertEqual(error as? DigitalMeUploadError, .invalidRecord(1))
        }
    }

    func testSuccessReturnsInsertedCount() async throws {
        StubProtocol.handler = { _ in (201, Data(#"{"inserted_count":1}"#.utf8)) }
        let count = try await client().upload(records: [record], userConfirmed: true)
        XCTAssertEqual(count, 1)
        XCTAssertEqual(StubProtocol.lastRequest?.httpMethod, "POST")
        XCTAssertEqual(StubProtocol.lastRequest?.url?.path, "/data/upload")
    }

    func testRetryableClassification() async {
        for (status, retryable) in [(401, false), (403, false), (400, false), (503, true), (429, true)] {
            StubProtocol.handler = { _ in (status, Data()) }
            do {
                _ = try await client().upload(records: [record], userConfirmed: true)
                XCTFail("expected error")
            } catch {
                let failure = error as? DigitalMeUploadError
                XCTAssertEqual(failure, .server(status))
                XCTAssertEqual(failure?.isRetryable, retryable, "status \(status)")
            }
        }
    }

    func testClientCertificateChallengeCancelledWithoutIdentity() {
        let delegate = MutualTLSDelegate(host: "digitalme.example", identity: nil, anchors: [])
        let space = URLProtectionSpace(host: "digitalme.example", port: 8443, protocol: "https", realm: nil,
                                       authenticationMethod: NSURLAuthenticationMethodClientCertificate)
        let challenge = URLAuthenticationChallenge(protectionSpace: space, proposedCredential: nil, previousFailureCount: 0,
                                                   failureResponse: nil, error: nil, sender: StubSender())
        let done = expectation(description: "challenge")
        delegate.urlSession(.shared, didReceive: challenge) { disposition, credential in
            XCTAssertEqual(disposition, .cancelAuthenticationChallenge)
            XCTAssertNil(credential)
            done.fulfill()
        }
        wait(for: [done], timeout: 1)
    }
}

private final class StubSender: NSObject, URLAuthenticationChallengeSender {
    func use(_ credential: URLCredential, for challenge: URLAuthenticationChallenge) {}
    func continueWithoutCredential(for challenge: URLAuthenticationChallenge) {}
    func cancel(_ challenge: URLAuthenticationChallenge) {}
}
