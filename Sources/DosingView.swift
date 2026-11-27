import SwiftUI

private func unitsText(_ units: Double?) -> String {
    units.map { "\($0.formatted(.number.precision(.fractionLength(0...1)))) U" } ?? "—"
}

private func rateText(_ rate: Double?) -> String {
    rate.map { "\($0.formatted(.number.precision(.fractionLength(0...2)))) U/h" } ?? "—"
}

/// Dosing section of Manage: three tabs on top, the formula behind Advanced.
/// Everything here is shown for the user to act on; the app sends nothing to a pump.
struct DosingSection: View {
    @EnvironmentObject private var dosing: DosingStore
    @EnvironmentObject private var foodStore: AcceptedFoodStore
    @EnvironmentObject private var formulaStore: DoseFormulaStore
    @EnvironmentObject private var profileStore: InsulinProfileStore

    var body: some View {
        Section("Dosing") {
            Picker("Dosing", selection: $dosing.mode) {
                ForEach(DosingMode.allCases) { Text($0.label).tag($0) }
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            switch dosing.mode {
            case .mealSpecific: mealSpecific
            case .simple: simple
            case .experimental: experimental
            }
        }
        Section {
            NavigationLink("Advanced: dose formula") { DoseFormulaView() }
        }
    }

    private var mealSpecific: some View {
        Group {
            Text("Doses learned for this meal from your Evaluate results.")
            Text("No evaluated results for this meal yet. Review the meal in the Evaluate tab to build them.")
                .font(.footnote).foregroundStyle(.secondary)
        }
    }

    private var simple: some View {
        Group {
            LabeledContent("Carbs") {
                numberField("Carbs", Binding(get: { dosing.simpleCarbs }, set: { dosing.simpleCarbs = $0 }), unit: "U")
            }
            LabeledContent("Protein") {
                numberField("Protein", Binding(get: { dosing.simpleProtein }, set: { dosing.simpleProteinEntry = $0 }), unit: "U")
            }
            if dosing.simpleProteinEntry != nil {
                Button("Protein = carbs ÷ \(Int(DosingStore.proteinDivisor))") { dosing.simpleProteinEntry = nil }
                    .font(.footnote)
            } else {
                Text("Protein defaults to carbs ÷ \(Int(DosingStore.proteinDivisor)). Type a number to override it.")
                    .font(.footnote).foregroundStyle(.secondary)
            }
        }
    }

    private func numberField(_ title: String, _ value: Binding<Double?>, unit: String) -> some View {
        HStack(spacing: 4) {
            TextField(title, value: value, format: .number.precision(.fractionLength(0...1)))
                .keyboardType(.decimalPad)
                .multilineTextAlignment(.trailing)
                .frame(width: 80)
            Text(unit).foregroundStyle(.secondary)
        }
    }

    private var experimental: some View {
        Group {
            if let dose = experimentalDose(foodStore.food) {
                LabeledContent("Bolus", value: unitsText(dose.bolusUnits))
                LabeledContent("Enhanced basal", value: "+\(rateText(dose.extraBasalUnitsPerHour)) for \(dose.extraBasalMinutes / 60) h \(dose.extraBasalMinutes % 60) min")
                Text("Drawn from the dose formula to match the meal's modelled impact. Review the result in the Evaluate tab. Experimental: the formula is not fitted to data.")
                    .font(.footnote).foregroundStyle(.secondary)
            } else if foodStore.food == nil {
                Text("Accept a food to see an experimental dose.").foregroundStyle(.secondary)
            } else {
                Text("No dose available. Check the formula under Advanced and the sensitivity in your insulin profile.")
                    .font(.footnote).foregroundStyle(.secondary)
            }
        }
    }

    private func experimentalDose(_ food: AcceptedFood?) -> ExperimentalDose? {
        DosingSummary.experimentalDose(food: food, formula: formulaStore.formula, profiles: profileStore)
    }
}

enum DosingSummary {
    static func experimentalDose(food: AcceptedFood?, formula: DoseFormula, profiles: InsulinProfileStore) -> ExperimentalDose? {
        guard let food, let sensitivity = profiles.segment(at: Date())?.sensitivityMgdlPerUnit else { return nil }
        return formula.experimentalDose(carbohydrate: food.totalCarbohydrates, fiber: food.totalFiber,
                                        protein: food.totalProtein, fat: food.totalFat,
                                        sensitivityMgdlPerUnit: sensitivity)
    }
}

/// Meal grams and the dose for the selected dosing tab, pinned to the bottom of Manage.
struct DosingFooter: View {
    let food: AcceptedFood?
    @EnvironmentObject private var dosing: DosingStore
    @EnvironmentObject private var formulaStore: DoseFormulaStore
    @EnvironmentObject private var profileStore: InsulinProfileStore

    var body: some View {
        Grid(horizontalSpacing: 8, verticalSpacing: 10) {
            GridRow {
                cell(grams(food?.totalCarbohydrates), "Carbohydrate", "Carbs in the meal (g)")
                cell(grams(food?.totalProtein), "Protein", "Protein in the meal (g)")
                cell(grams(food?.totalFat), "Fat", "Fat in the meal (g)")
            }
            Divider()
            GridRow {
                switch dosing.mode {
                case .simple:
                    cell(unitsText(dosing.simpleCarbs), "Bolus for carbohydrate", "Simple bolus (U)")
                    cell(unitsText(dosing.simpleProtein), "Bolus for protein", "Simple bolus (U)")
                    cell(rateText(currentBasal), "Basal", "Current basal rate (U/h)")
                case .experimental:
                    let dose = DosingSummary.experimentalDose(food: food, formula: formulaStore.formula, profiles: profileStore)
                    cell(unitsText(dose?.bolusUnits), "Bolus", "Experimental bolus (U)")
                    cell(rateText(dose.map { $0.extraBasalUnitsPerHour + (currentBasal ?? 0) }), "Enhanced basal", "Basal plus extra (U/h)")
                    cell(dose.map { "\($0.extraBasalMinutes) min" } ?? "—", "Duration", "Enhanced basal length")
                case .mealSpecific:
                    cell("—", "Bolus", "Meal specific (U)")
                    cell("—", "Enhanced basal", "Meal specific (U/h)")
                    cell(rateText(currentBasal), "Basal", "Current basal rate (U/h)")
                }
            }
        }
        .padding(12)
        .frame(maxWidth: .infinity)
        .background(.bar)
    }

    private var currentBasal: Double? { profileStore.segment(at: Date())?.basalUnitsPerHour }

    private func grams(_ value: Double?) -> String {
        value.map { "\($0.formatted()) g" } ?? "Unavailable"
    }

    private func cell(_ value: String, _ title: String, _ definition: String) -> some View {
        VStack(spacing: 2) {
            Text(value).font(.title3.bold())
            Text(title).font(.caption.weight(.semibold))
            Text(definition).font(.caption2).foregroundStyle(.secondary)
        }
        .multilineTextAlignment(.center)
        .frame(maxWidth: .infinity)
    }
}
