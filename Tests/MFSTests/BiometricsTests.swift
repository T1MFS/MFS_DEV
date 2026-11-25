import XCTest

final class BiometricsTests: XCTestCase {
    private var calendar: Calendar {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "UTC")!
        return calendar
    }

    private func date(_ iso: String) -> Date { ISO8601DateFormatter().date(from: iso)! }

    /// Matches the example in TidepoolApi_extended docs/device-data/data-types/biometric.md.
    func testDatumMatchesSpecExample() throws {
        let sample = BiometricSample(metric: .heartRate, value: 72, time: date("2018-05-14T08:17:08Z"), id: "6e3ea4734056463f84f6be47621d21d7")
        let datum = BiometricMapper.datum(sample)

        XCTAssertEqual(datum["type"] as? String, "biometric")
        XCTAssertEqual(datum["metric"] as? String, "heartRate")
        XCTAssertEqual(datum["id"] as? String, "6e3ea4734056463f84f6be47621d21d7")
        XCTAssertEqual(datum["time"] as? String, "2018-05-14T08:17:08.000Z")
        let amount = try XCTUnwrap(datum["amount"] as? [String: Any])
        XCTAssertEqual(amount["value"] as? Double, 72)
        XCTAssertEqual(amount["units"] as? String, "bpm")
        XCTAssertEqual(Set(datum.keys), ["type", "metric", "id", "time", "amount"])
    }

    func testEveryMetricHasTheSpecUnit() {
        XCTAssertEqual(BiometricMetric.heartRate.units, "bpm")
        XCTAssertEqual(BiometricMetric.heartRateVariability.units, "ms")
        XCTAssertEqual(BiometricMetric.sleepDuration.units, "minutes")
    }

    func testSleepMergesOverlapsAndTotalsPerNight() {
        let intervals = [
            SleepInterval(start: date("2024-10-07T23:00:00Z"), end: date("2024-10-08T03:00:00Z")),
            SleepInterval(start: date("2024-10-08T02:00:00Z"), end: date("2024-10-08T06:00:00Z")),  // overlaps the first
            SleepInterval(start: date("2024-10-08T06:30:00Z"), end: date("2024-10-08T07:00:00Z")),
        ]
        let nights = BiometricMapper.sleepNights(from: intervals, before: date("2024-10-09T00:00:00Z"), calendar: calendar)

        XCTAssertEqual(nights.count, 1)
        XCTAssertEqual(nights[0].metric, .sleepDuration)
        XCTAssertEqual(nights[0].value, 7 * 60 + 30)  // 23:00-06:00 merged, plus 30 min
        XCTAssertEqual(nights[0].time, date("2024-10-08T07:00:00Z"))
    }

    func testNightStillInProgressIsNotSent() {
        let intervals = [SleepInterval(start: date("2024-10-08T23:00:00Z"), end: date("2024-10-09T05:00:00Z"))]
        XCTAssertTrue(BiometricMapper.sleepNights(from: intervals, before: date("2024-10-09T00:00:00Z"), calendar: calendar).isEmpty)
    }

    func testSyncStateRoundTripsAndKeepsAnchorsPerMetric() throws {
        let defaults = try XCTUnwrap(UserDefaults(suiteName: "biometric-test-\(UUID())"))
        var state = BiometricSyncState()
        state.set(anchor: Data([1, 2]), for: .heartRate)
        state.lastSleepSent = date("2024-10-08T07:00:00Z")
        state.save(to: defaults)

        let loaded = BiometricSyncState.load(from: defaults)
        XCTAssertEqual(loaded, state)
        XCTAssertEqual(loaded.anchor(for: .heartRate), Data([1, 2]))
        XCTAssertNil(loaded.anchor(for: .heartRateVariability))
    }
}
