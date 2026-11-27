import SwiftUI
import Charts

/// Draws a prediction beside the readings that were known and the readings that followed.
struct PredictionChart: View {
    let evaluation: PredictionEvaluation

    var body: some View {
        Chart {
            ForEach(evaluation.known) { reading in
                LineMark(x: .value("Time", reading.date), y: .value("mg/dl", reading.milligramsPerDeciliter),
                         series: .value("Series", "Known"))
                    .foregroundStyle(.blue)
            }
            ForEach(evaluation.actual) { reading in
                LineMark(x: .value("Time", reading.date), y: .value("mg/dl", reading.milligramsPerDeciliter),
                         series: .value("Series", "Actual"))
                    .foregroundStyle(.green)
            }
            ForEach(evaluation.predicted) { point in
                if let lower = point.lower, let upper = point.upper {
                    AreaMark(x: .value("Time", point.date), yStart: .value("Low", lower), yEnd: .value("High", upper))
                        .foregroundStyle(.orange.opacity(0.2))
                }
                LineMark(x: .value("Time", point.date), y: .value("mg/dl", point.milligramsPerDeciliter),
                         series: .value("Series", "Predicted"))
                    .foregroundStyle(.orange)
                    .lineStyle(StrokeStyle(lineWidth: 2, dash: [5, 3]))
            }
            RuleMark(x: .value("Prediction time", evaluation.predictionTime))
                .foregroundStyle(.secondary)
                .lineStyle(StrokeStyle(lineWidth: 1, dash: [2, 2]))
        }
        .chartForegroundStyleScale(["Known": Color.blue, "Actual": Color.green, "Predicted": Color.orange])
        .frame(height: 240)
    }
}

/// Pick a model and a moment; see what that model predicted from the data available then.
/// Models come from the registry, so new math appears here without view changes.
struct PredictionEvaluationView: View {
    let registry: PredictionModelRegistry
    let context: ForecastContext
    var horizon: TimeInterval = 2 * 60 * 60

    @State private var modelID: String?
    @State private var offset = 1.0 // 0...1 across the span of readings

    private var span: ClosedRange<Date>? {
        guard let first = context.readings.map(\.date).min(), let last = context.readings.map(\.date).max(), first < last else { return nil }
        return first...last
    }

    private var predictionTime: Date? {
        span.map { $0.lowerBound.addingTimeInterval($0.upperBound.timeIntervalSince($0.lowerBound) * offset) }
    }

    private var model: PredictionModel? {
        registry.model(id: modelID ?? "") ?? registry.models.first
    }

    private var evaluation: PredictionEvaluation? {
        guard let model, let time = predictionTime else { return nil }
        return PredictionEvaluator.evaluate(model: model, at: time, context: context, horizon: horizon)
    }

    var body: some View {
        List {
            if registry.models.isEmpty {
                Text("No prediction models are available.").foregroundStyle(.secondary)
            } else if let evaluation {
                Section("Prediction") {
                    PredictionChart(evaluation: evaluation)
                }
                Section("Model") {
                    Picker("Model", selection: Binding(get: { model?.id ?? "" }, set: { modelID = $0 })) {
                        ForEach(registry.models, id: \.id) { Text($0.name).tag($0.id) }
                    }
                }
                Section("Predicted at") {
                    Slider(value: $offset, in: 0...1)
                    Text(evaluation.predictionTime.formatted(date: .abbreviated, time: .shortened))
                        .font(.caption).foregroundStyle(.secondary)
                }
                Section("Accuracy") { accuracy(evaluation) }
            } else {
                Text("Needs at least two glucose readings.").foregroundStyle(.secondary)
            }
        }
        .navigationTitle("Predictions")
    }

    @ViewBuilder
    private func accuracy(_ evaluation: PredictionEvaluation) -> some View {
        if let mae = evaluation.meanAbsoluteError, let rmse = evaluation.rootMeanSquareError {
            let format = FloatingPointFormatStyle<Double>.number.precision(.fractionLength(0...1))
            LabeledContent("Mean absolute error", value: "\(mae.formatted(format)) mg/dl")
            LabeledContent("Root mean square error", value: "\(rmse.formatted(format)) mg/dl")
            LabeledContent("Points compared", value: "\(evaluation.matches.count)")
        } else {
            Text("No later readings to compare with yet.").foregroundStyle(.secondary)
        }
    }
}
