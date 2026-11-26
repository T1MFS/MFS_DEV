import XCTest
@testable import MFS

final class DoseFormulaTests: XCTestCase {
    func testDefaultCurveMatchesToyModelTwoLandmarks() {
        let curve = DoseFormula().curve()
        let peak = curve.indices.max { curve[$0] < curve[$1] }!
        XCTAssertEqual(peak, 62)
        XCTAssertEqual(curve[62], 0.0065, accuracy: 5e-5)
        XCTAssertEqual(curve[166], 0.0020, accuracy: 5e-5)
        XCTAssertEqual(curve[276], 0.0029, accuracy: 5e-5)
        XCTAssertLessThan(curve[600], 1e-4)
    }

    func testOffsetAndFiberAndAmount() {
        var formula = DoseFormula()
        formula.offset = 0.01
        formula.fiber = .half
        // net carbs 40 - 10/2 = 35
        let base = DoseFormula().curve()[62]
        XCTAssertEqual(formula.impact(carbohydrate: 40, fiber: 10, minutes: 62), 35 * (base + 0.01), accuracy: 1e-9)
        XCTAssertEqual(formula.impact(carbohydrate: nil, fiber: nil, minutes: 62), 0)
        XCTAssertEqual(formula.impact(carbohydrate: 40, fiber: nil, minutes: -1), 0)
    }
}
