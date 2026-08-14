import XCTest
@testable import LumiSyncAppSupport

final class PublicDisplayBrightnessReaderTests: XCTestCase {
    func testReadsMainDisplayBrightnessFromPublicDisplayServicesAPI() throws {
        let api = StubDisplayServicesAPI(
            mainDisplayID: 42,
            activeDisplayIDs: [42],
            builtInDisplayIDs: [42],
            brightnessByDisplayID: [42: 0.35]
        )

        let reading = try PublicDisplayBrightnessReader(api: api).read()

        XCTAssertEqual(reading.value, 0.35)
        XCTAssertEqual(reading.sourceDescription, "Built-in display")
    }

    func testFallsBackToReadableBuiltInDisplayWhenMainDisplayCannotBeRead() throws {
        let api = StubDisplayServicesAPI(
            mainDisplayID: 7,
            activeDisplayIDs: [7, 42],
            builtInDisplayIDs: [42],
            brightnessByDisplayID: [42: 0.7]
        )

        let reading = try PublicDisplayBrightnessReader(api: api).read()

        XCTAssertEqual(reading.value, 0.7)
        XCTAssertEqual(reading.sourceDescription, "Built-in display")
        XCTAssertNotNil(reading.fallbackReason)
    }

    func testThrowsUnavailableWhenNoPublicReadableDisplayExists() {
        let api = StubDisplayServicesAPI(
            mainDisplayID: 7,
            activeDisplayIDs: [7],
            builtInDisplayIDs: [],
            brightnessByDisplayID: [:]
        )

        XCTAssertThrowsError(try PublicDisplayBrightnessReader(api: api).read()) { error in
            XCTAssertEqual(error as? DisplayBrightnessError, .unavailable)
        }
    }
}

private struct StubDisplayServicesAPI: DisplayServicesAPI {
    let mainDisplayID: UInt32
    let activeDisplayIDs: [UInt32]
    let builtInDisplayIDs: Set<UInt32>
    let brightnessByDisplayID: [UInt32: Double]

    func activeDisplays() -> [UInt32] { activeDisplayIDs }
    func isBuiltIn(_ displayID: UInt32) -> Bool { builtInDisplayIDs.contains(displayID) }
    func readBrightness(displayID: UInt32) -> Double? { brightnessByDisplayID[displayID] }
}
