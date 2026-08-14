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

    func testRetireWaitsForLeaseAcquiredBeforeContextMethod() {
        let registry = KeyboardInputNativeCallbackRegistry.shared
        let context = makeContext()
        let token = registry.register(context)
        let tokenBits = UInt(bitPattern: token)
        let acquired = DispatchSemaphore(value: 0)
        let resume = DispatchSemaphore(value: 0)
        let retired = DispatchSemaphore(value: 0)

        DispatchQueue.global().async {
            let rawToken = UnsafeMutableRawPointer(bitPattern: tokenBits)
            guard let lease = registry.acquire(rawToken, afterIncrement: {
                acquired.signal()
                resume.wait()
            }) else {
                return
            }
            lease.context.recordActivity(origin: .builtIn, nowNanoseconds: 1)
            lease.release()
        }
        XCTAssertEqual(acquired.wait(timeout: .now() + 1), .success)

        DispatchQueue.global().async {
            if let rawToken = UnsafeMutableRawPointer(bitPattern: tokenBits) {
                registry.retire(rawToken)
            }
            retired.signal()
        }
        XCTAssertEqual(retired.wait(timeout: .now() + 0.05), .timedOut)
        resume.signal()
        XCTAssertEqual(retired.wait(timeout: .now() + 1), .success)
        XCTAssertNil(registry.acquire(UnsafeMutableRawPointer(bitPattern: tokenBits)))
    }

    func testRetireCannotPassAcquisitionWhileRegistryLockIsHeld() {
        let registry = KeyboardInputNativeCallbackRegistry.shared
        let token = registry.register(makeContext())
        let tokenBits = UInt(bitPattern: token)
        let locked = DispatchSemaphore(value: 0)
        let resume = DispatchSemaphore(value: 0)
        let retired = DispatchSemaphore(value: 0)
        DispatchQueue.global().async {
            let lease = registry.acquire(
                UnsafeMutableRawPointer(bitPattern: tokenBits),
                whileLocked: {
                    locked.signal()
                    resume.wait()
                }
            )
            lease?.release()
        }
        XCTAssertEqual(locked.wait(timeout: .now() + 1), .success)
        DispatchQueue.global().async {
            if let rawToken = UnsafeMutableRawPointer(bitPattern: tokenBits) {
                registry.retire(rawToken)
            }
            retired.signal()
        }
        XCTAssertEqual(retired.wait(timeout: .now()), .timedOut)
        resume.signal()
        XCTAssertEqual(retired.wait(timeout: .now() + 1), .success)
    }

    func testConcurrentLeaseReleaseOnlyDecrementsInFlightOnce() {
        let registry = KeyboardInputNativeCallbackRegistry.shared
        let token = registry.register(makeContext())
        let tokenBits = UInt(bitPattern: token)
        let releaseBarrier = LeaseReleaseBarrier(participantCount: 2)
        guard let lease = registry.acquire(token, beforeReleaseStateCheck: {
            releaseBarrier.arriveAndWait()
        }) else {
            XCTFail("Expected registered token to acquire a lease")
            return
        }
        let releaseGroup = DispatchGroup()

        for _ in 0..<2 {
            releaseGroup.enter()
            DispatchQueue.global().async {
                lease.release()
                releaseGroup.leave()
            }
        }
        XCTAssertTrue(releaseBarrier.waitUntilAllArrived(timeout: 1))
        releaseBarrier.resume()
        XCTAssertEqual(releaseGroup.wait(timeout: .now() + 1), .success)

        let retired = DispatchSemaphore(value: 0)
        DispatchQueue.global().async {
            if let rawToken = UnsafeMutableRawPointer(bitPattern: tokenBits) {
                registry.retire(rawToken)
            }
            retired.signal()
        }
        XCTAssertEqual(retired.wait(timeout: .now() + 1), .success)
        XCTAssertNil(registry.acquire(UnsafeMutableRawPointer(bitPattern: tokenBits)))
    }

    func testTrampolineOperationHoldsLeaseUntilOperationReturns() {
        let registry = KeyboardInputNativeCallbackRegistry.shared
        let token = registry.register(makeContext())
        let tokenBits = UInt(bitPattern: token)
        let operationStarted = DispatchSemaphore(value: 0)
        let resumeOperation = DispatchSemaphore(value: 0)
        let operationFinished = DispatchSemaphore(value: 0)
        let retireWaiting = DispatchSemaphore(value: 0)
        let retired = DispatchSemaphore(value: 0)

        DispatchQueue.global().async {
            let rawToken = UnsafeMutableRawPointer(bitPattern: tokenBits)
            XCTAssertTrue(KeyboardInputNativeCallbackTrampoline.withContext(token: rawToken) { _ in
                operationStarted.signal()
                resumeOperation.wait()
            })
            operationFinished.signal()
        }
        XCTAssertEqual(operationStarted.wait(timeout: .now() + 1), .success)

        DispatchQueue.global().async {
            if let rawToken = UnsafeMutableRawPointer(bitPattern: tokenBits) {
                registry.retire(rawToken, beforeWait: {
                    retireWaiting.signal()
                })
            }
            retired.signal()
        }
        XCTAssertEqual(retireWaiting.wait(timeout: .now() + 1), .success)
        XCTAssertEqual(retired.wait(timeout: .now()), .timedOut)
        resumeOperation.signal()
        XCTAssertEqual(operationFinished.wait(timeout: .now() + 1), .success)
        XCTAssertEqual(retired.wait(timeout: .now() + 1), .success)
        let retiredToken = UnsafeMutableRawPointer(bitPattern: tokenBits)
        XCTAssertFalse(KeyboardInputNativeCallbackTrampoline.withContext(token: retiredToken) { _ in
            XCTFail("Retired token must not reach callback context")
        })
    }

    func testRetiredRawTokenRejectsLateTrampolineAcquisition() {
        let registry = KeyboardInputNativeCallbackRegistry.shared
        let token = registry.register(makeContext())

        registry.retire(token)

        XCTAssertFalse(KeyboardInputNativeCallbackTrampoline.withContext(token: token) { _ in
            XCTFail("Retired token must not reach callback context")
        })
    }

    private func makeContext() -> KeyboardInputNativeCallbackContext {
        KeyboardInputNativeCallbackContext(
            permissionStatus: { .granted },
            monotonicNanoseconds: { 1 },
            handler: { _ in },
            runtimeEventHandler: { _ in }
        )
    }
}

private final class LeaseReleaseBarrier: @unchecked Sendable {
    private let condition = NSCondition()
    private let participantCount: Int
    private var arrived = 0
    private var isResumed = false

    init(participantCount: Int) {
        self.participantCount = participantCount
    }

    func arriveAndWait() {
        condition.lock()
        arrived += 1
        condition.broadcast()
        while !isResumed {
            condition.wait()
        }
        condition.unlock()
    }

    func waitUntilAllArrived(timeout: TimeInterval) -> Bool {
        let deadline = Date(timeIntervalSinceNow: timeout)
        condition.lock()
        defer { condition.unlock() }
        while arrived < participantCount {
            guard condition.wait(until: deadline) else { return false }
        }
        return true
    }

    func resume() {
        condition.lock()
        isResumed = true
        condition.broadcast()
        condition.unlock()
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
