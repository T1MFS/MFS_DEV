import CryptoKit
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
    private let lock = NSLock()
    private var _fingerprint: String?
    private var _issue: TLSIssue?

    /// SHA-256 (hex) of the server leaf certificate seen in the most recent handshake.
    var observedFingerprint: String? { lock.lock(); defer { lock.unlock() }; return _fingerprint }
    /// Why this delegate last refused to continue, if it did.
    var issue: TLSIssue? { lock.lock(); defer { lock.unlock() }; return _issue }

    private func record(fingerprint: String? = nil, issue: TLSIssue? = nil) {
        lock.lock(); defer { lock.unlock() }
        if let fingerprint { _fingerprint = fingerprint }
        if let issue { _issue = issue }
    }

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
            guard let identity else {
                record(issue: .noClientIdentity)
                return completionHandler(.cancelAuthenticationChallenge, nil)
            }
            completionHandler(.useCredential, URLCredential(identity: identity, certificates: nil, persistence: .forSession))
        case NSURLAuthenticationMethodServerTrust:
            guard space.host == host, let trust = space.serverTrust else {
                record(issue: .hostMismatch)
                return completionHandler(.cancelAuthenticationChallenge, nil)
            }
            record(fingerprint: Self.leafFingerprint(trust))
            guard !anchors.isEmpty else { return completionHandler(.performDefaultHandling, nil) }
            if Self.trusts(trust, host: host, anchors: anchors) {
                completionHandler(.useCredential, URLCredential(trust: trust))
            } else {
                record(issue: .untrustedServer)
                completionHandler(.cancelAuthenticationChallenge, nil)
            }
        default:
            completionHandler(.performDefaultHandling, nil)
        }
    }

    static func leafFingerprint(_ trust: SecTrust) -> String? {
        guard let chain = SecTrustCopyCertificateChain(trust) as? [SecCertificate], let leaf = chain.first else { return nil }
        let der = SecCertificateCopyData(leaf) as Data
        return SHA256.hash(data: der).map { String(format: "%02x", $0) }.joined()
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

extension ServiceConnection {
    /// `https://host[:port]/<path>` under the connection's base address, or nil if the base is not a valid https URL.
    func endpoint(_ path: String) -> URL? {
        let trimmed = baseURL.trimmingCharacters(in: .whitespaces)
        guard let base = URL(string: trimmed), base.scheme == "https", base.host != nil else { return nil }
        return base.appendingPathComponent(path)
    }
}

enum DigitalMeUploadError: LocalizedError, Equatable {
    case notConfirmed
    case invalidConnection
    case invalidRecord(Int)
    case securityCheckFailed(SecurityFailure)
    case securityBelowRequired(actual: SecurityLevel, required: SecurityLevel)
    case securityChanged(SecurityChange)
    case network(String)
    case server(Int)

    /// Whether the user can sensibly tap "Retry".
    var isRetryable: Bool {
        switch self {
        case .network: return true
        case .securityCheckFailed(let failure): return failure.isRetryable
        case .server(let status): return status >= 500 || status == 408 || status == 429
        default: return false
        }
    }

    var errorDescription: String? {
        switch self {
        case .notConfirmed: return "Upload was not confirmed."
        case .invalidConnection: return "The DigitalMe connection needs an https:// address."
        case .invalidRecord(let index): return "Record \(index + 1) needs a text \"type\" and \"time\"."
        case .securityCheckFailed(let failure): return "Nothing was uploaded. \(failure.explanation)"
        case .securityBelowRequired(let actual, let required):
            return "Nothing was uploaded. This connection is \(actual.shortLabel) but \(required.shortLabel) is required."
        case .securityChanged(let change): return "Nothing was uploaded. \(change.summary) Review and accept the change first."
        case .network(let message): return "Could not reach DigitalMe: \(message)"
        case .server(401): return "DigitalMe rejected the client certificate."
        case .server(403): return "DigitalMe does not accept this client certificate or endpoint for uploads."
        case .server(let status): return "DigitalMe returned HTTP \(status)."
        }
    }
}

struct DigitalMeUploadResult: Equatable {
    var inserted: Int
    /// What the connection looked like when the data was sent. Persist it so later changes are detected.
    var snapshot: SecuritySnapshot
    var change: SecurityChange
}

/// Where DigitalMe accepts a kind of record.
enum DigitalMeEndpoint {
    /// Tidepool diabetes data (`cbg`, `bolus`, `food`, ...) at `POST /data/upload`.
    case data
    /// Non-glucose body-state measurements (`type: "biometric"`) at `POST /biometrics/upload`.
    case biometrics

    var path: String {
        switch self {
        case .data: return "data/upload"
        case .biometrics: return "biometrics/upload"
        }
    }

    /// Whether a record's `type` belongs on this endpoint. Glucose never goes to biometrics.
    func accepts(type: String) -> Bool {
        switch self {
        case .data: return true
        case .biometrics: return type == "biometric"
        }
    }
}

/// Sends Tidepool-format records to DigitalMe's `POST /data/upload` (or `/biometrics/upload`) over mTLS.
/// Never retries on its own: the caller must pass `userConfirmed: true` for every attempt, including retries.
/// Before sending anything it re-checks the connection's security and refuses to send over a weaker or changed one.
struct DigitalMeUploadClient {
    let connection: ServiceConnection
    var session: URLSession

    init(connection: ServiceConnection, session: URLSession? = nil) {
        self.connection = connection
        self.session = session ?? MutualTLSSession.make(for: connection)
    }

    var uploadURL: URL? { url(for: .data) }

    func url(for endpoint: DigitalMeEndpoint) -> URL? { connection.endpoint(endpoint.path) }

    @discardableResult
    func upload(records: [[String: Any]], to endpoint: DigitalMeEndpoint = .data, userConfirmed: Bool, acknowledgedChange: Bool = false) async throws -> DigitalMeUploadResult {
        guard userConfirmed else { throw DigitalMeUploadError.notConfirmed }
        guard let url = url(for: endpoint) else { throw DigitalMeUploadError.invalidConnection }
        guard !records.isEmpty else { throw DigitalMeUploadError.invalidRecord(0) }
        for (index, record) in records.enumerated() {
            guard let type = record["type"] as? String, record["time"] is String, endpoint.accepts(type: type) else {
                throw DigitalMeUploadError.invalidRecord(index)
            }
        }

        let report = await ConnectionSecurityChecker(connection: connection, session: session).check()
        guard let snapshot = report.snapshot else {
            throw DigitalMeUploadError.securityCheckFailed(report.failure ?? .unreachable("Unknown error"))
        }
        guard snapshot.level >= connection.requiredSecurity else {
            throw DigitalMeUploadError.securityBelowRequired(actual: snapshot.level, required: connection.requiredSecurity)
        }
        let change = SecurityChange.compare(previous: connection.lastSnapshot, current: snapshot)
        if change.needsAcknowledgement && !acknowledgedChange { throw DigitalMeUploadError.securityChanged(change) }

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
        return DigitalMeUploadResult(inserted: (body?["inserted_count"] as? Int) ?? records.count, snapshot: snapshot, change: change)
    }
}
