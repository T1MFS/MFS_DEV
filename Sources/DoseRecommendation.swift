import Foundation

/// Something a complete dose recommendation needs. Inputs that are not in place yet are reported as missing
/// instead of being guessed, so the screen can say what is still a placeholder.
enum DoseInput: String, CaseIterable, Identifiable {
    case mealNutrition, carbRatio, sensitivity, glucose, target, insulinOnBoard, mealHistory

    var id: String { rawValue }

    var label: String {
        switch self {
        case .mealNutrition: return "Meal carbs and protein"
        case .carbRatio: return "Carb ratio (insulin profile)"
        case .sensitivity: return "Sensitivity (insulin profile)"
        case .glucose: return "Current glucose"
        case .target: return "Glucose target (insulin profile)"
        case .insulinOnBoard: return "Insulin on board (needs pump dose amounts)"
        case .mealHistory: return "Past results for this meal (Evaluate)"
        }
    }
}

/// Where insulin on board comes from. Pump history keeps event titles only, so nothing supplies it yet.
protocol InsulinOnBoardSource {
    func units(at date: Date) -> Double?
}

struct UnavailableInsulinOnBoard: InsulinOnBoardSource {
    func units(at date: Date) -> Double? { nil }
}

/// Where meal specific doses come from: results saved by the Evaluate tab. Nothing is saved there yet.
protocol MealHistorySource {
    func bolusUnits(forMealNamed name: String) -> Double?
}

struct UnavailableMealHistory: MealHistorySource {
    func bolusUnits(forMealNamed name: String) -> Double? { nil }
}

/// Everything a recommender may read. nil means not known.
struct DoseInputs: Equatable {
    var mealName: String?
    var carbohydrate: Double?
    var fiber: Double?
    var protein: Double?
    var fat: Double?
    var glucose: Double?
    var carbRatioGramsPerUnit: Double?
    var sensitivityMgdlPerUnit: Double?
    var targetMgdl: Double?
    var insulinOnBoard: Double?
    var basalUnitsPerHour: Double?
    /// Simple tab numbers, in grams.
    var simpleCarbGrams: Double?
    var simpleProteinGrams: Double?
    /// Units a past evaluation of this meal settled on; nil while none exist.
    var mealHistoryBolus: Double?
}

struct DoseRecommendation: Equatable {
    struct Part: Equatable, Identifiable {
        var label: String
        var units: Double
        var id: String { label }
    }

    var mode: DosingMode
    var parts: [Part] = []
    /// Rounded total of the parts, never below zero; nil when no part could be worked out.
    var bolusUnits: Double?
    var enhancedBasalUnitsPerHour: Double?
    var enhancedBasalMinutes: Int?
    /// Glucose rise the meal is expected to cause without insulin, in mg/dL.
    var expectedRiseMgdl: Double?
    /// Inputs that were not available. The recommendation is incomplete while this is not empty.
    var missing: [DoseInput] = []

    var isComplete: Bool { bolusUnits != nil && missing.isEmpty }

    /// Pod bolus step.
    static let increment = 0.05

    static func rounded(_ units: Double) -> Double {
        (max(units, 0) / increment).rounded() * increment
    }
}

protocol DoseRecommender {
    func recommend(_ inputs: DoseInputs, formula: DoseFormula) -> DoseRecommendation
}

extension DoseRecommender {
    /// Correction for glucose above target and the insulin already on board, shared by every tab.
    /// Each is added only when its inputs exist; the rest is reported as missing.
    fileprivate func finish(_ recommendation: DoseRecommendation, inputs: DoseInputs) -> DoseRecommendation {
        var result = recommendation
        if let glucose = inputs.glucose, let target = inputs.targetMgdl, let sensitivity = inputs.sensitivityMgdlPerUnit, sensitivity > 0 {
            result.parts.append(.init(label: "Correction", units: (glucose - target) / sensitivity))
        } else {
            if inputs.glucose == nil { result.missing.append(.glucose) }
            if inputs.targetMgdl == nil { result.missing.append(.target) }
            if inputs.sensitivityMgdlPerUnit == nil, !result.missing.contains(.sensitivity) { result.missing.append(.sensitivity) }
        }
        if let iob = inputs.insulinOnBoard {
            result.parts.append(.init(label: "Insulin on board", units: -iob))
        } else {
            result.missing.append(.insulinOnBoard)
        }
        var seen = Set<DoseInput>()
        result.missing = result.missing.filter { seen.insert($0).inserted }
        result.bolusUnits = result.parts.isEmpty ? nil : DoseRecommendation.rounded(result.parts.map(\.units).reduce(0, +))
        return result
    }
}

/// Simple tab: the carbs and protein grams typed in, each covered at the profile's carb ratio.
/// Toy model: protein is covered like carbs, and the rise is the meal units times sensitivity.
struct SimpleDoseRecommender: DoseRecommender {
    func recommend(_ inputs: DoseInputs, formula: DoseFormula) -> DoseRecommendation {
        var result = DoseRecommendation(mode: .simple)
        if inputs.simpleCarbGrams == nil { result.missing.append(.mealNutrition) }
        guard let ratio = inputs.carbRatioGramsPerUnit, ratio > 0 else {
            result.missing.append(.carbRatio)
            return finish(result, inputs: inputs)
        }
        var mealUnits = 0.0
        if let carbs = inputs.simpleCarbGrams {
            result.parts.append(.init(label: "Carbs", units: carbs / ratio))
            mealUnits += carbs / ratio
        }
        if let protein = inputs.simpleProteinGrams {
            result.parts.append(.init(label: "Protein", units: protein / ratio))
            mealUnits += protein / ratio
        }
        if let sensitivity = inputs.sensitivityMgdlPerUnit, !result.parts.isEmpty {
            result.expectedRiseMgdl = mealUnits * sensitivity
        } else {
            result.missing.append(.sensitivity)
        }
        return finish(result, inputs: inputs)
    }
}

/// Experimental tab: a bolus and an enhanced basal that together offset the formula's modelled meal impact.
struct ExperimentalDoseRecommender: DoseRecommender {
    func recommend(_ inputs: DoseInputs, formula: DoseFormula) -> DoseRecommendation {
        var result = DoseRecommendation(mode: .experimental)
        if inputs.carbohydrate == nil && inputs.protein == nil { result.missing.append(.mealNutrition) }
        guard let sensitivity = inputs.sensitivityMgdlPerUnit else {
            result.missing.append(.sensitivity)
            return finish(result, inputs: inputs)
        }
        if let dose = formula.experimentalDose(carbohydrate: inputs.carbohydrate, fiber: inputs.fiber, protein: inputs.protein,
                                               fat: inputs.fat, sensitivityMgdlPerUnit: sensitivity) {
            result.parts.append(.init(label: "Meal bolus", units: dose.bolusUnits))
            result.enhancedBasalUnitsPerHour = dose.extraBasalUnitsPerHour
            result.enhancedBasalMinutes = dose.extraBasalMinutes
            result.expectedRiseMgdl = dose.riseMgdl
        }
        return finish(result, inputs: inputs)
    }
}

/// Meal specific tab: a dose learned from earlier evaluations of the same meal. Nothing records them yet.
struct MealSpecificDoseRecommender: DoseRecommender {
    func recommend(_ inputs: DoseInputs, formula: DoseFormula) -> DoseRecommendation {
        var result = DoseRecommendation(mode: .mealSpecific)
        if let past = inputs.mealHistoryBolus {
            result.parts.append(.init(label: "Past meal bolus", units: past))
        } else {
            result.missing.append(.mealHistory)
        }
        return finish(result, inputs: inputs)
    }
}

enum DoseRecommenders {
    static func recommender(for mode: DosingMode) -> DoseRecommender {
        switch mode {
        case .mealSpecific: return MealSpecificDoseRecommender()
        case .simple: return SimpleDoseRecommender()
        case .experimental: return ExperimentalDoseRecommender()
        }
    }
}
