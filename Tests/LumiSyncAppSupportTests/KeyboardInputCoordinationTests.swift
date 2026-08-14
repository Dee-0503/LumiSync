import XCTest
import LumiSyncCore
@testable import LumiSyncAppSupport

@MainActor
final class KeyboardInputCoordinationTests: XCTestCase {
    func testDeniedPermissionDoesNotStartKeyboardInputMonitoring() {
        let inputMonitoring = MutableInputMonitoringController(status: .denied)
        let keyboardInputMonitor = FakeKeyboardInputMonitor()
        let coordinator = makeCoordinator(
            inputMonitoring: inputMonitoring,
            keyboardInputMonitor: keyboardInputMonitor
        )

        coordinator.start()

        XCTAssertEqual(keyboardInputMonitor.startCount, 0)
        XCTAssertFalse(coordinator.snapshot.keyboardInputMonitoringActive)
        XCTAssertEqual(coordinator.snapshot.status, .stopped(.missingInputMonitoring))
    }

    func testGrantedPermissionStartsKeyboardInputMonitoring() {
        let keyboardInputMonitor = FakeKeyboardInputMonitor()
        let coordinator = makeCoordinator(keyboardInputMonitor: keyboardInputMonitor)

        coordinator.start()

        XCTAssertEqual(keyboardInputMonitor.startCount, 1)
        XCTAssertTrue(coordinator.snapshot.keyboardInputMonitoringActive)
    }

    func testExternalInputTurnsOffBuiltInBacklightAndBuiltInInputRestoresIt() {
        let keyboard = RecordingKeyboardBacklightController()
        let keyboardInputMonitor = FakeKeyboardInputMonitor()
        let coordinator = makeCoordinator(
            keyboard: keyboard,
            keyboardInputMonitor: keyboardInputMonitor
        )
        coordinator.start()
        keyboard.values.removeAll()
        let external = KeyboardDeviceID(
            transport: "Bluetooth",
            vendorID: 1,
            productID: 2,
            locationID: nil
        )

        keyboardInputMonitor.send(.external(external))
        XCTAssertEqual(keyboard.values.last, 0)
        XCTAssertTrue(coordinator.snapshot.externalKeyboardActive)

        keyboardInputMonitor.send(.builtIn)
        XCTAssertGreaterThan(keyboard.values.last ?? 0, 0)
        XCTAssertFalse(coordinator.snapshot.externalKeyboardActive)
    }

    func testExcludedExternalInputDoesNotTurnOffBacklight() {
        let excluded = KeyboardDeviceID(
            transport: "USB",
            vendorID: 3,
            productID: 4,
            locationID: 5
        )
        let keyboard = RecordingKeyboardBacklightController()
        let keyboardInputMonitor = FakeKeyboardInputMonitor()
        let coordinator = makeCoordinator(
            keyboard: keyboard,
            keyboardInputMonitor: keyboardInputMonitor,
            excludedDevices: [excluded]
        )
        coordinator.start()
        keyboard.values.removeAll()

        keyboardInputMonitor.send(.external(excluded))

        XCTAssertTrue(keyboard.values.isEmpty)
        XCTAssertFalse(coordinator.snapshot.externalKeyboardActive)
    }

    func testFifteenMinuteReconciliationRestoresSynchronization() {
        let keyboard = RecordingKeyboardBacklightController()
        let keyboardInputMonitor = FakeKeyboardInputMonitor()
        let scheduler = FakeReconciliationScheduler()
        let clock = MutableClock(seconds: 100)
        let coordinator = makeCoordinator(
            keyboard: keyboard,
            keyboardInputMonitor: keyboardInputMonitor,
            scheduler: scheduler,
            clock: clock
        )
        coordinator.start()
        keyboard.values.removeAll()
        keyboardInputMonitor.send(.external(KeyboardDeviceID(
            transport: "USB",
            vendorID: 7,
            productID: 8,
            locationID: 9
        )))
        keyboard.values.removeAll()

        XCTAssertEqual(scheduler.scheduledDelay, 900)
        clock.seconds = 999
        scheduler.fire()
        XCTAssertTrue(coordinator.snapshot.externalKeyboardActive)
        XCTAssertTrue(keyboard.values.isEmpty)

        clock.seconds = 1_000
        scheduler.fire()
        XCTAssertFalse(coordinator.snapshot.externalKeyboardActive)
        XCTAssertGreaterThan(keyboard.values.last ?? 0, 0)
    }

    func testStopStopsListeningAndCancelsReconciliation() {
        let keyboardInputMonitor = FakeKeyboardInputMonitor()
        let scheduler = FakeReconciliationScheduler()
        let coordinator = makeCoordinator(
            keyboardInputMonitor: keyboardInputMonitor,
            scheduler: scheduler
        )
        coordinator.start()

        coordinator.stop()

        XCTAssertEqual(keyboardInputMonitor.stopCount, 1)
        XCTAssertEqual(scheduler.cancelCount, 1)
        XCTAssertFalse(coordinator.snapshot.keyboardInputMonitoringActive)
    }

    func testUnavailableBacklightTracksExternalStateWithoutClaimingWrite() {
        let keyboardInputMonitor = FakeKeyboardInputMonitor()
        let coordinator = makeCoordinator(
            keyboard: UnavailableKeyboardBacklightController(),
            keyboardInputMonitor: keyboardInputMonitor
        )
        coordinator.start()

        keyboardInputMonitor.send(.external(KeyboardDeviceID(
            transport: "Bluetooth",
            vendorID: 10,
            productID: 11,
            locationID: nil
        )))

        XCTAssertTrue(coordinator.snapshot.externalKeyboardActive)
        XCTAssertEqual(coordinator.snapshot.status, .stopped(.keyboardBacklightUnavailable))
    }

    private func makeCoordinator(
        keyboard: any KeyboardBacklightControlling = RecordingKeyboardBacklightController(),
        inputMonitoring: MutableInputMonitoringController = MutableInputMonitoringController(status: .granted),
        keyboardInputMonitor: FakeKeyboardInputMonitor,
        scheduler: FakeReconciliationScheduler = FakeReconciliationScheduler(),
        clock: MutableClock = MutableClock(seconds: 0),
        excludedDevices: Set<KeyboardDeviceID> = []
    ) -> AppStateCoordinator {
        let preferences = AppPreferences(
            core: LumiSyncPreferences(
                version: 1,
                curveSelection: .preset(.comfort),
                intensity: 1,
                loginLaunchEnabled: true,
                excludedKeyboardDevices: excludedDevices
            ),
            isPaused: false
        )
        return AppStateCoordinator(
            preferencesStore: InMemoryKeyboardPreferencesStore(value: preferences),
            displayBrightnessReader: FixedDisplayBrightnessReader(),
            keyboardBacklight: keyboard,
            inputMonitoring: inputMonitoring,
            keyboardInputMonitor: keyboardInputMonitor,
            reconciliationScheduler: scheduler,
            monotonicSeconds: { clock.seconds }
        )
    }
}

private final class FakeKeyboardInputMonitor: KeyboardInputMonitoring {
    private var handler: (@MainActor @Sendable (KeyboardInputOrigin) -> Void)?
    private(set) var startCount = 0
    private(set) var stopCount = 0

    func start(handler: @escaping @MainActor @Sendable (KeyboardInputOrigin) -> Void) throws {
        startCount += 1
        self.handler = handler
    }

    func stop() {
        stopCount += 1
        handler = nil
    }

    @MainActor
    func send(_ origin: KeyboardInputOrigin) {
        handler?(origin)
    }
}

private final class FakeReconciliationScheduler: ExternalKeyboardReconciliationScheduling {
    private var action: (@MainActor @Sendable () -> Void)?
    private(set) var scheduledDelay: TimeInterval?
    private(set) var cancelCount = 0

    func schedule(after delay: TimeInterval, action: @escaping @MainActor @Sendable () -> Void) {
        scheduledDelay = delay
        self.action = action
    }

    func cancel() {
        cancelCount += 1
        action = nil
    }

    @MainActor
    func fire() {
        action?()
    }
}

private final class MutableClock {
    var seconds: Int

    init(seconds: Int) {
        self.seconds = seconds
    }
}

private final class MutableInputMonitoringController: InputMonitoringControlling {
    var status: InputMonitoringStatus

    init(status: InputMonitoringStatus) {
        self.status = status
    }

    func requestAccess() -> Bool { status == .granted }
    func openSystemSettings() {}
}

private final class InMemoryKeyboardPreferencesStore: AppPreferencesStoring {
    private var value: AppPreferences

    init(value: AppPreferences) {
        self.value = value
    }

    func load() throws -> AppPreferences { value }
    func save(_ preferences: AppPreferences) throws { value = preferences }
}

private struct FixedDisplayBrightnessReader: DisplayBrightnessReadingService {
    func read() throws -> DisplayBrightnessReading {
        DisplayBrightnessReading(value: 0.5, sourceDescription: "Built-in display")
    }
}

private final class RecordingKeyboardBacklightController: KeyboardBacklightControlling {
    var availability: KeyboardBacklightAvailability { .available }
    var values: [Double] = []

    func setBrightness(_ value: Double) throws {
        values.append(value)
    }
}
