import Foundation
import XCTest
@testable import LumiSyncAppSupport
import LumiSyncCore

final class AppPreferencesStoreTests: XCTestCase {
    func testMissingStoredValueReturnsDefaults() throws {
        let defaults = try XCTUnwrap(UserDefaults(suiteName: #function))
        defaults.removePersistentDomain(forName: #function)
        let store = UserDefaultsAppPreferencesStore(defaults: defaults, key: "settings")

        XCTAssertEqual(try store.load(), .defaults)
    }

    func testSettingsRoundTripPersistsPauseAndCorePreferences() throws {
        let defaults = try XCTUnwrap(UserDefaults(suiteName: #function))
        defaults.removePersistentDomain(forName: #function)
        let store = UserDefaultsAppPreferencesStore(defaults: defaults, key: "settings")
        let settings = AppPreferences(
            core: LumiSyncPreferences(
                version: 1,
                curveSelection: .preset(.energySaver),
                intensity: 0.4,
                loginLaunchEnabled: false,
                excludedKeyboardDevices: []
            ),
            isPaused: true
        )

        try store.save(settings)

        XCTAssertEqual(try store.load(), settings)
    }
}
