import XCTest
@testable import LumiSyncAppSupport

@MainActor
final class AppStateCoordinatorTests: XCTestCase {
    func testPausePersistsAndPreventsHardwareWrites() throws {
        let preferencesStore = InMemoryAppPreferencesStore()
        let keyboard = RecordingKeyboardBacklightController()
        let coordinator = AppStateCoordinator(
            preferencesStore: preferencesStore,
            displayBrightnessReader: StubDisplayBrightnessReader(result: .success(
                DisplayBrightnessReading(value: 0.2, sourceDescription: "Built-in display")
            )),
            keyboardBacklight: keyboard,
            inputMonitoring: StubInputMonitoringController(status: .granted)
        )

        coordinator.setPaused(true)
        coordinator.refresh()

        XCTAssertTrue(coordinator.snapshot.isPaused)
        XCTAssertTrue(try preferencesStore.load().isPaused)
        XCTAssertTrue(keyboard.values.isEmpty)
    }

    func testLanguageChangePublishesAndPersistsImmediately() throws {
        let preferencesStore = InMemoryAppPreferencesStore()
        let coordinator = AppStateCoordinator(
            preferencesStore: preferencesStore,
            displayBrightnessReader: StubDisplayBrightnessReader(result: .success(
                DisplayBrightnessReading(value: 0.2, sourceDescription: "Built-in display")
            )),
            keyboardBacklight: UnavailableKeyboardBacklightController(),
            inputMonitoring: StubInputMonitoringController(status: .granted)
        )
        var observedLanguage: AppLanguage?
        coordinator.onSnapshotChange = { snapshot in
            observedLanguage = snapshot.language
        }

        coordinator.setLanguage(.simplifiedChinese)

        XCTAssertEqual(coordinator.snapshot.language, .simplifiedChinese)
        XCTAssertEqual(observedLanguage, .simplifiedChinese)
        XCTAssertEqual(try preferencesStore.load().language, .simplifiedChinese)
    }

    func testUnavailableKeyboardCapabilityIsReportedWithoutClaimingSuccess() {
        let coordinator = AppStateCoordinator(
            preferencesStore: InMemoryAppPreferencesStore(),
            displayBrightnessReader: StubDisplayBrightnessReader(result: .success(
                DisplayBrightnessReading(value: 0.2, sourceDescription: "Built-in display")
            )),
            keyboardBacklight: UnavailableKeyboardBacklightController(),
            inputMonitoring: StubInputMonitoringController(status: .granted)
        )

        coordinator.refresh()

        XCTAssertEqual(coordinator.snapshot.keyboardBacklightStatus, .unavailable)
        XCTAssertEqual(coordinator.snapshot.status, .stopped(.keyboardBacklightUnavailable))
    }

    func testSessionLockForcesImmediateZeroWhenKeyboardCapabilityIsAvailable() {
        let keyboard = RecordingKeyboardBacklightController()
        let coordinator = AppStateCoordinator(
            preferencesStore: InMemoryAppPreferencesStore(),
            displayBrightnessReader: StubDisplayBrightnessReader(result: .success(
                DisplayBrightnessReading(value: 0.2, sourceDescription: "Built-in display")
            )),
            keyboardBacklight: keyboard,
            inputMonitoring: StubInputMonitoringController(status: .granted)
        )

        coordinator.handleWorkspaceEvent(.sessionLocked)

        XCTAssertEqual(keyboard.values.last, 0.0)
        XCTAssertEqual(coordinator.snapshot.status, .active)
    }

    func testWakeAndUnlockRefreshesDisplayAndResumesCoordination() {
        let display = MutableDisplayBrightnessReader(
            reading: DisplayBrightnessReading(value: 0.4, sourceDescription: "Built-in display")
        )
        let keyboard = RecordingKeyboardBacklightController()
        let coordinator = AppStateCoordinator(
            preferencesStore: InMemoryAppPreferencesStore(),
            displayBrightnessReader: display,
            keyboardBacklight: keyboard,
            inputMonitoring: StubInputMonitoringController(status: .granted)
        )

        coordinator.handleWorkspaceEvent(.systemWillSleep)
        display.reading = DisplayBrightnessReading(value: 0.6, sourceDescription: "Built-in display")
        coordinator.handleWorkspaceEvent(.systemDidWake)

        XCTAssertFalse(coordinator.snapshot.systemAsleep)
        XCTAssertEqual(coordinator.snapshot.displayBrightness, 0.6)
        XCTAssertEqual(keyboard.values.last, 0.0)
    }

    func testMissingInputMonitoringStopsBeforeKeyboardWrite() {
        let keyboard = RecordingKeyboardBacklightController()
        let coordinator = AppStateCoordinator(
            preferencesStore: InMemoryAppPreferencesStore(),
            displayBrightnessReader: StubDisplayBrightnessReader(result: .success(
                DisplayBrightnessReading(value: 0.2, sourceDescription: "Built-in display")
            )),
            keyboardBacklight: keyboard,
            inputMonitoring: StubInputMonitoringController(status: .denied)
        )

        coordinator.refresh()

        XCTAssertEqual(coordinator.snapshot.status, .stopped(.missingInputMonitoring))
        XCTAssertTrue(keyboard.values.isEmpty)
    }
}

private final class InMemoryAppPreferencesStore: AppPreferencesStoring {
    private var value = AppPreferences.defaults

    func load() throws -> AppPreferences { value }
    func save(_ preferences: AppPreferences) throws { value = preferences }
}

private struct StubDisplayBrightnessReader: DisplayBrightnessReadingService {
    let result: Result<DisplayBrightnessReading, DisplayBrightnessError>

    func read() throws -> DisplayBrightnessReading {
        try result.get()
    }
}

private final class MutableDisplayBrightnessReader: DisplayBrightnessReadingService {
    var reading: DisplayBrightnessReading

    init(reading: DisplayBrightnessReading) {
        self.reading = reading
    }

    func read() throws -> DisplayBrightnessReading { reading }
}

private final class RecordingKeyboardBacklightController: KeyboardBacklightControlling {
    var availability: KeyboardBacklightAvailability { .available }
    private(set) var values: [Double] = []

    func setBrightness(_ value: Double) throws {
        values.append(value)
    }
}

private struct StubInputMonitoringController: InputMonitoringControlling {
    let status: InputMonitoringStatus

    func requestAccess() -> Bool { status == .granted }
    func openSystemSettings() {}
}
