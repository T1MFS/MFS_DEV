import XCTest
@testable import MFS

final class HistoryStoreTests: XCTestCase {
    private var directory: URL!

    override func setUp() {
        directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    }

    override func tearDown() { try? FileManager.default.removeItem(at: directory) }

    func testGlucoseReadingsSurviveARelaunch() {
        let first = GlucoseFeed(store: HistoryStore(filename: "g.json", directory: directory))
        let t = Date(timeIntervalSince1970: 1_700_000_000)
        first.merge([GlucoseReading(date: t, milligramsPerDeciliter: 110), GlucoseReading(date: t.addingTimeInterval(300), milligramsPerDeciliter: 118)])
        first.merge([GlucoseReading(date: t, milligramsPerDeciliter: 110)])
        let store = HistoryStore<GlucoseReading>(filename: "g.json", directory: directory)
        store.flush()

        let second = GlucoseFeed(store: HistoryStore(filename: "g.json", directory: directory))
        XCTAssertEqual(second.readings.map(\.milligramsPerDeciliter), [110, 118])
        second.merge([GlucoseReading(date: t.addingTimeInterval(600), milligramsPerDeciliter: 125)])
        store.flush()
        XCTAssertEqual(GlucoseFeed(store: HistoryStore(filename: "g.json", directory: directory)).readings.count, 3)
    }

    func testMissingOrCorruptFileLoadsEmpty() throws {
        let store = HistoryStore<GlucoseReading>(filename: "x.json", directory: directory)
        XCTAssertTrue(store.load().isEmpty)
        try Data("not json".utf8).write(to: store.url)
        XCTAssertTrue(store.load().isEmpty)
    }
}
