import XCTest
@testable import LumiSyncCore

final class DisplaySourceSelectorTests: XCTestCase {
    func testReadableMainExternalWins() {
        let result = DisplaySourceSelector().select(from: [
            .init(id: 1, kind: .builtIn, adapter: .builtIn, readableBrightness: 0.4, isMain: false),
            .init(id: 9, kind: .external, adapter: .ddc, readableBrightness: 0.7, isMain: true)
        ])
        XCTAssertEqual(result?.brightness, 0.7)
    }

    func testFallsBackToBuiltInWhenExternalUnreadable() {
        let result = DisplaySourceSelector().select(from: [
            .init(id: 1, kind: .builtIn, adapter: .builtIn, readableBrightness: 0.4, isMain: false),
            .init(id: 9, kind: .external, adapter: .ddc, readableBrightness: nil, isMain: true)
        ])
        XCTAssertEqual(result?.brightness, 0.4)
        XCTAssertNotNil(result?.fallbackReason)
    }

    func testAppleAdapterPreferredForSameDisplay() {
        let result = DisplaySourceSelector().select(from: [
            .init(id: 10, kind: .external, adapter: .ddc, readableBrightness: 0.5, isMain: true),
            .init(id: 10, kind: .external, adapter: .apple, readableBrightness: 0.6, isMain: true)
        ])
        XCTAssertEqual(result?.brightness, 0.6)
    }
}
