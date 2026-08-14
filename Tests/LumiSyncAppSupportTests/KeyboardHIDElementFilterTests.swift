import XCTest
import LumiSyncCore
@testable import LumiSyncAppSupport

final class KeyboardHIDElementFilterTests: XCTestCase {
    func testAcceptsOrdinaryKeyboardAndKeypadPresses() {
        XCTAssertTrue(KeyboardHIDElementFilter.isOrdinaryKeyPress(
            usagePage: 0x07,
            usage: 0x04,
            integerValue: 1
        ))
        XCTAssertTrue(KeyboardHIDElementFilter.isOrdinaryKeyPress(
            usagePage: 0x07,
            usage: 0x59,
            integerValue: 1
        ))
        XCTAssertTrue(KeyboardHIDElementFilter.isOrdinaryKeyPress(
            usagePage: 0x07,
            usage: 0x53,
            integerValue: 1
        ))
    }

    func testRejectsReleaseModifierConsumerAndReservedUsages() {
        XCTAssertFalse(KeyboardHIDElementFilter.isOrdinaryKeyPress(
            usagePage: 0x07,
            usage: 0x04,
            integerValue: 0
        ))
        XCTAssertFalse(KeyboardHIDElementFilter.isOrdinaryKeyPress(
            usagePage: 0x07,
            usage: 0xE0,
            integerValue: 1
        ))
        XCTAssertFalse(KeyboardHIDElementFilter.isOrdinaryKeyPress(
            usagePage: 0x0C,
            usage: 0xE9,
            integerValue: 1
        ))
        XCTAssertFalse(KeyboardHIDElementFilter.isOrdinaryKeyPress(
            usagePage: 0x07,
            usage: 0x01,
            integerValue: 1
        ))
        XCTAssertFalse(KeyboardHIDElementFilter.isOrdinaryKeyPress(
            usagePage: 0x01,
            usage: 0x06,
            integerValue: 1
        ))
    }

    func testRejectsKeyboardPageUsagesWithoutOrdinaryKeyDownEvents() {
        for usage: UInt32 in [
            0x39, // Caps Lock is delivered as a flags-changed event.
            0x46, // Print Screen is handled as a system function.
            0x47, // Scroll Lock is not a normal macOS keyDown source.
            0x48, // Pause is not a normal macOS keyDown source.
            0x65, // Application is not accepted by the conservative allowlist.
            0x66, // Power is handled outside ordinary keyboard events.
            0x82, // Locking Caps Lock.
            0xA4  // ExSel is not mapped to an ordinary macOS keyDown.
        ] {
            XCTAssertFalse(KeyboardHIDElementFilter.isOrdinaryKeyPress(
                usagePage: 0x07,
                usage: usage,
                integerValue: 1
            ))
        }
    }
}

final class KeyboardInputEventGateWindowTests: XCTestCase {
    func testCandidateExpiresOutsideShortAssociationWindow() {
        let device = KeyboardDeviceID(
            transport: "USB",
            vendorID: 1,
            productID: 2,
            locationID: 3
        )
        var gate = KeyboardInputEventGate(maximumAssociationNanoseconds: 5_000_000)
        gate.recordDeviceTransition(
            origin: .external(device),
            isPressed: true,
            nowNanoseconds: 10_000_000
        )

        XCTAssertNil(gate.consumeKeyDown(nowNanoseconds: 15_000_001))
    }

    func testCandidateWithinAssociationWindowIsConsumedOnce() {
        var gate = KeyboardInputEventGate(maximumAssociationNanoseconds: 5_000_000)
        gate.recordDeviceTransition(
            origin: .builtIn,
            isPressed: true,
            nowNanoseconds: 10_000_000
        )

        XCTAssertEqual(gate.consumeKeyDown(nowNanoseconds: 15_000_000), .builtIn)
        XCTAssertNil(gate.consumeKeyDown(nowNanoseconds: 15_000_000))
    }
}
