import XCTest
@testable import LumiSyncCore

final class SmoothingTests: XCTestCase {
    func testManualChangeStartsWithinThreeHundredMilliseconds() {
        let plan = SmoothingPolicy().plan(kind: .manual, from: 0.1, to: 0.8)
        XCTAssertLessThanOrEqual(plan.debounceMilliseconds, 300)
        XCTAssertEqual(plan.target, 0.8)
    }

    func testAutomaticChangeUsesDebounceAndTransition() {
        let plan = SmoothingPolicy().plan(kind: .automatic, from: 0.1, to: 0.8)
        XCTAssertEqual(plan.debounceMilliseconds, 500)
        XCTAssertEqual(plan.durationMilliseconds, 1500)
    }

    func testSafetyOffIsImmediate() {
        let plan = SmoothingPolicy().plan(kind: .automatic, from: 0.8, to: 0.0)
        XCTAssertEqual(plan.debounceMilliseconds, 0)
        XCTAssertEqual(plan.durationMilliseconds, 0)
    }
}
