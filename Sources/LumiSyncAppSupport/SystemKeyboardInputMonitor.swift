import ApplicationServices
import Foundation
import IOKit.hid
import LumiSyncCore

/// A privacy-minimized keyboard source monitor.
///
/// A physical keyboard press is staged from IOHIDManager using only its Boolean pressed
/// state and device identity. It is reported only after the listen-only CGEventTap confirms
/// a corresponding keyDown. The key usage, keycode, character, and input sequence are never
/// stored or forwarded; ambiguous or unmatched activity is dropped fail-closed.
@MainActor
public final class SystemKeyboardInputMonitor: KeyboardInputMonitoring {
    private let nativeAPI: SystemKeyboardInputNativeAPI
    private var eventTap: CFMachPort?
    private var eventTapSource: CFRunLoopSource?
    private var hidManager: IOHIDManager?
    private var callbackContext: KeyboardInputNativeCallbackContext?
    private var callbackToken: UnsafeMutableRawPointer?

    public convenience init() {
        self.init(nativeAPI: .live)
    }

    init(nativeAPI: SystemKeyboardInputNativeAPI) {
        self.nativeAPI = nativeAPI
    }

    public func start(
        handler: @escaping @MainActor @Sendable (KeyboardInputOrigin) -> Void,
        runtimeEventHandler: @escaping @MainActor @Sendable (KeyboardInputMonitorRuntimeEvent) -> Void
    ) throws {
        guard nativeAPI.permissionStatus() == .granted else {
            throw KeyboardInputMonitoringError.inputMonitoringNotAuthorized
        }
        guard callbackContext == nil else { return }

        let context = KeyboardInputNativeCallbackContext(
            permissionStatus: nativeAPI.permissionStatus,
            monotonicNanoseconds: nativeAPI.monotonicNanoseconds,
            handler: handler,
            runtimeEventHandler: runtimeEventHandler
        )
        let callbackToken = KeyboardInputNativeCallbackRegistry.shared.register(context)
        callbackContext = context
        self.callbackToken = callbackToken

        do {
            try configureHIDManager(context: callbackToken)
            try configureEventTap(context: callbackToken)
        } catch {
            teardownNativeResources()
            throw error
        }
    }

    public func stop() {
        teardownNativeResources()
    }

    deinit {
        MainActor.assumeIsolated {
            teardownNativeResources()
        }
    }

    private func configureHIDManager(context: UnsafeMutableRawPointer) throws {
        let manager = nativeAPI.createHIDManager()
        let keyboardMatching: [String: Any] = [
            kIOHIDDeviceUsagePageKey as String: kHIDPage_GenericDesktop,
            kIOHIDDeviceUsageKey as String: kHIDUsage_GD_Keyboard
        ]
        IOHIDManagerSetDeviceMatching(manager, keyboardMatching as CFDictionary)
        IOHIDManagerRegisterDeviceMatchingCallback(
            manager,
            Self.deviceMatchedCallback,
            context
        )
        IOHIDManagerRegisterDeviceRemovalCallback(
            manager,
            Self.deviceRemovedCallback,
            context
        )
        IOHIDManagerRegisterInputValueCallback(
            manager,
            Self.inputValueCallback,
            context
        )
        nativeAPI.scheduleHIDManager(manager)
        hidManager = manager

        guard nativeAPI.openHIDManager(manager) == kIOReturnSuccess else {
            throw KeyboardInputMonitoringError.hidManagerUnavailable
        }
    }

    private func configureEventTap(context: UnsafeMutableRawPointer) throws {
        let mask = CGEventMask(1) << CGEventType.keyDown.rawValue
        guard let eventTap = nativeAPI.createEventTap(mask, Self.eventTapCallback, context) else {
            throw KeyboardInputMonitoringError.eventTapUnavailable
        }

        let source = CFMachPortCreateRunLoopSource(kCFAllocatorDefault, eventTap, 0)
        self.eventTap = eventTap
        eventTapSource = source
        CFRunLoopAddSource(CFRunLoopGetMain(), source, .commonModes)
        CGEvent.tapEnable(tap: eventTap, enable: true)
    }

    private func teardownNativeResources() {
        guard callbackContext != nil
                || callbackToken != nil
                || hidManager != nil
                || eventTap != nil else {
            return
        }

        callbackContext?.deactivate()

        if let hidManager {
            nativeAPI.unregisterHIDCallbacks(hidManager)
        }
        if let eventTap {
            CGEvent.tapEnable(tap: eventTap, enable: false)
            CFMachPortInvalidate(eventTap)
        }
        if let eventTapSource {
            CFRunLoopRemoveSource(CFRunLoopGetMain(), eventTapSource, .commonModes)
        }
        eventTapSource = nil
        eventTap = nil

        if let hidManager {
            nativeAPI.unscheduleHIDManager(hidManager)
            nativeAPI.closeHIDManager(hidManager)
        }
        hidManager = nil

        if let callbackToken {
            KeyboardInputNativeCallbackRegistry.shared.retire(callbackToken)
        }
        self.callbackToken = nil
        callbackContext = nil
    }

    private static let eventTapCallback: CGEventTapCallBack = { _, type, event, token in
        KeyboardInputNativeCallbackTrampoline.withContext(token: token) { context in
            context.receiveTapEvent(type)
        }
        return Unmanaged.passUnretained(event)
    }

    private static let deviceMatchedCallback: IOHIDDeviceCallback = { token, _, _, device in
        KeyboardInputNativeCallbackTrampoline.withContext(token: token) { context in
            context.deviceMatched(device)
        }
    }

    private static let deviceRemovedCallback: IOHIDDeviceCallback = { token, _, _, device in
        KeyboardInputNativeCallbackTrampoline.withContext(token: token) { context in
            context.deviceRemoved(device)
        }
    }

    private static let inputValueCallback: IOHIDValueCallback = { token, _, _, value in
        KeyboardInputNativeCallbackTrampoline.withContext(token: token) { context in
            context.receiveActivity(from: value)
        }
    }
}

struct SystemKeyboardInputNativeAPI: Sendable {
    let permissionStatus: @Sendable () -> InputMonitoringStatus
    let monotonicNanoseconds: @Sendable () -> UInt64
    let createHIDManager: @Sendable () -> IOHIDManager
    let scheduleHIDManager: @Sendable (IOHIDManager) -> Void
    let openHIDManager: @Sendable (IOHIDManager) -> IOReturn
    let unregisterHIDCallbacks: @Sendable (IOHIDManager) -> Void
    let unscheduleHIDManager: @Sendable (IOHIDManager) -> Void
    let closeHIDManager: @Sendable (IOHIDManager) -> Void
    let createEventTap: @Sendable (
        CGEventMask,
        @escaping CGEventTapCallBack,
        UnsafeMutableRawPointer
    ) -> CFMachPort?

    static let live = SystemKeyboardInputNativeAPI(
        permissionStatus: {
            IOHIDCheckAccess(kIOHIDRequestTypeListenEvent) == kIOHIDAccessTypeGranted
                ? .granted
                : .denied
        },
        monotonicNanoseconds: {
            DispatchTime.now().uptimeNanoseconds
        },
        createHIDManager: {
            IOHIDManagerCreate(kCFAllocatorDefault, IOOptionBits(kIOHIDOptionsTypeNone))
        },
        scheduleHIDManager: { manager in
            IOHIDManagerScheduleWithRunLoop(
                manager,
                CFRunLoopGetMain(),
                CFRunLoopMode.commonModes.rawValue
            )
        },
        openHIDManager: { manager in
            IOHIDManagerOpen(manager, IOOptionBits(kIOHIDOptionsTypeNone))
        },
        unregisterHIDCallbacks: { manager in
            IOHIDManagerRegisterDeviceMatchingCallback(manager, nil, nil)
            IOHIDManagerRegisterDeviceRemovalCallback(manager, nil, nil)
            IOHIDManagerRegisterInputValueCallback(manager, nil, nil)
        },
        unscheduleHIDManager: { manager in
            IOHIDManagerUnscheduleFromRunLoop(
                manager,
                CFRunLoopGetMain(),
                CFRunLoopMode.commonModes.rawValue
            )
        },
        closeHIDManager: { manager in
            IOHIDManagerClose(manager, IOOptionBits(kIOHIDOptionsTypeNone))
        },
        createEventTap: { mask, callback, context in
            CGEvent.tapCreate(
                tap: .cgSessionEventTap,
                place: .tailAppendEventTap,
                options: .listenOnly,
                eventsOfInterest: mask,
                callback: callback,
                userInfo: context
            )
        }
    )
}

final class KeyboardInputNativeCallbackContext: @unchecked Sendable {
    private let lock = NSLock()
    private let permissionStatus: @Sendable () -> InputMonitoringStatus
    private let monotonicNanoseconds: @Sendable () -> UInt64
    private var handler: (@MainActor @Sendable (KeyboardInputOrigin) -> Void)?
    private var runtimeEventHandler: (@MainActor @Sendable (KeyboardInputMonitorRuntimeEvent) -> Void)?
    private var recordsByDevice: [IOHIDDevice: KeyboardDeviceRecord] = [:]
    private var inputGate = KeyboardInputEventGate()
    private var deliveryGate = KeyboardInputDeliveryGate()

    init(
        permissionStatus: @escaping @Sendable () -> InputMonitoringStatus,
        monotonicNanoseconds: @escaping @Sendable () -> UInt64,
        handler: @escaping @MainActor @Sendable (KeyboardInputOrigin) -> Void,
        runtimeEventHandler: @escaping @MainActor @Sendable (KeyboardInputMonitorRuntimeEvent) -> Void
    ) {
        self.permissionStatus = permissionStatus
        self.monotonicNanoseconds = monotonicNanoseconds
        self.handler = handler
        self.runtimeEventHandler = runtimeEventHandler
        _ = deliveryGate.start()
    }

    func deactivate() {
        lock.withLock {
            deliveryGate.stop()
            recordsByDevice.removeAll()
            inputGate.invalidatePendingInput()
            handler = nil
            runtimeEventHandler = nil
        }
    }

    func deviceMatched(_ device: IOHIDDevice) {
        lock.withLock {
            guard deliveryGate.isRunning,
                  let record = KeyboardDeviceRecord(device: device) else {
                return
            }
            recordsByDevice[device] = record
        }
    }

    func deviceRemoved(_ device: IOHIDDevice) {
        lock.withLock {
            guard deliveryGate.isRunning else { return }
            recordsByDevice.removeValue(forKey: device)
        }
    }

    func receiveActivity(from value: IOHIDValue) {
        let element = IOHIDValueGetElement(value)
        guard KeyboardHIDElementFilter.isOrdinaryKeyPress(
            usagePage: IOHIDElementGetUsagePage(element),
            usage: IOHIDElementGetUsage(element),
            integerValue: IOHIDValueGetIntegerValue(value)
        ) else {
            return
        }
        let device = IOHIDElementGetDevice(element)
        let record: KeyboardDeviceRecord? = lock.withLock {
            guard deliveryGate.isRunning else { return nil }
            return recordsByDevice[device] ?? KeyboardDeviceRecord(device: device)
        }
        guard let record else {
            return
        }
        recordActivity(
            origin: record.isBuiltIn ? .builtIn : .external(record.deviceID),
            nowNanoseconds: monotonicNanoseconds()
        )
    }

    func recordActivity(origin: KeyboardInputOrigin, nowNanoseconds: UInt64) {
        lock.withLock {
            guard deliveryGate.isRunning else { return }
            inputGate.recordDeviceTransition(
                origin: origin,
                isPressed: true,
                nowNanoseconds: nowNanoseconds
            )
        }
    }

    func receiveTapEvent(_ type: CGEventType) {
        switch type {
        case .keyDown:
            guard permissionStatus() == .granted else {
                lock.withLock {
                    inputGate.invalidatePendingInput()
                }
                notifyRuntimeEvent(.permissionRevoked)
                return
            }
            let origin: KeyboardInputOrigin? = lock.withLock {
                guard deliveryGate.isRunning else { return nil }
                return inputGate.consumeKeyDown(
                    nowNanoseconds: monotonicNanoseconds()
                )
            }
            if let origin {
                deliverOrigin(origin)
            }
        case .tapDisabledByTimeout:
            lock.withLock {
                inputGate.invalidatePendingInput()
            }
            notifyRuntimeEvent(.tapDisabledByTimeout)
        case .tapDisabledByUserInput:
            lock.withLock {
                inputGate.invalidatePendingInput()
            }
            notifyRuntimeEvent(
                permissionStatus() == .granted
                    ? .tapDisabledByUserInput
                    : .permissionRevoked
            )
        default:
            break
        }
    }

    private func deliverOrigin(_ origin: KeyboardInputOrigin) {
        let delivery = lock.withLock {
            (deliveryGate.generation, handler)
        }
        guard let handler = delivery.1 else { return }
        Task { @MainActor [weak self] in
            guard let self,
                  self.accepts(delivery.0) else {
                return
            }
            handler(origin)
        }
    }

    private func notifyRuntimeEvent(_ event: KeyboardInputMonitorRuntimeEvent) {
        let delivery = lock.withLock {
            (deliveryGate.generation, runtimeEventHandler)
        }
        guard let runtimeEventHandler = delivery.1 else { return }
        Task { @MainActor [weak self] in
            guard let self,
                  self.accepts(delivery.0) else {
                return
            }
            runtimeEventHandler(event)
        }
    }

    private func accepts(_ generation: UInt64) -> Bool {
        lock.withLock {
            deliveryGate.accepts(generation)
        }
    }
}

private struct KeyboardDeviceRecord: Sendable {
    let deviceID: KeyboardDeviceID
    let isBuiltIn: Bool

    init?(device: IOHIDDevice) {
        guard let vendorID = device.integerProperty(kIOHIDVendorIDKey),
              let productID = device.integerProperty(kIOHIDProductIDKey) else {
            return nil
        }
        let transport = device.stringProperty(kIOHIDTransportKey) ?? "Unknown"
        let locationID = device.integerProperty(kIOHIDLocationIDKey)
        deviceID = KeyboardDeviceID(
            transport: transport,
            vendorID: vendorID,
            productID: productID,
            locationID: locationID
        )
        isBuiltIn = device.boolProperty(kIOHIDBuiltInKey) ?? (transport == "SPI")
    }
}

private extension IOHIDDevice {
    func integerProperty(_ key: String) -> Int? {
        guard let value = IOHIDDeviceGetProperty(self, key as CFString) else { return nil }
        return (value as? NSNumber)?.intValue
    }

    func stringProperty(_ key: String) -> String? {
        IOHIDDeviceGetProperty(self, key as CFString) as? String
    }

    func boolProperty(_ key: String) -> Bool? {
        (IOHIDDeviceGetProperty(self, key as CFString) as? NSNumber)?.boolValue
    }
}
