import XCTest
@testable import LumiSyncCore

final class SyncEngineTests: XCTestCase {
    func testMissingCapabilityStopsWhenActive() {
        var snapshot = SyncSnapshot.normal(displayBrightness: 0.2)
        snapshot.inputMonitoringAuthorized = false
        XCTAssertEqual(SyncEngine().decide(snapshot), .stop(reason: .missingInputMonitoring))
    }

    func testPausedPreservesEvenWhenHelperMissing() {
        var snapshot = SyncSnapshot.normal(displayBrightness: 0.2)
        snapshot.paused = true
        snapshot.helperAvailable = false
        XCTAssertEqual(SyncEngine().decide(snapshot), .preserveCurrent)
    }

    func testDarkDisplayForcesZero() {
        let snapshot = SyncSnapshot.normal(displayBrightness: 0.0)
        XCTAssertEqual(SyncEngine().decide(snapshot), .setKeyboard(0.0))
    }

    func testExternalKeyboardActiveForcesZero() {
        var snapshot = SyncSnapshot.normal(displayBrightness: 0.2)
        snapshot.externalKeyboardActive = true
        XCTAssertEqual(SyncEngine().decide(snapshot), .setKeyboard(0.0))
    }
}
