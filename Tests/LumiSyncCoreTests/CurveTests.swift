import XCTest
@testable import LumiSyncCore

final class CurveTests: XCTestCase {
    func testComfortPresetControlPoints() throws {
        let curve = CurvePreset.comfort.curve
        XCTAssertEqual(curve.points.first, CurvePoint(display: 0.0, keyboard: 0.0))
        XCTAssertEqual(curve.points[1], CurvePoint(display: 0.01, keyboard: 1.0))
        XCTAssertEqual(curve.points.last, CurvePoint(display: 1.0, keyboard: 0.0))
    }

    func testPiecewiseInterpolationAndIntensityClamp() throws {
        let curve = try BrightnessCurve(points: [
            CurvePoint(display: 0.0, keyboard: 0.0),
            CurvePoint(display: 0.5, keyboard: 1.0),
            CurvePoint(display: 1.0, keyboard: 0.0)
        ])
        XCTAssertEqual(curve.value(at: 0.25, intensity: 1.0), 0.5, accuracy: 0.0001)
        XCTAssertEqual(curve.value(at: 0.25, intensity: 0.5), 0.25, accuracy: 0.0001)
        XCTAssertEqual(curve.value(at: 0.25, intensity: 4.0), 1.0, accuracy: 0.0001)
    }

    func testInvalidCustomCurveRejected() {
        XCTAssertThrowsError(try BrightnessCurve(points: [
            CurvePoint(display: 0.1, keyboard: 0.2),
            CurvePoint(display: 0.1, keyboard: 0.3)
        ]))
    }
}
