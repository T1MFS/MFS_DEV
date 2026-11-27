import XCTest
@testable import MFS

final class DoseFormulaTests: XCTestCase {
    func testDefaultCurveMatchesToyModelTwoLandmarks() {
        let curve = DoseFormula().curve(carbohydrate: 1, protein: 1, fat: 1)
        let peak = curve.indices.max { curve[$0] < curve[$1] }!
        XCTAssertEqual(peak, 62)
        XCTAssertEqual(curve[62], 0.0065, accuracy: 5e-5)
        XCTAssertEqual(curve[166], 0.0020, accuracy: 5e-5)
        XCTAssertEqual(curve[276], 0.0029, accuracy: 5e-5)
        XCTAssertLessThan(curve[600], 1e-4)
    }

    func testFatOnlyChangesTimingNotTotal() {
        let formula = DoseFormula()
        let lean = formula.curve(carbohydrate: 30, protein: 20, fat: 0.5)
        let fatty = formula.curve(carbohydrate: 30, protein: 20, fat: 2)
        XCTAssertEqual(lean.reduce(0, +), fatty.reduce(0, +), accuracy: lean.reduce(0, +) * 0.01)
        XCTAssertGreaterThan(lean.max()!, fatty.max()!)
        XCTAssertLessThan(lean.indices.max { lean[$0] < lean[$1] }!, fatty.indices.max { fatty[$0] < fatty[$1] }!)
    }

    func testCarbsDriveFastAndProteinDriveSlow() {
        var formula = DoseFormula()
        formula.offset = 0.01
        let carbsOnly = formula.curve(carbohydrate: 10, protein: 0, fat: 1)
        let proteinOnly = formula.curve(carbohydrate: 0, protein: 10, fat: 1)
        XCTAssertGreaterThan(carbsOnly[60], proteinOnly[60])
        XCTAssertGreaterThan(proteinOnly[240], carbsOnly[240])
        XCTAssertEqual(formula.curve(carbohydrate: 0, protein: 0, fat: 1)[100], 0.01, accuracy: 1e-12)
    }

    func testFiberAndMissingAmounts() {
        var formula = DoseFormula()
        formula.fiber = .half
        // net carbs 40 - 10/2 = 35
        XCTAssertEqual(formula.impact(carbohydrate: 40, fiber: 10, protein: 5, fat: 1, minutes: 62),
                       formula.curve(carbohydrate: 35, protein: 5, fat: 1)[62], accuracy: 1e-12)
        XCTAssertEqual(formula.impact(carbohydrate: nil, fiber: nil, protein: nil, fat: nil, minutes: 62), 0)
        XCTAssertEqual(formula.impact(carbohydrate: 40, fiber: nil, protein: 1, fat: 1, minutes: -1), 0)
    }

    func testExperimentalDoseCoversWholeImpactAndSplitsBolusFromBasal() throws {
        let formula = DoseFormula()
        let dose = try XCTUnwrap(formula.experimentalDose(carbohydrate: 30, fiber: nil, protein: 40, fat: 5, sensitivityMgdlPerUnit: 50))
        let total = formula.curve(carbohydrate: 30, protein: 40, fat: 5).reduce(0, +)
        let tailUnits = dose.extraBasalUnitsPerHour * Double(dose.extraBasalMinutes) / 60
        XCTAssertEqual(dose.bolusUnits + tailUnits, total / 50, accuracy: total / 50 * 0.01)
        XCTAssertGreaterThan(dose.bolusUnits, 0)
        XCTAssertGreaterThan(dose.extraBasalUnitsPerHour, 0)
        XCTAssertNil(formula.experimentalDose(carbohydrate: 30, fiber: nil, protein: 40, fat: 5, sensitivityMgdlPerUnit: 0))
        XCTAssertNil(formula.experimentalDose(carbohydrate: nil, fiber: nil, protein: nil, fat: nil, sensitivityMgdlPerUnit: 50))
    }

    func testSimpleProteinDefaultsToCarbsOverFiveUntilTyped() {
        let store = DosingStore(defaults: UserDefaults(suiteName: "DosingStoreTests")!)
        XCTAssertNil(store.simpleProtein)
        store.simpleCarbs = 10
        XCTAssertEqual(store.simpleProtein, 2)
        store.simpleProteinEntry = 3
        XCTAssertEqual(store.simpleProtein, 3)
        store.simpleProteinEntry = nil
        XCTAssertEqual(store.simpleProtein, 2)
    }

    func testSimpleRecommendationAddsPartsAndListsMissingInputs() {
        var inputs = DoseInputs()
        inputs.simpleCarbGrams = 40
        inputs.simpleProteinGrams = 8
        inputs.carbRatioGramsPerUnit = 10
        inputs.sensitivityMgdlPerUnit = 50
        let partial = SimpleDoseRecommender().recommend(inputs, formula: DoseFormula())
        XCTAssertEqual(partial.bolusUnits ?? 0, 4.8, accuracy: 1e-9)
        // (40 + 8) g / 10 g per U = 4.8 U, times 50 mg/dl per U
        XCTAssertEqual(partial.expectedRiseMgdl ?? 0, 240, accuracy: 1e-9)
        XCTAssertFalse(partial.isComplete)
        XCTAssertTrue(partial.missing.contains(.insulinOnBoard))
        XCTAssertTrue(partial.missing.contains(.glucose))

        inputs.glucose = 200
        inputs.targetMgdl = 100
        inputs.insulinOnBoard = 1
        let full = SimpleDoseRecommender().recommend(inputs, formula: DoseFormula())
        // 4 + 0.8 + (200-100)/50 - 1
        XCTAssertEqual(full.bolusUnits ?? 0, 5.8, accuracy: 1e-9)
        XCTAssertTrue(full.isComplete)
    }

    func testRecommendationNeverNegativeAndMealSpecificIsPlaceholder() {
        var inputs = DoseInputs()
        inputs.simpleCarbGrams = 10
        inputs.carbRatioGramsPerUnit = 10
        inputs.glucose = 60
        inputs.targetMgdl = 100
        inputs.sensitivityMgdlPerUnit = 20
        inputs.insulinOnBoard = 0
        XCTAssertEqual(SimpleDoseRecommender().recommend(inputs, formula: DoseFormula()).bolusUnits, 0)

        inputs.carbRatioGramsPerUnit = nil
        let noRatio = SimpleDoseRecommender().recommend(inputs, formula: DoseFormula())
        XCTAssertTrue(noRatio.missing.contains(.carbRatio))
        XCTAssertNil(noRatio.expectedRiseMgdl)

        let meal = MealSpecificDoseRecommender().recommend(DoseInputs(), formula: DoseFormula())
        XCTAssertNil(meal.bolusUnits)
        XCTAssertTrue(meal.missing.contains(.mealHistory))
    }

    func testExperimentalRecommendationNeedsSensitivity() {
        var inputs = DoseInputs()
        inputs.carbohydrate = 30
        inputs.protein = 20
        inputs.fat = 5
        let without = ExperimentalDoseRecommender().recommend(inputs, formula: DoseFormula())
        XCTAssertNil(without.bolusUnits.flatMap { $0 > 0 ? $0 : nil })
        XCTAssertTrue(without.missing.contains(.sensitivity))
        inputs.sensitivityMgdlPerUnit = 50
        let with = ExperimentalDoseRecommender().recommend(inputs, formula: DoseFormula())
        XCTAssertGreaterThan(with.bolusUnits ?? 0, 0)
        XCTAssertNotNil(with.enhancedBasalUnitsPerHour)
    }

    func testScheduleItemsAddMidnightWrapAndNeedEveryValue() {
        let profile = InsulinProfile(name: "p", segments: [
            ProfileSegment(startMinute: 360, basalUnitsPerHour: 1, sensitivityMgdlPerUnit: 50, carbRatioGramsPerUnit: 10),
            ProfileSegment(startMinute: 1200, basalUnitsPerHour: 0.5, sensitivityMgdlPerUnit: 60)])
        XCTAssertEqual(profile.scheduleItems { $0.basalUnitsPerHour },
                       [ScheduleItem(startTime: 0, value: 0.5), ScheduleItem(startTime: 21600, value: 1),
                        ScheduleItem(startTime: 72000, value: 0.5)])
        XCTAssertNil(profile.scheduleItems { $0.carbRatioGramsPerUnit })
    }

    func testProfileFromSchedulesMergesStartTimes() throws {
        let profile = try XCTUnwrap(InsulinProfile.make(
            name: "p",
            basal: [ScheduleItem(startTime: 0, value: 1)],
            sensitivity: [ScheduleItem(startTime: 0, value: 50), ScheduleItem(startTime: 43200, value: 40)],
            carbRatio: [ScheduleItem(startTime: 0, value: 10)]))
        XCTAssertEqual(profile.segments.map(\.startMinute), [0, 720])
        XCTAssertEqual(profile.segments[1].basalUnitsPerHour, 1)
        XCTAssertEqual(profile.segments[1].sensitivityMgdlPerUnit, 40)
        XCTAssertEqual(profile.segments[1].carbRatioGramsPerUnit, 10)
        XCTAssertNil(profile.segments[1].targetMgdl)
    }

    func testInsulinActionModelEndpointsAndDecay() {
        let model = InsulinActionModel()
        XCTAssertEqual(model.percentRemaining(at: 0), 1)
        XCTAssertEqual(model.percentRemaining(at: 6 * 3600 + 600), 0)
        let samples = stride(from: 0.0, through: 6 * 3600, by: 900).map { model.percentRemaining(at: $0) }
        XCTAssertEqual(samples, samples.sorted(by: >))
    }

    func testInsulinOnBoardFromRecordedDoses() {
        let now = Date()
        let bolus = InsulinDose(kind: .bolus, start: now.addingTimeInterval(-1800), end: now.addingTimeInterval(-1800), amount: 2)
        let basal = InsulinDose(kind: .basal, start: now, end: now.addingTimeInterval(1800), amount: 2)
        XCTAssertEqual(basal.units, 1, accuracy: 1e-9)
        XCTAssertNil(RecordedInsulinOnBoard(doses: []).units(at: now))
        let iob = RecordedInsulinOnBoard(doses: [bolus, basal]).units(at: now)
        XCTAssertNotNil(iob)
        XCTAssertGreaterThan(iob ?? 0, 1)
        XCTAssertLessThan(iob ?? 3, 2)
    }
}
