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

        gate.recordDeviceTransition(origin: .external(device), isPressed: true)
        XCTAssertEqual(gate.consumeKeyDown(), .external(device))
        XCTAssertNil(gate.consumeKeyDown())
    }

    func testReleaseAndNonKeyboardChangesNeverProduceOrigin() {
        var gate = KeyboardInputEventGate()

        gate.recordDeviceTransition(origin: .builtIn, isPressed: false)

        XCTAssertNil(gate.consumeKeyDown())
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

        gate.recordDeviceTransition(origin: .external(first), isPressed: true)
        gate.recordDeviceTransition(origin: .external(second), isPressed: true)

        XCTAssertNil(gate.consumeKeyDown())
    }

    func testDisabledTapClearsPendingSource() {
        var gate = KeyboardInputEventGate()
        gate.recordDeviceTransition(origin: .builtIn, isPressed: true)

        gate.invalidatePendingInput()

        XCTAssertNil(gate.consumeKeyDown())
    }
}
