import XCTest
@testable import MFS

final class DeviceStateStoreTests: XCTestCase {
    private func makeStore() -> DeviceStateStore {
        let defaults = UserDefaults(suiteName: "DeviceStateStoreTests-\(UUID().uuidString)")!
        return DeviceStateStore(key: "state", defaults: defaults)
    }

    func testRoundTripsRawState() {
        let store = makeStore()
        let state: [String: Any] = ["sensorID": "ABC", "count": 3, "when": Date(timeIntervalSince1970: 100)]
        store.save(state)
        let loaded = store.load()
        XCTAssertEqual(loaded?["sensorID"] as? String, "ABC")
        XCTAssertEqual(loaded?["count"] as? Int, 3)
        XCTAssertEqual(loaded?["when"] as? Date, Date(timeIntervalSince1970: 100))
    }

    func testLoadReturnsNilWhenEmptyOrCleared() {
        let store = makeStore()
        XCTAssertNil(store.load())
        store.save(["a": 1])
        store.clear()
        XCTAssertNil(store.load())
    }
}
