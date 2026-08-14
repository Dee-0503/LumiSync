import ApplicationServices
import IOKit.hid
import LumiSyncCore
import XCTest
@testable import LumiSyncAppSupport

@MainActor
final class SystemKeyboardInputMonitorLifecycleTests: XCTestCase {
    func testOpenFailureUnregistersUnschedulesAndClosesBeforeReleasingContext() {
        let native = RecordingSystemKeyboardInputNativeAPI(openResult: kIOReturnError)
        let monitor = SystemKeyboardInputMonitor(nativeAPI: native.api)

        XCTAssertThrowsError(try monitor.start(handler: { _ in }, runtimeEventHandler: { _ in })) { error in
            XCTAssertEqual(error as? KeyboardInputMonitoringError, .hidManagerUnavailable)
        }

        XCTAssertEqual(native.operations, [
            .createManager,
            .scheduleManager,
            .openManager,
            .unregisterCallbacks,
            .unscheduleManager,
            .closeManager
        ])
        XCTAssertEqual(native.eventTapCreateCount, 0)
    }

    func testStopAndDeinitTearDownNativeCallbacksOnce() {
        let native = RecordingSystemKeyboardInputNativeAPI()
        var monitor: SystemKeyboardInputMonitor? = SystemKeyboardInputMonitor(nativeAPI: native.api)
        XCTAssertThrowsError(try monitor?.start(handler: { _ in }, runtimeEventHandler: { _ in })) { error in
            XCTAssertEqual(error as? KeyboardInputMonitoringError, .eventTapUnavailable)
        }

        monitor?.stop()
        monitor = nil

        XCTAssertEqual(native.operations.suffix(3), [
            .unregisterCallbacks,
            .unscheduleManager,
            .closeManager
        ])
        XCTAssertEqual(native.operations.filter { $0 == .unregisterCallbacks }.count, 1)
        XCTAssertEqual(native.operations.filter { $0 == .closeManager }.count, 1)
    }

    func testLateNativeCallbackAfterDeactivateIsIgnored() async {
        var deliveredOrigins: [KeyboardInputOrigin] = []
        let context = KeyboardInputNativeCallbackContext(
            permissionStatus: { .granted },
            monotonicNanoseconds: { 1 },
            handler: { deliveredOrigins.append($0) },
            runtimeEventHandler: { _ in }
        )

        context.deactivate()
        context.recordActivity(origin: .builtIn, nowNanoseconds: 1)
        context.receiveTapEvent(.keyDown)
        await Task.yield()

        XCTAssertTrue(deliveredOrigins.isEmpty)
    }

    func testStopRestartRejectsPriorContextGeneration() async {
        var deliveredOrigins: [KeyboardInputOrigin] = []
        let priorContext = KeyboardInputNativeCallbackContext(
            permissionStatus: { .granted },
            monotonicNanoseconds: { 1 },
            handler: { deliveredOrigins.append($0) },
            runtimeEventHandler: { _ in }
        )
        priorContext.recordActivity(origin: .builtIn, nowNanoseconds: 1)
        priorContext.receiveTapEvent(.keyDown)
        priorContext.deactivate()

        let currentContext = KeyboardInputNativeCallbackContext(
            permissionStatus: { .granted },
            monotonicNanoseconds: { 2 },
            handler: { deliveredOrigins.append($0) },
            runtimeEventHandler: { _ in }
        )
        currentContext.recordActivity(origin: .builtIn, nowNanoseconds: 2)
        currentContext.receiveTapEvent(.keyDown)
        await Task.yield()

        XCTAssertEqual(deliveredOrigins, [.builtIn])
    }
}

private final class RecordingSystemKeyboardInputNativeAPI: @unchecked Sendable {
    enum Operation: Equatable {
        case createManager
        case scheduleManager
        case openManager
        case unregisterCallbacks
        case unscheduleManager
        case closeManager
        case createEventTap
    }

    private let openResult: IOReturn
    private(set) var operations: [Operation] = []

    init(openResult: IOReturn = kIOReturnSuccess) {
        self.openResult = openResult
    }

    var eventTapCreateCount: Int {
        operations.filter { $0 == .createEventTap }.count
    }

    var api: SystemKeyboardInputNativeAPI {
        SystemKeyboardInputNativeAPI(
            permissionStatus: { .granted },
            monotonicNanoseconds: { 0 },
            createHIDManager: { [self] in
                operations.append(.createManager)
                return IOHIDManagerCreate(kCFAllocatorDefault, IOOptionBits(kIOHIDOptionsTypeNone))
            },
            scheduleHIDManager: { [self] _ in
                operations.append(.scheduleManager)
            },
            openHIDManager: { [self] _ in
                operations.append(.openManager)
                return openResult
            },
            unregisterHIDCallbacks: { [self] _ in
                operations.append(.unregisterCallbacks)
            },
            unscheduleHIDManager: { [self] _ in
                operations.append(.unscheduleManager)
            },
            closeHIDManager: { [self] _ in
                operations.append(.closeManager)
            },
            createEventTap: { [self] _, _, _ in
                operations.append(.createEventTap)
                return nil
            }
        )
    }
}
