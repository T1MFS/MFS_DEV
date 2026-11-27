import Foundation

/// A delivered or programmed amount of insulin, independent of any pump kit type.
struct InsulinDose: Equatable {
    enum Kind: String, Equatable { case bolus, basal }

    var kind: Kind
    var start: Date
    var end: Date
    /// Bolus: units delivered. Basal: units per hour while the dose runs.
    var amount: Double

    var units: Double {
        switch kind {
        case .bolus: return amount
        case .basal: return amount * max(end.timeIntervalSince(start), 0) / 3600
        }
    }
}

/// Mirrors LoopKit's `ExponentialInsulinModel` (percentEffectRemaining) so insulin on board matches what Loop would show.
/// Defaults are Loop's rapid-acting adult preset: 6 h action, 75 min peak, 10 min delay.
struct InsulinActionModel: Equatable {
    var actionDuration: TimeInterval = 6 * 3600
    var peakActivityTime: TimeInterval = 75 * 60
    var delay: TimeInterval = 10 * 60

    /// Fraction of a dose still active `time` seconds after delivery.
    func percentRemaining(at time: TimeInterval) -> Double {
        let t = time - delay
        if t <= 0 { return 1 }
        if t >= actionDuration { return 0 }
        let tau = peakActivityTime * (1 - peakActivityTime / actionDuration) / (1 - 2 * peakActivityTime / actionDuration)
        let a = 2 * tau / actionDuration
        let s = 1 / (1 - a + (1 + a) * exp(-actionDuration / tau))
        return 1 - s * (1 - a) * ((t * t / (tau * actionDuration * (1 - a)) - t / tau - 1) * exp(-t / tau) + 1)
    }
}

enum InsulinOnBoard {
    /// Units still active at `date`. Boluses only: the scheduled basal is not known here, so basal is not netted out.
    static func units(at date: Date, doses: [InsulinDose], model: InsulinActionModel = InsulinActionModel()) -> Double {
        doses.filter { $0.kind == .bolus && $0.start <= date }
            .reduce(0) { $0 + $1.units * model.percentRemaining(at: date.timeIntervalSince($1.start)) }
    }

    static func timeline(doses: [InsulinDose], from start: Date, to end: Date, step: TimeInterval = 5 * 60,
                         model: InsulinActionModel = InsulinActionModel()) -> [(date: Date, units: Double)] {
        guard step > 0, start <= end else { return [] }
        return stride(from: 0.0, through: end.timeIntervalSince(start), by: step).map {
            let date = start.addingTimeInterval($0)
            return (date, units(at: date, doses: doses, model: model))
        }
    }
}

/// Insulin on board from recorded doses. nil when no doses have ever been recorded, so recommendations
/// keep listing it as missing instead of treating "no pump data" as zero.
struct RecordedInsulinOnBoard: InsulinOnBoardSource {
    var doses: [InsulinDose]
    var model = InsulinActionModel()

    func units(at date: Date) -> Double? {
        doses.isEmpty ? nil : InsulinOnBoard.units(at: date, doses: doses, model: model)
    }
}
