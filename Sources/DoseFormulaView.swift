import SwiftUI

/// Edits the seven factors of toy model two and previews the curve for the accepted food.
struct DoseFormulaView: View {
    @EnvironmentObject private var formulaStore: DoseFormulaStore
    @EnvironmentObject private var foodStore: AcceptedFoodStore
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    Text("B(t) = b + C·(s_σ * [A1·g_fast + A2·g_hold])(t) × net carbohydrate grams")
                        .font(.footnote.monospaced())
                    Text("B(t) is the impact on blood glucose t minutes after eating. g_fast peaks at t1; g_hold is a flat top centered at t2 (120 min hold, 60 min edge width, both fixed); s_σ smears the result by σ minutes.")
                        .font(.footnote).foregroundStyle(.secondary)
                }
                Section("Times (minutes)") {
                    field("t1  fast peak", $formulaStore.formula.fastPeakMinutes)
                    field("t2  slow hold center", $formulaStore.formula.slowCenterMinutes)
                    field("σ  smear", $formulaStore.formula.smearMinutes)
                }
                Section("Amplitudes") {
                    field("A1  fast weight", $formulaStore.formula.fastAmplitude)
                    field("A2  slow weight", $formulaStore.formula.slowAmplitude)
                    field("C  overall scale", $formulaStore.formula.scale)
                }
                Section("Offset") {
                    field("b  baseline", $formulaStore.formula.offset)
                }
                Section("Carbohydrate") {
                    Picker("Fiber", selection: $formulaStore.formula.fiber) {
                        ForEach(CarbFiberTreatment.allCases) { Text($0.label).tag($0) }
                    }
                }
                Section("Preview") { preview }
            }
            .navigationTitle("Dose formula")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement: .confirmationAction) { Button("Done") { dismiss() } } }
        }
    }

    private func field(_ title: String, _ value: Binding<Double>) -> some View {
        LabeledContent(title) {
            TextField(title, value: value, format: .number)
                .keyboardType(.numbersAndPunctuation)
                .multilineTextAlignment(.trailing)
                .frame(width: 100)
        }
    }

    @ViewBuilder private var preview: some View {
        if let food = foodStore.food {
            let curve = formulaStore.formula.curve()
            Text("For \(food.product.name)").font(.headline)
            ForEach([0.0, 30, 60, 120, 180, 240, 360], id: \.self) { minutes in
                let value = (formulaStore.formula.carbAmount(total: food.totalCarbohydrates, fiber: food.totalFiber) ?? 0) * curve[Int(minutes)]
                LabeledContent("t = \(Int(minutes)) min", value: value.formatted(.number.precision(.fractionLength(0...3))))
            }
        } else {
            Text("Accept a food to preview B(t).").font(.footnote).foregroundStyle(.secondary)
        }
    }
}
