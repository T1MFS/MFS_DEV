import Foundation

enum CarbFiberTreatment: String, Codable, CaseIterable, Identifiable {
    case ignore, half, full

    var id: String { rawValue }

    var label: String {
        switch self {
        case .ignore: return "Total carbs"
        case .half: return "Net (fiber ÷ 2)"
        case .full: return "Net (all fiber)"
        }
    }
}

/// Toy model two: B(t) = b + C·(s * [A1·carbs·g_fast + A2·protein·g_hold])(t).
/// Carbohydrate drives the fast component, protein the slow one, and fat only sets the smear time:
/// the smear width is σ minutes per gram of fat (no fat, no smear). Fat adds no glucose directly.
/// Seven adjustable factors: three times (t1, t2, σ), three amplitudes (A1, A2, C) and an offset b.
/// The hold length and edge width are fixed.
struct DoseFormula: Codable, Equatable {
    var fastPeakMinutes = 20.0
    var slowCenterMinutes = 240.0
    var smearMinutesPerGramFat = 26.3
    var fastAmplitude = 1.0
    var slowAmplitude = 1.5
    var scale = 0.5
    var offset = 0.0
    var fiber: CarbFiberTreatment = .ignore

    static let holdMinutes = 120.0
    static let edgeWidthMinutes = 60.0
    static let horizonMinutes = 720

    /// Curve on a one minute grid from 0 through `horizonMinutes` for the given grams.
    func curve(carbohydrate: Double, protein: Double, fat: Double) -> [Double] {
        let n = Self.horizonMinutes + 1
        let t1 = max(fastPeakMinutes, 0.01)
        let sigma = max(smearMinutesPerGramFat * fat, 0)
        let fast = (0..<n).map { Double($0) / (t1 * t1) * exp(-Double($0) / t1) }
        let logistic = { (x: Double) in 1 / (1 + exp(-x)) }
        let hold = (0..<n).map { i -> Double in
            let t = Double(i)
            return logistic((t - slowCenterMinutes + Self.holdMinutes / 2) / Self.edgeWidthMinutes)
                - logistic((t - slowCenterMinutes - Self.holdMinutes / 2) / Self.edgeWidthMinutes)
        }
        let holdArea = hold.reduce(0, +)
        let base = (0..<n).map {
            fastAmplitude * carbohydrate * fast[$0] + (holdArea > 0 ? slowAmplitude * protein * hold[$0] / holdArea : 0)
        }
        let kernel = sigma < 0.01 ? [1.0] : (0...Int(6 * sigma)).map { exp(-0.5 * pow((Double($0) - sigma) / sigma, 2)) }
        let kernelSum = kernel.reduce(0, +)
        return (0..<n).map { i in
            var acc = 0.0
            for (tau, k) in kernel.enumerated() where tau <= i { acc += k / kernelSum * base[i - tau] }
            return offset + scale * acc
        }
    }

    func carbAmount(total: Double?, fiber grams: Double?) -> Double? {
        guard let total else { return nil }
        let fiberGrams = grams ?? 0
        switch fiber {
        case .ignore: return total
        case .half: return max(total - fiberGrams / 2, 0)
        case .full: return max(total - fiberGrams, 0)
        }
    }

    /// Curve for a food's grams; missing amounts count as 0.
    func curve(carbohydrate c: Double?, fiber: Double?, protein p: Double?, fat f: Double?) -> [Double] {
        curve(carbohydrate: carbAmount(total: c, fiber: fiber) ?? 0, protein: p ?? 0, fat: f ?? 0)
    }

    /// Impact at `minutes` after eating, linearly interpolated between grid minutes.
    func impact(carbohydrate c: Double?, fiber: Double?, protein p: Double?, fat f: Double?, minutes: Double) -> Double {
        guard minutes >= 0, minutes <= Double(Self.horizonMinutes) else { return 0 }
        let curve = curve(carbohydrate: c, fiber: fiber, protein: p, fat: f)
        let lower = Int(minutes), frac = minutes - Double(lower)
        return lower + 1 < curve.count ? curve[lower] * (1 - frac) + curve[lower + 1] * frac : curve[lower]
    }
}

/// A bolus plus an enhanced (extra) basal rate meant to cancel the modelled glucose impact of a meal.
/// Displayed only; nothing here is sent to a pump.
struct ExperimentalDose: Equatable {
    var bolusUnits: Double
    var extraBasalUnitsPerHour: Double
    var extraBasalMinutes: Int
    /// Total modelled glucose rise the dose offsets, in mg/dL.
    var riseMgdl: Double
}

extension DoseFormula {
    /// Treats B(t) as mg/dL of rise per minute, so total insulin is its area divided by sensitivity.
    /// The part inside `bolusMinutes` goes in as a bolus; the tail (until the curve falls below 1% of its peak)
    /// is spread evenly as extra basal. Results are relative until B(t) is fitted to data.
    func experimentalDose(carbohydrate: Double?, fiber: Double?, protein: Double?, fat: Double?,
                          sensitivityMgdlPerUnit: Double, bolusMinutes: Int = 120) -> ExperimentalDose? {
        guard sensitivityMgdlPerUnit > 0 else { return nil }
        let impact = curve(carbohydrate: carbohydrate, fiber: fiber, protein: protein, fat: fat).map { max($0 - offset, 0) }
        guard let peak = impact.max(), peak > 0 else { return nil }
        let split = min(bolusMinutes, impact.count)
        let bolusArea = impact[..<split].reduce(0, +)
        let tail = Array(impact[split...])
        let tailArea = tail.reduce(0, +)
        let tailMinutes = (tail.lastIndex { $0 >= peak * 0.01 } ?? -1) + 1
        let extraBasal = tailMinutes > 0 ? tailArea / sensitivityMgdlPerUnit / (Double(tailMinutes) / 60) : 0
        return ExperimentalDose(bolusUnits: bolusArea / sensitivityMgdlPerUnit,
                                extraBasalUnitsPerHour: extraBasal,
                                extraBasalMinutes: tailMinutes,
                                riseMgdl: bolusArea + tailArea)
    }
}

enum DosingMode: String, Codable, CaseIterable, Identifiable {
    case mealSpecific, simple, experimental

    var id: String { rawValue }

    var label: String {
        switch self {
        case .mealSpecific: return "Meal specific"
        case .simple: return "Simple"
        case .experimental: return "Experimental"
        }
    }
}

/// Which dosing tab is selected and the Simple tab's numbers.
final class DosingStore: ObservableObject {
    /// Protein defaults to the carbohydrate number divided by this.
    static let proteinDivisor = 5.0

    @Published var mode: DosingMode { didSet { defaults.set(mode.rawValue, forKey: key) } }
    /// Grams of carbohydrate.
    @Published var simpleCarbs: Double?
    /// Grams of protein. nil while the user has not typed a number; then protein follows carbs.
    @Published var simpleProteinEntry: Double?

    private let defaults: UserDefaults
    private let key = "MFS.DosingMode"

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        mode = defaults.string(forKey: key).flatMap(DosingMode.init(rawValue:)) ?? .simple
    }

    var simpleProtein: Double? { simpleProteinEntry ?? simpleCarbs.map { $0 / Self.proteinDivisor } }
}

final class DoseFormulaStore: ObservableObject {
    @Published var formula: DoseFormula { didSet { save() } }
    private let defaults: UserDefaults
    private let key = "MFS.DoseFormula"

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        if let data = defaults.data(forKey: key), let saved = try? JSONDecoder().decode(DoseFormula.self, from: data) {
            formula = saved
        } else {
            formula = DoseFormula()
        }
    }

    private func save() {
        defaults.set(try? JSONEncoder().encode(formula), forKey: key)
    }
}
