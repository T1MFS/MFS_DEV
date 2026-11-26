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

/// Toy model two: B(t) = b + C·(s_σ * [A1·g_fast + A2·g_hold])(t), scaled by the net carbohydrate grams.
/// Seven adjustable factors: three times (t1, t2, σ), three amplitudes (A1, A2, C) and an offset b.
/// The hold length and edge width are fixed.
struct DoseFormula: Codable, Equatable {
    var fastPeakMinutes = 20.0
    var slowCenterMinutes = 240.0
    var smearMinutes = 26.3
    var fastAmplitude = 1.0
    var slowAmplitude = 1.5
    var scale = 0.5
    var offset = 0.0
    var fiber: CarbFiberTreatment = .ignore

    static let holdMinutes = 120.0
    static let edgeWidthMinutes = 60.0
    static let horizonMinutes = 720

    /// Curve per gram of carbohydrate on a one minute grid from 0 through `horizonMinutes`.
    func curve() -> [Double] {
        let n = Self.horizonMinutes + 1
        let t1 = max(fastPeakMinutes, 0.01), sigma = max(smearMinutes, 0.01)
        let fast = (0..<n).map { Double($0) / (t1 * t1) * exp(-Double($0) / t1) }
        let logistic = { (x: Double) in 1 / (1 + exp(-x)) }
        let hold = (0..<n).map { i -> Double in
            let t = Double(i)
            return logistic((t - slowCenterMinutes + Self.holdMinutes / 2) / Self.edgeWidthMinutes)
                - logistic((t - slowCenterMinutes - Self.holdMinutes / 2) / Self.edgeWidthMinutes)
        }
        let holdArea = hold.reduce(0, +)
        let base = (0..<n).map { fastAmplitude * fast[$0] + (holdArea > 0 ? slowAmplitude * hold[$0] / holdArea : 0) }
        let kernel = (0...Int(6 * sigma)).map { exp(-0.5 * pow((Double($0) - sigma) / sigma, 2)) }
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

    /// Impact at `minutes` after eating; a missing carbohydrate amount contributes nothing.
    func impact(carbohydrate c: Double?, fiber: Double?, minutes: Double) -> Double {
        guard minutes >= 0, minutes <= Double(Self.horizonMinutes),
              let carbs = carbAmount(total: c, fiber: fiber) else { return 0 }
        let curve = curve()
        let lower = Int(minutes), frac = minutes - Double(lower)
        let y = lower + 1 < curve.count ? curve[lower] * (1 - frac) + curve[lower + 1] * frac : curve[lower]
        return carbs * y
    }
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
