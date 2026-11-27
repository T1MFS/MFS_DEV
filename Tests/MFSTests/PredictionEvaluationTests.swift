import XCTest
@testable import MFS

final class PredictionEvaluationTests: XCTestCase {
    private let t0 = Date(timeIntervalSince1970: 1_700_000_000)

    private func readings(_ values: [Double]) -> [GlucoseReading] {
        values.enumerated().map { GlucoseReading(date: t0.addingTimeInterval(Double($0.offset) * 300), milligramsPerDeciliter: $0.element) }
    }

    private struct SeenModel: PredictionModel {
        let id = "seen"
        let name = "Seen"
        let record: (ForecastContext) -> Void
        func predict(context: ForecastContext, horizon: TimeInterval, step: TimeInterval) -> [PredictionPoint] {
            record(context)
            return [PredictionPoint(date: context.readings.last!.date.addingTimeInterval(step), milligramsPerDeciliter: 100)]
        }
    }

    func testModelOnlySeesDataUpToThePredictionTime() {
        var seen: ForecastContext?
        let all = readings([100, 110, 120, 130])
        let context = ForecastContext(readings: all, foods: [FoodEvent(time: t0.addingTimeInterval(900), carbohydrates: 10, protein: nil, fat: nil)])
        let result = PredictionEvaluator.evaluate(model: SeenModel { seen = $0 }, at: t0.addingTimeInterval(300), context: context)
        XCTAssertEqual(seen?.readings, Array(all.prefix(2)))
        XCTAssertTrue(seen?.foods.isEmpty ?? false)
        XCTAssertEqual(result.actual, Array(all.suffix(2)))
    }

    func testErrorsComparePredictionsWithLaterReadings() {
        let context = ForecastContext(readings: readings([100, 100, 110, 130]))
        let result = PredictionEvaluator.evaluate(model: ForecasterPredictionModel(), at: t0.addingTimeInterval(300), context: context, horizon: 600)
        // Baseline holds 100: errors are -10 and -30.
        XCTAssertEqual(result.matches.map(\.error), [-10, -30])
        XCTAssertEqual(result.meanAbsoluteError, 20)
    }

    func testRegistryReplacesModelsWithTheSameID() {
        var registry = PredictionModelRegistry()
        registry.register(ForecasterPredictionModel(id: "baseline", name: "Replaced"))
        registry.register(ForecasterPredictionModel(id: "other", name: "Other"))
        XCTAssertEqual(registry.models.map(\.name), ["Replaced", "Other"])
    }
}
