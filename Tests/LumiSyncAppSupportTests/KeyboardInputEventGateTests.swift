import XCTest
import LumiSyncCore
@testable import LumiSyncAppSupport

final class KeyboardInputEventGateTests: XCTestCase {
    func testKeyDownRequiresMatchingDevicePressBeforeReportingOrigin() {
        let device = KeyboardDeviceID(
            transport: "USB",
            vendorID: 1,
            productID: 2,
            locationID: 3
        )
        var gate = KeyboardInputEventGate()

        gate.recordDeviceTransition(origin: .external(device), isPressed: true, nowNanoseconds: 0)
        XCTAssertEqual(gate.consumeKeyDown(nowNanoseconds: 0), .external(device))
        XCTAssertNil(gate.consumeKeyDown(nowNanoseconds: 0))
    }

    func testReleaseAndNonKeyboardChangesNeverProduceOrigin() {
        var gate = KeyboardInputEventGate()

        gate.recordDeviceTransition(origin: .builtIn, isPressed: false, nowNanoseconds: 0)

        XCTAssertNil(gate.consumeKeyDown(nowNanoseconds: 0))
    }

    func testMultipleUnmatchedDevicePressesFailClosed() {
        let first = KeyboardDeviceID(
            transport: "USB",
            vendorID: 1,
            productID: 2,
            locationID: 3
        )
        let second = KeyboardDeviceID(
            transport: "Bluetooth",
            vendorID: 4,
            productID: 5,
            locationID: nil
        )
        var gate = KeyboardInputEventGate()

        gate.recordDeviceTransition(origin: .external(first), isPressed: true, nowNanoseconds: 0)
        gate.recordDeviceTransition(origin: .external(second), isPressed: true, nowNanoseconds: 1)

        XCTAssertNil(gate.consumeKeyDown(nowNanoseconds: 1))
    }

    func testDisabledTapClearsPendingSource() {
        var gate = KeyboardInputEventGate()
        gate.recordDeviceTransition(origin: .builtIn, isPressed: true, nowNanoseconds: 0)

        gate.invalidatePendingInput()

        XCTAssertNil(gate.consumeKeyDown(nowNanoseconds: 0))
    }
}
