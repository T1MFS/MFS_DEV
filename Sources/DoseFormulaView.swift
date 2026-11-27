import SwiftUI

/// Edits the seven factors of toy model two and previews the curve for the accepted food.
/// Pushed from the Advanced row of the Dosing section.
struct DoseFormulaView: View {
    @EnvironmentObject private var formulaStore: DoseFormulaStore
    @EnvironmentObject private var foodStore: AcceptedFoodStore
    @State private var showHelp = false

    var body: some View {
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
        .toolbar { ToolbarItem(placement: .primaryAction) { Button("Help") { showHelp = true } } }
        .sheet(isPresented: $showHelp) { DoseFormulaHelpView() }
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

/// In-app copy of docs/DOSE_FORMULA.md.
struct DoseFormulaHelpView: View {
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            List {
                section("What it computes", """
                B(t) is the modelled impact on blood glucose t minutes after eating, on a one-minute grid from 0 to 720 minutes. It is a hand-shaped toy model, not fitted to data, and is not yet used for the forecast or bolus values.
                """)
                section("Inputs", """
                carbs: carbohydrate grams adjusted by the Fiber setting. Drives the fast component.
                protein: protein grams. Drives the slow component.
                fat: fat grams. Adds no glucose; only sets the smear time.
                Missing amounts count as 0. Fiber: Total carbs uses carbs as entered; Net (fiber ÷ 2) uses max(carbs − fiber/2, 0); Net (all fiber) uses max(carbs − fiber, 0).
                """)
                section("The seven factors", """
                Times (min): t1 fast peak (20), t2 slow hold center (240), σ smear per gram of fat (26.3).
                Amplitudes: A1 per gram of carbs (1.0), A2 per gram of protein (1.5), C overall scale (0.5).
                Offset: b baseline (0).
                Fixed: hold length H = 120 min, edge width w = 60 min.
                """)
                section("Total curve", """
                B(t) = b + C · ( s * [ A1·carbs·g_fast + A2·protein·g_hold ] )(t)
                * is convolution over minutes.
                """, mono: true)
                section("Fast component g_fast", """
                g_fast(t) = (t / t1²) · e^(−t / t1), t ≥ 0
                A gamma curve of shape 2 with unit area: two equal exponential steps of t1 minutes in series, so it peaks at t1.
                """, mono: true)
                section("Slow component g_hold", """
                L(x) = 1 / (1 + e^(−x))
                raw(t) = L((t − t2 + H/2)/w) − L((t − t2 − H/2)/w)
                g_hold(t) = raw(t) / Σ raw(t')
                A flat top centered at t2 with hold H and logistic edges of width w, normalized to unit area on the 0…720 grid.
                """, mono: true)
                section("Smear s (fat)", """
                σ_eff = σ × fat grams
                s(τ) ∝ exp[ −½ ((τ − σ_eff)/σ_eff)² ], τ ≥ 0, normalized to sum 1
                A Gaussian whose mean delay equals its standard deviation σ_eff, truncated at 6·σ_eff. With no fat there is no smear. Fat moves and flattens the curve but does not change its total area.
                """, mono: true)
                section("Landmark conversions", """
                t1 = T_peak (time to peak)
                t2 = (T_on + T_off) / 2 and H = T_off − T_on (hold start and end)
                w = R / (2 ln 9) (R = 10%–90% rise time; 2 ln 9 ≈ 4.394)
                σ_eff = B90 / (1 + 1.2816) (B90 = time for 90% of the blur; 1.2816 is the normal z-score for 90%)
                Defaults: T_peak 20; T_on 180, T_off 300; R 263.6 gives w 60; B90 60 gives σ 26.3 (for 1 g of fat).
                """, mono: true)
                section("Default curve check", """
                With 1 g each of carbs, protein and fat: peak 0.0065 at minute 62, dip about 0.0020 at 166, second hump about 0.0029 near 276, effectively 0 by 600.
                """)
                section("Insulin action side", """
                B(t) above is the food side only. The insulin side is stored data, not yet a computed model.
                Insulin profiles (Manage > menu > Insulin profiles): time frames, each with basal (units/hour) and sensitivity (mg/dl one unit lowers glucose). The Main profile or a hand-chosen alternative is active; automatic switching has an extension point but no hooks.
                Insulin table: population half-life and duration per insulin type (for example rapid-acting about 1 hour half-life, 3–5 hours duration). Reference only; not dosing advice and not used in any calculation.
                """)
                section("How the models combine", """
                The food model and the insulin model are independent; neither is folded into the other. Predicted glucose is their simple sum:
                predicted glucose(t) = starting glucose + food model(t) + insulin model(t)
                The insulin term lowers glucose. Any future model would be another independent term. Not built yet: the insulin model and the sum. B(t) is in model units per gram until fitted to mg/dl, so the terms cannot be added meaningfully yet.
                """, mono: true)
                section("Limits", """
                Shapes are hand-chosen and expected to be fitted to data later. Fat affects timing only; person-specific effects of fat on insulin are not modelled. Glucose level does not enter the formula. Results are relative until fitted.
                """)
            }
            .navigationTitle("Dose formula help")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement: .confirmationAction) { Button("Done") { dismiss() } } }
        }
    }

    private func section(_ title: String, _ text: String, mono: Bool = false) -> some View {
        Section(title) {
            Text(text).font(mono ? .footnote.monospaced() : .footnote)
        }
    }
}
