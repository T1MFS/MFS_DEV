import Foundation

// Plug-in API for the prediction/evaluation visualization. Nothing here does the glucose math:
// a model is anything that turns the data known at a moment into predicted points. The
// visualization only draws what a model returns and compares it with what actually happened.

struct PredictionPoint: Equatable, Identifiable {
    let date: Date
    let milligramsPerDeciliter: Double
    /// Optional uncertainty band drawn around the value.
    var lower: Double? = nil
    var upper: Double? = nil
    var id: Date { date }
}

/// A mathematical model that can be shown and evaluated. Implementations must only use
/// data in `context` (the caller hides anything after the prediction time).
protocol PredictionModel {
    /// Stable identifier, unique among registered models.
    var id: String { get }
    var name: String { get }
    /// Predicted points after the latest reading in `context`, spaced `step` apart up to `horizon`.
    func predict(context: ForecastContext, horizon: TimeInterval, step: TimeInterval) -> [PredictionPoint]
}

/// Adapts the existing `GlucoseForecaster` so it can be plugged in like any other model.
struct ForecasterPredictionModel: PredictionModel {
    var id = "baseline"
    var name = "Baseline"
    var forecaster = GlucoseForecaster()

    func predict(context: ForecastContext, horizon: TimeInterval, step: TimeInterval) -> [PredictionPoint] {
        forecaster.points(context: context, horizon: horizon, step: step)
            .map { PredictionPoint(date: $0.date, milligramsPerDeciliter: $0.milligramsPerDeciliter) }
    }
}

/// The models offered to the visualization.
struct PredictionModelRegistry {
    private(set) var models: [PredictionModel]

    init(models: [PredictionModel] = [ForecasterPredictionModel()]) {
        self.models = []
        for model in models { register(model) }
    }

    /// Adds a model, replacing any registered model with the same id.
    mutating func register(_ model: PredictionModel) {
        models.removeAll { $0.id == model.id }
        models.append(model)
    }

    func model(id: String) -> PredictionModel? { models.first { $0.id == id } }
}

/// A prediction made at one moment, lined up against the readings that followed.
struct PredictionEvaluation: Equatable {
    struct Match: Equatable, Identifiable {
        let date: Date
        let predicted: Double
        let actual: Double
        var error: Double { predicted - actual }
        var id: Date { date }
    }

    let modelID: String
    let predictionTime: Date
    let predicted: [PredictionPoint]
    /// Readings at or before the prediction time: what the model was allowed to see.
    let known: [GlucoseReading]
    /// Readings after the prediction time, within the horizon.
    let actual: [GlucoseReading]
    /// Predicted points that have a reading within `tolerance`.
    let matches: [Match]

    var meanAbsoluteError: Double? {
        matches.isEmpty ? nil : matches.map { abs($0.error) }.reduce(0, +) / Double(matches.count)
    }

    var rootMeanSquareError: Double? {
        matches.isEmpty ? nil : (matches.map { $0.error * $0.error }.reduce(0, +) / Double(matches.count)).squareRoot()
    }
}

enum PredictionEvaluator {
    /// Runs `model` as of `time` using only data up to then, and matches it to what happened next.
    static func evaluate(
        model: PredictionModel,
        at time: Date,
        context: ForecastContext,
        horizon: TimeInterval = 2 * 60 * 60,
        step: TimeInterval = 5 * 60,
        tolerance: TimeInterval = 150
    ) -> PredictionEvaluation {
        let known = context.readings.filter { $0.date <= time }.sorted { $0.date < $1.date }
        let visible = ForecastContext(
            readings: known,
            foods: context.foods.filter { $0.time <= time },
            doses: context.doses.filter { $0.time <= time })
        let predicted = model.predict(context: visible, horizon: horizon, step: step)
            .filter { $0.date > time }
        let actual = context.readings
            .filter { $0.date > time && $0.date <= time.addingTimeInterval(horizon) }
            .sorted { $0.date < $1.date }
        let matches: [PredictionEvaluation.Match] = predicted.compactMap { point in
            guard let reading = actual.min(by: { abs($0.date.timeIntervalSince(point.date)) < abs($1.date.timeIntervalSince(point.date)) }),
                  abs(reading.date.timeIntervalSince(point.date)) <= tolerance else { return nil }
            return PredictionEvaluation.Match(date: point.date, predicted: point.milligramsPerDeciliter, actual: reading.milligramsPerDeciliter)
        }
        return PredictionEvaluation(modelID: model.id, predictionTime: time, predicted: predicted,
                                    known: known, actual: actual, matches: matches)
    }
}
