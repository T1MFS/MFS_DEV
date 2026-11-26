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
}
