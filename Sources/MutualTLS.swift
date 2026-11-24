import Foundation
import Security

/// Keychain access for the mTLS client identity and the private CA used to validate the server.
enum MutualTLSKeychain {
    static func identity(label: String) -> SecIdentity? {
        let query: [String: Any] = [
            kSecClass as String: kSecClassIdentity,
            kSecAttrLabel as String: label,
            kSecReturnRef as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne,
        ]
        var result: CFTypeRef?
        guard SecItemCopyMatching(query as CFDictionary, &result) == errSecSuccess, let result else { return nil }
        return (result as! SecIdentity)
    }

    /// Stores a CA certificate (DER or PEM-decoded DER) that is trusted only for the connection that references it.
    static func importCA(der: Data, label: String) throws {
        guard let certificate = SecCertificateCreateWithData(nil, der as CFData) else {
            throw MutualTLSError.invalidCertificate
        }
        deleteCA(label: label)
        let status = SecItemAdd([
            kSecClass as String: kSecClassCertificate,
            kSecValueRef as String: certificate,
            kSecAttrLabel as String: label,
        ] as CFDictionary, nil)
        guard status == errSecSuccess else { throw MutualTLSError.keychain(status) }
    }

    static func ca(label: String) -> SecCertificate? {
        let query: [String: Any] = [
            kSecClass as String: kSecClassCertificate,
            kSecAttrLabel as String: label,
            kSecReturnRef as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne,
        ]
        var result: CFTypeRef?
        guard SecItemCopyMatching(query as CFDictionary, &result) == errSecSuccess, let result else { return nil }
        return (result as! SecCertificate)
    }

    static func deleteCA(label: String) {
        SecItemDelete([kSecClass as String: kSecClassCertificate, kSecAttrLabel as String: label] as CFDictionary)
    }
}

enum MutualTLSError: LocalizedError {
    case invalidCertificate
    case keychain(OSStatus)

    var errorDescription: String? {
        switch self {
        case .invalidCertificate: return "That file is not a valid DER-encoded certificate."
        case .keychain(let status): return "Could not store the certificate (code \(status))."
        }
    }
}

/// Answers TLS challenges for one service: presents the client identity and, when a private CA is configured,
/// validates the server against only that CA (system trust is not used in that case).
final class MutualTLSDelegate: NSObject, URLSessionDelegate {
    private let host: String
    private let identity: SecIdentity?
    private let anchors: [SecCertificate]

    init(host: String, identity: SecIdentity?, anchors: [SecCertificate]) {
        self.host = host
        self.identity = identity
        self.anchors = anchors
    }

    func urlSession(_ session: URLSession, didReceive challenge: URLAuthenticationChallenge,
                    completionHandler: @escaping (URLSession.AuthChallengeDisposition, URLCredential?) -> Void) {
        let space = challenge.protectionSpace
        switch space.authenticationMethod {
        case NSURLAuthenticationMethodClientCertificate:
            guard let identity else { return completionHandler(.cancelAuthenticationChallenge, nil) }
            completionHandler(.useCredential, URLCredential(identity: identity, certificates: nil, persistence: .forSession))
        case NSURLAuthenticationMethodServerTrust:
            guard space.host == host, let trust = space.serverTrust else {
                return completionHandler(.cancelAuthenticationChallenge, nil)
            }
            guard !anchors.isEmpty else { return completionHandler(.performDefaultHandling, nil) }
            if Self.trusts(trust, host: host, anchors: anchors) {
                completionHandler(.useCredential, URLCredential(trust: trust))
            } else {
                completionHandler(.cancelAuthenticationChallenge, nil)
            }
        default:
            completionHandler(.performDefaultHandling, nil)
        }
    }

    static func trusts(_ trust: SecTrust, host: String, anchors: [SecCertificate]) -> Bool {
        SecTrustSetPolicies(trust, SecPolicyCreateSSL(true, host as CFString))
        SecTrustSetAnchorCertificates(trust, anchors as CFArray)
        SecTrustSetAnchorCertificatesOnly(trust, true)
        return SecTrustEvaluateWithError(trust, nil)
    }
}

enum MutualTLSSession {
    static func make(for connection: ServiceConnection) -> URLSession {
        let host = URL(string: connection.baseURL.trimmingCharacters(in: .whitespaces))?.host ?? ""
        let identity = connection.auth == .mutualTLS ? connection.identityLabel.flatMap(MutualTLSKeychain.identity) : nil
        let anchors = connection.caLabel.flatMap(MutualTLSKeychain.ca).map { [$0] } ?? []
        let configuration = URLSessionConfiguration.ephemeral
        configuration.tlsMinimumSupportedProtocolVersion = .TLSv12
        return URLSession(configuration: configuration,
                          delegate: MutualTLSDelegate(host: host, identity: identity, anchors: anchors),
                          delegateQueue: nil)
    }
}

enum DigitalMeUploadError: LocalizedError, Equatable {
    case notConfirmed
    case invalidConnection
    case invalidRecord(Int)
    case network(String)
    case server(Int)

    /// Whether the user can sensibly tap "Retry".
    var isRetryable: Bool {
        switch self {
        case .network: return true
        case .server(let status): return status >= 500 || status == 408 || status == 429
        default: return false
        }
    }

    var errorDescription: String? {
        switch self {
        case .notConfirmed: return "Upload was not confirmed."
        case .invalidConnection: return "The DigitalMe connection needs an https:// address."
        case .invalidRecord(let index): return "Record \(index + 1) needs a text \"type\" and \"time\"."
        case .network(let message): return "Could not reach DigitalMe: \(message)"
        case .server(401): return "DigitalMe rejected the client certificate."
        case .server(403): return "This client certificate is not authorized by DigitalMe."
        case .server(let status): return "DigitalMe returned HTTP \(status)."
        }
    }
}

/// Sends Tidepool-format records to DigitalMe's `POST /data/upload` over mTLS.
/// Never retries on its own: the caller must pass `userConfirmed: true` for every attempt, including retries.
struct DigitalMeUploadClient {
    let connection: ServiceConnection
    var session: URLSession

    init(connection: ServiceConnection, session: URLSession? = nil) {
        self.connection = connection
        self.session = session ?? MutualTLSSession.make(for: connection)
    }

    var uploadURL: URL? {
        let trimmed = connection.baseURL.trimmingCharacters(in: .whitespaces)
        guard let base = URL(string: trimmed), base.scheme == "https", base.host != nil else { return nil }
        return base.appendingPathComponent("data/upload")
    }

    /// Returns the number of records DigitalMe stored.
    @discardableResult
    func upload(records: [[String: Any]], userConfirmed: Bool) async throws -> Int {
        guard userConfirmed else { throw DigitalMeUploadError.notConfirmed }
        guard let url = uploadURL else { throw DigitalMeUploadError.invalidConnection }
        for (index, record) in records.enumerated() where !(record["type"] is String && record["time"] is String) {
            throw DigitalMeUploadError.invalidRecord(index)
        }
        guard !records.isEmpty else { throw DigitalMeUploadError.invalidRecord(0) }

        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try JSONSerialization.data(withJSONObject: records)

        let data: Data
        let response: URLResponse
        do {
            (data, response) = try await session.data(for: request)
        } catch {
            throw DigitalMeUploadError.network(error.localizedDescription)
        }
        guard let http = response as? HTTPURLResponse else { throw DigitalMeUploadError.network("Invalid response") }
        guard (200..<300).contains(http.statusCode) else { throw DigitalMeUploadError.server(http.statusCode) }
        let body = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
        return (body?["inserted_count"] as? Int) ?? records.count
    }
}
