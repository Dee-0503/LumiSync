import XCTest
@testable import LumiSyncCore

final class LumiSyncCoreTests: XCTestCase {
    func testCoreModuleExposesVersion() {
        XCTAssertEqual(LumiSyncCore.version, "0.1.0")
    }
}
