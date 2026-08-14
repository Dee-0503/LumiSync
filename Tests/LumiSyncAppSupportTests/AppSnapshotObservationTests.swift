import XCTest
import LumiSyncCore
@testable import LumiSyncAppSupport

@MainActor
final class AppSnapshotObservationTests: XCTestCase {
    func testKeyboardInputPublishesUpdatedSnapshotToObserver() {
        let monitor = SnapshotObservationKeyboardInputMonitor()
        let coordinator = AppStateCoordinator(
            preferencesStore: SnapshotObservationPreferencesStore(),
            displayBrightnessReader: SnapshotObservationDisplayReader(),
            keyboardBacklight: UnavailableKeyboardBacklightController(),
            inputMonitoring: SnapshotObservationInputMonitoring(),
            keyboardInputMonitor: monitor
        )
        var observedSnapshots: [AppSnapshot] = []
        coordinator.onSnapshotChange = { snapshot in
            observedSnapshots.append(snapshot)
        }
        coordinator.start()

        monitor.send(.external(KeyboardDeviceID(
            transport: "USB",
            vendorID: 1,
            productID: 2,
            locationID: 3
        )))

        XCTAssertEqual(observedSnapshots.last?.externalKeyboardActive, true)
        XCTAssertEqual(observedSnapshots.last?.keyboardInputMonitoringActive, true)
    }
}

private final class SnapshotObservationKeyboardInputMonitor: KeyboardInputMonitoring {
    private var handler: (@MainActor @Sendable (KeyboardInputOrigin) -> Void)?

    func start(
        handler: @escaping @MainActor @Sendable (KeyboardInputOrigin) -> Void,
        runtimeEventHandler: @escaping @MainActor @Sendable (KeyboardInputMonitorRuntimeEvent) -> Void
    ) throws {
        self.handler = handler
    }

    func stop() {
        handler = nil
    }

    @MainActor
    func send(_ origin: KeyboardInputOrigin) {
        handler?(origin)
    }
}

private final class SnapshotObservationPreferencesStore: AppPreferencesStoring {
    func load() throws -> AppPreferences { .defaults }
    func save(_ preferences: AppPreferences) throws {}
}

private struct SnapshotObservationDisplayReader: DisplayBrightnessReadingService {
    func read() throws -> DisplayBrightnessReading {
        DisplayBrightnessReading(value: 0.5, sourceDescription: "Built-in display")
    }
}

private struct SnapshotObservationInputMonitoring: InputMonitoringControlling {
    var status: InputMonitoringStatus { .granted }
    func requestAccess() -> Bool { true }
    func openSystemSettings() {}
}
