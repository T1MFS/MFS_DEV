import Foundation

/// How well a connection is protected, from weakest to strongest.
enum SecurityLevel: Int, Codable, CaseIterable, Comparable, Identifiable {
    case none = 0, tls = 1, mtls = 2

    var id: Int { rawValue }
    static func < (lhs: SecurityLevel, rhs: SecurityLevel) -> Bool { lhs.rawValue < rhs.rawValue }

    var shortLabel: String {
        switch self {
        case .none: return "No protection"
        case .tls: return "TLS"
        case .mtls: return "Mutual TLS"
        }
    }

    var detail: String {
        switch self {
        case .none: return "Data is not encrypted or the server is not verified."
        case .tls: return "Encrypted, and the server's identity is verified. The server does not verify you."
        case .mtls: return "Encrypted, the server is verified, and the server verified your client certificate."
        }
    }
}

/// What was observed the last time a connection's security was checked.
struct SecuritySnapshot: Codable, Equatable {
    var level: SecurityLevel
    /// SHA-256 of the server's leaf certificate (hex).
    var serverFingerprint: String?
    /// Mode DigitalMe reported: off, tls, mtls-optional or mtls-required.
    var serverMode: String?
    var clientCommonName: String?
    var checkedAt: Date
}

/// A recorded, user-visible security change or decision.
struct SecurityEvent: Codable, Identifiable, Equatable {
    var id = UUID()
    var date: Date
    var connectionID: UUID
    var message: String
}

enum SecurityChange: Equatable {
    case first
    case unchanged
    case upgraded(from: SecurityLevel, to: SecurityLevel)
    case downgraded(from: SecurityLevel, to: SecurityLevel)
    case serverCertificateChanged
    case serverPolicyWeakened(from: String, to: String)
    case serverPolicyChanged(from: String, to: String)

    /// Changes that make the connection weaker or suspicious must be accepted by the user before uploading.
    var needsAcknowledgement: Bool {
        switch self {
        case .downgraded, .serverCertificateChanged, .serverPolicyWeakened: return true
        default: return false
        }
    }

    var summary: String {
        switch self {
        case .first: return "First security check for this service."
        case .unchanged: return "Security unchanged."
        case .upgraded(let from, let to): return "Security improved: \(from.shortLabel) to \(to.shortLabel)."
        case .downgraded(let from, let to): return "Security lowered: \(from.shortLabel) to \(to.shortLabel)."
        case .serverCertificateChanged: return "The server's certificate changed since the last check."
        case .serverPolicyWeakened(let from, let to): return "The server now accepts weaker connections (\(from) to \(to))."
        case .serverPolicyChanged(let from, let to): return "The server's security mode changed (\(from) to \(to))."
        }
    }

    static func serverRank(_ mode: String?) -> Int {
        switch mode {
        case "off": return 0
        case "tls": return 1
        case "mtls-optional": return 2
        case "mtls-required": return 3
        default: return 0
        }
    }

    static func compare(previous: SecuritySnapshot?, current: SecuritySnapshot) -> SecurityChange {
        guard let previous else { return .first }
        if let old = previous.serverFingerprint, let new = current.serverFingerprint, old != new {
            return .serverCertificateChanged
        }
        if current.level < previous.level { return .downgraded(from: previous.level, to: current.level) }
        if previous.serverMode != nil, serverRank(current.serverMode) < serverRank(previous.serverMode) {
            return .serverPolicyWeakened(from: previous.serverMode ?? "unknown", to: current.serverMode ?? "unknown")
        }
        if current.level > previous.level { return .upgraded(from: previous.level, to: current.level) }
        if current.serverMode != previous.serverMode {
            return .serverPolicyChanged(from: previous.serverMode ?? "unknown", to: current.serverMode ?? "unknown")
        }
        return .unchanged
    }
}

/// Why the TLS layer refused to continue, recorded by the session delegate.
enum TLSIssue: Equatable {
    case noClientIdentity, untrustedServer, hostMismatch
}

enum SecurityFailure: Equatable {
    case notHTTPS
    case noClientCertificate
    case clientCertificateRejected
    case handshakeFailed
    case serverNotTrusted
    case hostMismatch
    case unreachable(String)
    case badResponse(Int)

    static func classify(_ error: URLError, issue: TLSIssue?) -> SecurityFailure {
        switch issue {
        case .noClientIdentity?: return .noClientCertificate
        case .untrustedServer?: return .serverNotTrusted
        case .hostMismatch?: return .hostMismatch
        case nil: break
        }
        switch error.code {
        case .clientCertificateRequired, .clientCertificateRejected:
            return .clientCertificateRejected
        case .serverCertificateUntrusted, .serverCertificateHasUnknownRoot, .serverCertificateHasBadDate, .serverCertificateNotYetValid:
            return .serverNotTrusted
        case .secureConnectionFailed:
            return .handshakeFailed
        default:
            return .unreachable(error.localizedDescription)
        }
    }

    var explanation: String {
        switch self {
        case .notHTTPS: return "The address must start with https://."
        case .noClientCertificate: return "This service needs a client certificate, but none is imported."
        case .clientCertificateRejected: return "The server rejected your client certificate."
        case .handshakeFailed: return "The secure connection could not be established. The server may require a client certificate you did not present, or it may not be using TLS on this port."
        case .serverNotTrusted: return "The server's certificate is not trusted. Nothing was sent."
        case .hostMismatch: return "The server's certificate is for a different host than the address you entered. Nothing was sent."
        case .unreachable(let message): return "Could not reach the server: \(message)"
        case .badResponse(let status): return "The server answered with HTTP \(status)."
        }
    }

    /// Concrete next steps. Turning off certificate validation is never one of them.
    var suggestions: [String] {
        switch self {
        case .notHTTPS: return ["Use the full https://host:port address."]
        case .noClientCertificate: return ["Import the client .p12 and its password."]
        case .clientCertificateRejected: return ["Check that the .p12 was issued by the CA the server trusts.", "Check it has not expired and is on the server's allowlist, if one is set."]
        case .handshakeFailed: return ["Import your client .p12.", "Check the port is the TCP/TLS port, not the HTTP one.", "Check the server is running with TLS enabled."]
        case .serverNotTrusted: return ["Import the CA certificate that signed the server certificate.", "If the CA was re-issued, import the new one."]
        case .hostMismatch: return ["Use the host name the certificate was issued for, or re-issue the server certificate for this host."]
        case .unreachable: return ["Check your connection and the host and port.", "Retry in a moment."]
        case .badResponse: return ["Check the address points to DigitalMe."]
        }
    }

    var isRetryable: Bool {
        switch self {
        case .unreachable, .handshakeFailed: return true
        case .badResponse(let status): return status >= 500
        default: return false
        }
    }
}

struct SecurityCheckStep: Identifiable, Equatable {
    enum Outcome: Equatable { case ok, warning, failed, skipped }
    var title: String
    var outcome: Outcome
    var detail: String
    var id: String { title }

    var symbol: String {
        switch outcome {
        case .ok: return "checkmark.circle.fill"
        case .warning: return "exclamationmark.triangle.fill"
        case .failed: return "xmark.octagon.fill"
        case .skipped: return "minus.circle"
        }
    }
}

struct SecurityReport: Equatable {
    var snapshot: SecuritySnapshot?
    var steps: [SecurityCheckStep]
    var failure: SecurityFailure?
}

/// Always-visible one-line status for a connection.
struct SecurityBadge: Equatable {
    enum Tone { case good, caution, bad, unknown }
    var symbol: String
    var text: String
    var tone: Tone

    static func make(for connection: ServiceConnection) -> SecurityBadge {
        let required = connection.requiredSecurity
        guard let snapshot = connection.lastSnapshot else {
            return SecurityBadge(symbol: "questionmark.shield", text: "Security not checked yet (requires \(required.shortLabel))", tone: .unknown)
        }
        if snapshot.level >= required {
            return SecurityBadge(symbol: "lock.shield.fill", text: "\(snapshot.level.shortLabel) verified", tone: .good)
        }
        return SecurityBadge(symbol: "exclamationmark.triangle.fill", text: "\(snapshot.level.shortLabel) only, \(required.shortLabel) required", tone: .bad)
    }
}

enum ConnectionSecurityAssessment {
    /// Turns DigitalMe's `/security/status` answer into a snapshot and the steps shown to the user.
    static func assess(connection: ServiceConnection, status: Int, body: Data, modeHeader: String?,
                       serverFingerprint: String?, now: Date = Date()) -> SecurityReport {
        guard (200..<300).contains(status) || status == 404 else {
            let failure = SecurityFailure.badResponse(status)
            return SecurityReport(snapshot: nil, steps: [SecurityCheckStep(title: "Connection", outcome: .failed, detail: failure.explanation)], failure: failure)
        }
        let json = (try? JSONSerialization.jsonObject(with: body)) as? [String: Any]
        let client = json?["client"] as? [String: Any]
        let mode = (json?["mode"] as? String) ?? modeHeader
        let presented = (client?["presented"] as? Bool) ?? false
        let authorized = (client?["authorized"] as? Bool) ?? false
        let commonName = client?["common_name"] as? String
        let hasIdentity = connection.auth == .mutualTLS && connection.identityLabel != nil

        var steps = [SecurityCheckStep(title: "Connection", outcome: .ok, detail: "Secure connection established.")]
        let trustDetail = connection.caLabel != nil ? "Verified against the CA you imported." : "Verified by the system's trusted certificates."
        let shortFingerprint = serverFingerprint.map { " Fingerprint \($0.prefix(16))..." } ?? ""
        steps.append(SecurityCheckStep(title: "Server identity", outcome: .ok, detail: trustDetail + shortFingerprint))

        var level = SecurityLevel.tls
        if !hasIdentity {
            steps.append(SecurityCheckStep(title: "Your certificate", outcome: .skipped, detail: "No client certificate configured."))
        } else if presented && authorized {
            level = .mtls
            steps.append(SecurityCheckStep(title: "Your certificate", outcome: .ok, detail: "Presented and accepted" + (commonName.map { " as \($0)." } ?? ".")))
        } else if presented {
            steps.append(SecurityCheckStep(title: "Your certificate", outcome: .failed, detail: "Presented, but the server does not authorize it."))
        } else {
            steps.append(SecurityCheckStep(title: "Your certificate", outcome: .warning, detail: "The server did not receive a client certificate."))
        }

        if status == 404 {
            steps.append(SecurityCheckStep(title: "Server policy", outcome: .warning, detail: "This DigitalMe version does not report its security policy. Update it."))
        } else if mode == "mtls-required" {
            steps.append(SecurityCheckStep(title: "Server policy", outcome: .ok, detail: "Requires client certificates (mtls-required)."))
        } else {
            steps.append(SecurityCheckStep(title: "Server policy", outcome: .warning, detail: "Server mode is \(mode ?? "unknown"): it does not require client certificates."))
        }
        if let uploads = json?["upload_enabled"] as? Bool {
            steps.append(SecurityCheckStep(title: "Uploads", outcome: uploads ? .ok : .warning, detail: uploads ? "This endpoint accepts uploads." : "This endpoint does not accept uploads yet."))
        }

        let snapshot = SecuritySnapshot(level: level, serverFingerprint: serverFingerprint, serverMode: mode,
                                        clientCommonName: level == .mtls ? commonName : nil, checkedAt: now)
        return SecurityReport(snapshot: snapshot, steps: steps, failure: nil)
    }

    static func failureReport(_ failure: SecurityFailure) -> SecurityReport {
        SecurityReport(snapshot: nil, steps: [
            SecurityCheckStep(title: "Connection", outcome: .failed, detail: failure.explanation),
        ], failure: failure)
    }
}

struct ConnectionSecurityChecker {
    let connection: ServiceConnection
    var session: URLSession

    init(connection: ServiceConnection, session: URLSession? = nil) {
        self.connection = connection
        self.session = session ?? MutualTLSSession.make(for: connection)
    }

    func check() async -> SecurityReport {
        guard let url = connection.endpoint("security/status") else {
            return ConnectionSecurityAssessment.failureReport(.notHTTPS)
        }
        var request = URLRequest(url: url)
        request.timeoutInterval = 15
        let delegate = session.delegate as? MutualTLSDelegate
        do {
            let (data, response) = try await session.data(for: request)
            guard let http = response as? HTTPURLResponse else {
                return ConnectionSecurityAssessment.failureReport(.unreachable("Invalid response"))
            }
            return ConnectionSecurityAssessment.assess(
                connection: connection, status: http.statusCode, body: data,
                modeHeader: http.value(forHTTPHeaderField: "X-DigitalMe-Security-Mode"),
                serverFingerprint: delegate?.observedFingerprint)
        } catch {
            let urlError = (error as? URLError) ?? URLError(.unknown)
            return ConnectionSecurityAssessment.failureReport(.classify(urlError, issue: delegate?.issue))
        }
    }
}
