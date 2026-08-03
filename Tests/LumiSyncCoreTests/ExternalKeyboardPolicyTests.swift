import XCTest
@testable import LumiSyncCore

final class ExternalKeyboardPolicyTests: XCTestCase {
    func testExternalInputActivatesAndBuiltInInputClears() {
        let device = KeyboardDeviceID(transport: "Bluetooth", vendorID: 1, productID: 2, locationID: nil)
        var policy = ExternalKeyboardPolicy(excludedDevices: [])
        policy.recordInput(.external(device), seconds: 0)
        XCTAssertTrue(policy.isExternalKeyboardActive)
        policy.recordInput(.builtIn, seconds: 5)
        XCTAssertFalse(policy.isExternalKeyboardActive)
    }

    func testExcludedExternalDeviceDoesNotActivate() {
        let device = KeyboardDeviceID(transport: "USB", vendorID: 3, productID: 4, locationID: 5)
        var policy = ExternalKeyboardPolicy(excludedDevices: [device])
        policy.recordInput(.external(device), seconds: 0)
        XCTAssertFalse(policy.isExternalKeyboardActive)
    }

    func testFifteenMinuteFallbackClearsExternalActivity() {
        let device = KeyboardDeviceID(transport: "USB", vendorID: 3, productID: 4, locationID: 5)
        var policy = ExternalKeyboardPolicy(excludedDevices: [])
        policy.recordInput(.external(device), seconds: 0)
        policy.tick(seconds: 899)
        XCTAssertTrue(policy.isExternalKeyboardActive)
        policy.tick(seconds: 900)
        XCTAssertFalse(policy.isExternalKeyboardActive)
    }
}
