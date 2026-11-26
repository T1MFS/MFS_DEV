import XCTest
@testable import MFS

@MainActor
final class BiometricStreamTests: XCTestCase {
    private var defaults: UserDefaults!
    private var connection: ServiceConnection!
    private var calls: [Int] = []
    private var readKinds: [Set<HealthDataKind>] = []

    override func setUp() {
        defaults = UserDefaults(suiteName: "BiometricStreamTests-\(UUID().uuidString)")
        connection = ServiceConnection(name: "DigitalMe", baseURL: "https://example.test", auth: .mutualTLS)
        calls = []
        readKinds = []
    }

    private let night = Date(timeIntervalSince1970: 1_700_000_000)

    private func samples(_ count: Int) -> [BiometricSample] {
        (0..<count).map { BiometricSample(metric: .heartRate, value: 70, time: night.addingTimeInterval(Double($0)), id: "id-\($0)") }
    }

    private func makeStream(count: Int, uploadError: DigitalMeUploadError? = nil, failures: Int = 0) -> BiometricStream {
        var remainingFailures = failures
        let batchSamples = samples(count)
        var state = BiometricSyncState()
        state.lastSleepSent = night
        let stream = BiometricStream(
            defaults: defaults,
            read: { [unowned self] kinds, _ in
                readKinds.append(kinds)
                return BiometricBatch(samples: batchSamples, pendingState: state)
            },
            upload: { [unowned self] _, records in
                calls.append(records.count)
                if let uploadError, remainingFailures > 0 || failures == 0 {
                    remainingFailures -= 1
                    throw uploadError
                }
            })
        stream.connections = { [connection] in [connection!] }
        return stream
    }

    func testNothingIsReadOrSentWithoutApproval() async {
        let stream = makeStream(count: 3)
        await stream.readingArrived()
        XCTAssertTrue(readKinds.isEmpty)
        XCTAssertTrue(calls.isEmpty)
    }

    func testApprovedKindsAreSentWithEachReadingAndStateIsCommitted() async {
        let stream = makeStream(count: 3)
        stream.setApproved(.heartRate, true, connectionID: connection.id)
        await stream.readingArrived()
        XCTAssertEqual(readKinds, [[.heartRate]])
        XCTAssertEqual(calls, [3])
        XCTAssertEqual(stream.lastSentCount, 3)
        XCTAssertEqual(BiometricSyncState.load(from: defaults).lastSleepSent, night)
    }

    func testEmptyBatchSendsNothingButAdvancesState() async {
        let stream = makeStream(count: 0)
        stream.setApproved(.sleep, true, connectionID: connection.id)
        await stream.readingArrived()
        XCTAssertTrue(calls.isEmpty)
        XCTAssertEqual(BiometricSyncState.load(from: defaults).lastSleepSent, night)
    }

    func testLargeBacklogIsSplitIntoChunks() async {
        let stream = makeStream(count: BiometricStream.chunkSize * 2 + 1)
        stream.setApproved(.heartRate, true, connectionID: connection.id)
        await stream.readingArrived()
        XCTAssertEqual(calls, [BiometricStream.chunkSize, BiometricStream.chunkSize, 1])
    }

    func testNetworkFailureKeepsStreamingAndDoesNotCommit() async {
        let stream = makeStream(count: 2, uploadError: .network("offline"), failures: 1)
        stream.setApproved(.heartRate, true, connectionID: connection.id)
        await stream.readingArrived()
        XCTAssertTrue(stream.consent.isStreaming)
        XCTAssertNil(BiometricSyncState.load(from: defaults).lastSleepSent)
        await stream.readingArrived()
        XCTAssertEqual(BiometricSyncState.load(from: defaults).lastSleepSent, night)
    }

    func testRefusalPausesUntilResumed() async {
        let stream = makeStream(count: 2, uploadError: .server(403))
        stream.setApproved(.heartRate, true, connectionID: connection.id)
        await stream.readingArrived()
        XCTAssertNotNil(stream.consent.pausedReason)
        XCTAssertFalse(stream.consent.isStreaming)
        let before = calls.count
        await stream.readingArrived()
        XCTAssertEqual(calls.count, before)
        stream.resume()
        XCTAssertTrue(stream.consent.isStreaming)
    }

    func testStopRevokesApprovalAndForgetsState() async {
        let stream = makeStream(count: 2)
        stream.setApproved(.heartRate, true, connectionID: connection.id)
        await stream.readingArrived()
        stream.stop()
        XCTAssertFalse(stream.consent.isActive)
        XCTAssertNil(BiometricSyncState.load(from: defaults).lastSleepSent)
        let before = calls.count
        await stream.readingArrived()
        XCTAssertEqual(calls.count, before)
    }

    func testTurningOffLastKindEndsApproval() {
        let stream = makeStream(count: 1)
        stream.setApproved(.heartRate, true, connectionID: connection.id)
        stream.setApproved(.sleep, true, connectionID: connection.id)
        stream.setApproved(.heartRate, false, connectionID: connection.id)
        XCTAssertEqual(stream.consent.approved, [.sleep])
        stream.setApproved(.sleep, false, connectionID: connection.id)
        XCTAssertFalse(stream.consent.isActive)
    }
}
