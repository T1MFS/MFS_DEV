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
                    Text("B(t) = b + C·(s * [A1·carbs·g_fast + A2·protein·g_hold])(t)")
                        .font(.footnote.monospaced())
                    Text("B(t) is the impact on blood glucose t minutes after eating. Carbohydrate (net of fiber, below) drives g_fast, which peaks at t1. Protein drives g_hold, a flat top centered at t2 (120 min hold, 60 min edge width, both fixed). Fat adds no glucose; it only sets the time smear s, whose width is σ minutes per gram of fat.")
                        .font(.footnote).foregroundStyle(.secondary)
                }
                Section("Times (minutes)") {
                    field("t1  fast peak", $formulaStore.formula.fastPeakMinutes)
                    field("t2  slow hold center", $formulaStore.formula.slowCenterMinutes)
                    field("σ  smear per g fat", $formulaStore.formula.smearMinutesPerGramFat)
                }
                Section("Amplitudes") {
                    field("A1  carbs (fast)", $formulaStore.formula.fastAmplitude)
                    field("A2  protein (slow)", $formulaStore.formula.slowAmplitude)
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
            let curve = formulaStore.formula.curve(carbohydrate: food.totalCarbohydrates, fiber: food.totalFiber,
                                                   protein: food.totalProtein, fat: food.totalFat)
            Text("For \(food.product.name)").font(.headline)
            ForEach([0.0, 30, 60, 120, 180, 240, 360], id: \.self) { minutes in
                LabeledContent("t = \(Int(minutes)) min", value: curve[Int(minutes)].formatted(.number.precision(.fractionLength(0...3))))
            }
        } else {
            Text("Accept a food to preview B(t).").font(.footnote).foregroundStyle(.secondary)
        }
    }
}
