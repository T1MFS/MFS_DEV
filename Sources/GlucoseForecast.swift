import Foundation

struct GlucoseReading: Equatable, Identifiable {
    let date: Date
    let milligramsPerDeciliter: Double
    var id: Date { date }
}

enum GlucoseTrend: Equatable {
    case risingFast, rising, steady, falling, fallingFast

    var symbolName: String {
        switch self {
        case .risingFast: return "arrow.up"
        case .rising: return "arrow.up.right"
        case .steady: return "arrow.right"
        case .falling: return "arrow.down.right"
        case .fallingFast: return "arrow.down"
        }
    }

    /// Classifies a rate in mg/dL per minute.
    init(rate: Double) {
        switch rate {
        case 2...: self = .risingFast
        case 1..<2: self = .rising
        case -1..<1: self = .steady
        case -2..<(-1): self = .falling
        default: self = .fallingFast
        }
    }
}

enum GlucoseTrendCalculator {
    /// Rate of change in mg/dL per minute over the window ending at the latest reading.
    static func rate(of readings: [GlucoseReading], window: TimeInterval = 15 * 60) -> Double? {
        guard let latest = readings.max(by: { $0.date < $1.date }) else { return nil }
        let recent = readings.filter { latest.date.timeIntervalSince($0.date) <= window }
        guard let earliest = recent.min(by: { $0.date < $1.date }), earliest.date < latest.date else { return nil }
        let minutes = latest.date.timeIntervalSince(earliest.date) / 60
        return (latest.milligramsPerDeciliter - earliest.milligramsPerDeciliter) / minutes
    }

    static func trend(of readings: [GlucoseReading]) -> GlucoseTrend? {
        rate(of: readings).map(GlucoseTrend.init(rate:))
    }
}

// MARK: Connector for future predictive models

struct FoodEvent: Equatable {
    let time: Date
    let carbohydrates: Double?
    let protein: Double?
    let fat: Double?
}

struct DoseEvent: Equatable {
    let time: Date
    let units: Double
}

/// Everything a predictive model may use. Attach food and dose data here.
struct ForecastContext {
    var readings: [GlucoseReading]
    var foods: [FoodEvent] = []
    var doses: [DoseEvent] = []
}

/// A model of how food or dose moves glucose, as a change in mg/dL at a given time
/// relative to the no-influence baseline.
protocol GlucoseInfluence {
    func change(at date: Date, context: ForecastContext) -> Double
}

/// Placeholder until real models exist: food and dose have no effect.
struct NoInfluence: GlucoseInfluence {
    func change(at date: Date, context: ForecastContext) -> Double { 0 }
}

struct ForecastPoint: Equatable, Identifiable {
    let date: Date
    let milligramsPerDeciliter: Double
    var id: Date { date }
}

struct GlucoseForecaster {
    var foodInfluence: GlucoseInfluence = NoInfluence()
    var doseInfluence: GlucoseInfluence = NoInfluence()

    /// Baseline is the latest reading held flat; influences are added to it.
    func points(context: ForecastContext, horizon: TimeInterval = 2 * 60 * 60, step: TimeInterval = 5 * 60) -> [ForecastPoint] {
        guard let latest = context.readings.max(by: { $0.date < $1.date }) else { return [] }
        return stride(from: 0.0, through: horizon, by: step).map { offset in
            let date = latest.date.addingTimeInterval(offset)
            let value = latest.milligramsPerDeciliter
                + foodInfluence.change(at: date, context: context)
                + doseInfluence.change(at: date, context: context)
            return ForecastPoint(date: date, milligramsPerDeciliter: value)
        }
    }
}

extension Date {
    /// Rounds to the nearest 5-minute step relative to the given anchor.
    func snapped(toFiveMinutesFrom anchor: Date) -> Date {
        let step = 5.0 * 60
        let steps = (timeIntervalSince(anchor) / step).rounded()
        return anchor.addingTimeInterval(steps * step)
    }
}
