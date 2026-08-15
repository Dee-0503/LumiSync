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

    func testDefaultsFollowSystemLanguage() {
        XCTAssertEqual(AppPreferences.defaults.language, .system)
    }

    func testLegacySettingsWithoutLanguageDecodeAsSystem() throws {
        let legacyJSON = """
        {
          "core": {
            "version": 1,
            "curveSelection": { "preset": { "_0": "comfort" } },
            "intensity": 1,
            "loginLaunchEnabled": true,
            "excludedKeyboardDevices": []
          },
          "isPaused": false
        }
        """.data(using: .utf8)!

        let decoded = try JSONDecoder().decode(AppPreferences.self, from: legacyJSON)

        XCTAssertEqual(decoded.language, .system)
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
            isPaused: true,
            language: .simplifiedChinese
        )

        try store.save(settings)

        XCTAssertEqual(try store.load(), settings)
    }
}
