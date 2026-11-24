import XCTest

final class ConnectionSecurityTests: XCTestCase {
    private func snapshot(_ level: SecurityLevel, fingerprint: String? = "aa", mode: String? = "mtls-required") -> SecuritySnapshot {
        SecuritySnapshot(level: level, serverFingerprint: fingerprint, serverMode: mode, clientCommonName: nil, checkedAt: Date())
    }

    func testChangeDetection() {
        XCTAssertEqual(SecurityChange.compare(previous: nil, current: snapshot(.mtls)), .first)
        XCTAssertEqual(SecurityChange.compare(previous: snapshot(.mtls), current: snapshot(.mtls)), .unchanged)
        XCTAssertEqual(SecurityChange.compare(previous: snapshot(.mtls), current: snapshot(.tls)), .downgraded(from: .mtls, to: .tls))
        XCTAssertEqual(SecurityChange.compare(previous: snapshot(.tls, mode: "tls"), current: snapshot(.mtls, mode: "tls")), .upgraded(from: .tls, to: .mtls))
        XCTAssertEqual(SecurityChange.compare(previous: snapshot(.mtls), current: snapshot(.mtls, fingerprint: "bb")), .serverCertificateChanged)
        XCTAssertEqual(SecurityChange.compare(previous: snapshot(.mtls), current: snapshot(.mtls, mode: "mtls-optional")),
                       .serverPolicyWeakened(from: "mtls-required", to: "mtls-optional"))
    }

    func testOnlyWeakeningChangesNeedAcknowledgement() {
        XCTAssertTrue(SecurityChange.downgraded(from: .mtls, to: .tls).needsAcknowledgement)
        XCTAssertTrue(SecurityChange.serverCertificateChanged.needsAcknowledgement)
        XCTAssertFalse(SecurityChange.upgraded(from: .tls, to: .mtls).needsAcknowledgement)
        XCTAssertFalse(SecurityChange.first.needsAcknowledgement)
    }

    func testFailureClassificationNeverSuggestsDisablingValidation() {
        XCTAssertEqual(SecurityFailure.classify(URLError(.cancelled), issue: .noClientIdentity), .noClientCertificate)
        XCTAssertEqual(SecurityFailure.classify(URLError(.serverCertificateUntrusted), issue: nil), .serverNotTrusted)
        XCTAssertEqual(SecurityFailure.classify(URLError(.clientCertificateRequired), issue: nil), .clientCertificateRejected)
        XCTAssertEqual(SecurityFailure.classify(URLError(.secureConnectionFailed), issue: nil), .handshakeFailed)
        XCTAssertEqual(SecurityFailure.classify(URLError(.cancelled), issue: .untrustedServer), .serverNotTrusted)
        let all: [SecurityFailure] = [.noClientCertificate, .clientCertificateRejected, .handshakeFailed, .serverNotTrusted, .hostMismatch]
        for failure in all {
            XCTAssertFalse(failure.suggestions.joined().lowercased().contains("disable"))
            XCTAssertFalse(failure.suggestions.isEmpty)
        }
    }

    func testBadgeReflectsRequirement() {
        var connection = ServiceConnection(name: "D", baseURL: "https://x", auth: .mutualTLS)
        XCTAssertEqual(SecurityBadge.make(for: connection).tone, .unknown)
        connection.lastSnapshot = snapshot(.mtls)
        XCTAssertEqual(SecurityBadge.make(for: connection).tone, .good)
        connection.lastSnapshot = snapshot(.tls)
        XCTAssertEqual(SecurityBadge.make(for: connection).tone, .bad)
        connection.minimumSecurity = .tls
        XCTAssertEqual(SecurityBadge.make(for: connection).tone, .good)
    }

    func testAssessmentLevels() {
        var connection = ServiceConnection(name: "D", baseURL: "https://x", auth: .mutualTLS)
        connection.identityLabel = "id"
        let accepted = Data(#"{"mode":"mtls-required","client":{"presented":true,"authorized":true,"common_name":"c"}}"#.utf8)
        let missing = Data(#"{"mode":"mtls-optional","client":{"presented":false,"authorized":false}}"#.utf8)
        XCTAssertEqual(ConnectionSecurityAssessment.assess(connection: connection, status: 200, body: accepted, modeHeader: nil, serverFingerprint: "ab").snapshot?.level, .mtls)
        let weaker = ConnectionSecurityAssessment.assess(connection: connection, status: 200, body: missing, modeHeader: nil, serverFingerprint: "ab")
        XCTAssertEqual(weaker.snapshot?.level, .tls)
        XCTAssertTrue(weaker.steps.contains { $0.outcome == .warning })
        let broken = ConnectionSecurityAssessment.assess(connection: connection, status: 500, body: Data(), modeHeader: nil, serverFingerprint: nil)
        XCTAssertNil(broken.snapshot)
        XCTAssertEqual(broken.failure, .badResponse(500))
    }

    func testStorePersistsSecurityHistoryAndOldDataStillLoads() throws {
        let defaults = try XCTUnwrap(UserDefaults(suiteName: "security-test-\(UUID())"))
        let store = ServiceConnectionStore(defaults: defaults)
        let id = UUID()
        store.logSecurity(["You lowered the required security to TLS."], for: id)
        XCTAssertEqual(ServiceConnectionStore(defaults: defaults).securityEvents.map(\.message), ["You lowered the required security to TLS."])
        let legacy = Data(#"{"connections":[{"id":"\#(id.uuidString)","name":"N","baseURL":"https://x","auth":"none","headerName":"","hashSecretSHA1":false,"enabled":true}],"healthKinds":[],"healthRequested":false}"#.utf8)
        let legacyDefaults = try XCTUnwrap(UserDefaults(suiteName: "security-legacy-\(UUID())"))
        legacyDefaults.set(legacy, forKey: "MFS.ServiceConnections")
        let loaded = ServiceConnectionStore(defaults: legacyDefaults)
        XCTAssertEqual(loaded.connections.count, 1)
        XCTAssertTrue(loaded.securityEvents.isEmpty)
    }
}
