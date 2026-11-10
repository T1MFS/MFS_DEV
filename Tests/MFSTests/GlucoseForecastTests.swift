import XCTest
@testable import MFS

final class GlucoseForecastTests: XCTestCase {
    private let start = Date(timeIntervalSince1970: 1_000_000)

    private func readings(_ values: [Double]) -> [GlucoseReading] {
        values.enumerated().map { GlucoseReading(date: start.addingTimeInterval(Double($0.offset) * 300), milligramsPerDeciliter: $0.element) }
    }

    func testTrendRateAndClassification() {
        let rising = readings([100, 110, 120])
        XCTAssertEqual(try XCTUnwrap(GlucoseTrendCalculator.rate(of: rising)), 2, accuracy: 0.001)
        XCTAssertEqual(GlucoseTrendCalculator.trend(of: rising), .risingFast)
        XCTAssertEqual(GlucoseTrendCalculator.trend(of: readings([100, 100, 101])), .steady)
        XCTAssertEqual(GlucoseTrendCalculator.trend(of: readings([120, 100, 80])), .fallingFast)
        XCTAssertNil(GlucoseTrendCalculator.trend(of: readings([100])))
        XCTAssertNil(GlucoseTrendCalculator.trend(of: []))
    }

    func testForecastWithNoInfluenceHoldsLatestValue() {
        let context = ForecastContext(readings: readings([100, 110, 120]),
                                      foods: [FoodEvent(time: start, carbohydrates: 60, protein: 10, fat: 5)],
                                      doses: [DoseEvent(time: start, units: 3)])
        let points = GlucoseForecaster().points(context: context)
        XCTAssertEqual(points.count, 25)
        XCTAssertTrue(points.allSatisfy { $0.milligramsPerDeciliter == 120 })
        XCTAssertEqual(points.first?.date, start.addingTimeInterval(600))
        XCTAssertTrue(GlucoseForecaster().points(context: ForecastContext(readings: [])).isEmpty)
    }

    func testInfluencesAreAdded() {
        struct Plus: GlucoseInfluence {
            let amount: Double
            func change(at date: Date, context: ForecastContext) -> Double { amount }
        }
        let forecaster = GlucoseForecaster(foodInfluence: Plus(amount: 10), doseInfluence: Plus(amount: -4))
        let points = forecaster.points(context: ForecastContext(readings: readings([100])))
        XCTAssertTrue(points.allSatisfy { $0.milligramsPerDeciliter == 106 })
    }

    func testSnapsToFiveMinuteSteps() {
        XCTAssertEqual(start.addingTimeInterval(7 * 60).snapped(toFiveMinutesFrom: start), start.addingTimeInterval(300))
        XCTAssertEqual(start.addingTimeInterval(8 * 60).snapped(toFiveMinutesFrom: start), start.addingTimeInterval(600))
        XCTAssertEqual(start.addingTimeInterval(-12 * 60).snapped(toFiveMinutesFrom: start), start.addingTimeInterval(-600))
    }
}
