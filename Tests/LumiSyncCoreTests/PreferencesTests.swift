import XCTest
@testable import LumiSyncCore

final class PreferencesTests: XCTestCase {
    func testDefaultPreferencesMatchProductSpec() {
        let prefs = LumiSyncPreferences.defaults
        XCTAssertEqual(prefs.curveSelection, .preset(.comfort))
        XCTAssertEqual(prefs.loginLaunchEnabled, true)
        XCTAssertEqual(prefs.intensity, 1.0)
    }

    func testPreferencesRoundTripWithoutSensitiveFields() throws {
        let data = try JSONEncoder().encode(LumiSyncPreferences.defaults)
        let json = String(data: data, encoding: .utf8)!
        XCTAssertFalse(json.contains("keyContents"))
        XCTAssertFalse(json.contains("inputSequence"))
        let decoded = try JSONDecoder().decode(LumiSyncPreferences.self, from: data)
        XCTAssertEqual(decoded, LumiSyncPreferences.defaults)
    }
}
