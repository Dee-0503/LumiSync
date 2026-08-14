import XCTest
@testable import LumiSyncAppSupport

final class KeyboardInputDeliveryGateTests: XCTestCase {
    func testStopInvalidatesQueuedDeliveryGeneration() {
        var gate = KeyboardInputDeliveryGate()
        let generation = gate.start()

        gate.stop()

        XCTAssertFalse(gate.accepts(generation))
    }

    func testRestartRejectsPriorGenerationAndAcceptsCurrentGeneration() {
        var gate = KeyboardInputDeliveryGate()
        let priorGeneration = gate.start()
        gate.stop()
        let currentGeneration = gate.start()

        XCTAssertFalse(gate.accepts(priorGeneration))
        XCTAssertTrue(gate.accepts(currentGeneration))
    }
}
