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
public final class SystemKeyboardInputMonitor: KeyboardInputMonitoring, @unchecked Sendable {
    private let permissionStatus: @Sendable () -> InputMonitoringStatus
    private let monotonicNanoseconds: @Sendable () -> UInt64
    private var eventTap: CFMachPort?
    private var eventTapSource: CFRunLoopSource?
    private var hidManager: IOHIDManager?
    private var handler: (@MainActor @Sendable (KeyboardInputOrigin) -> Void)?
    private var runtimeEventHandler: (@MainActor @Sendable (KeyboardInputMonitorRuntimeEvent) -> Void)?
    private var recordsByDevice: [IOHIDDevice: KeyboardDeviceRecord] = [:]
    private var inputGate = KeyboardInputEventGate()
    private var deliveryGate = KeyboardInputDeliveryGate()

    public init(
        permissionStatus: @escaping @Sendable () -> InputMonitoringStatus = {
            IOHIDCheckAccess(kIOHIDRequestTypeListenEvent) == kIOHIDAccessTypeGranted
                ? .granted
                : .denied
        },
        monotonicNanoseconds: @escaping @Sendable () -> UInt64 = {
            DispatchTime.now().uptimeNanoseconds
        }
    ) {
        self.permissionStatus = permissionStatus
        self.monotonicNanoseconds = monotonicNanoseconds
    }

    public func start(
        handler: @escaping @MainActor @Sendable (KeyboardInputOrigin) -> Void,
        runtimeEventHandler: @escaping @MainActor @Sendable (KeyboardInputMonitorRuntimeEvent) -> Void
    ) throws {
        guard permissionStatus() == .granted else {
            throw KeyboardInputMonitoringError.inputMonitoringNotAuthorized
        }
        guard !deliveryGate.isRunning else { return }

        _ = deliveryGate.start()
        self.handler = handler
        self.runtimeEventHandler = runtimeEventHandler
        do {
            try configureHIDManager()
        } catch {
            stop()
            throw error
        }

        let mask = CGEventMask(1) << CGEventType.keyDown.rawValue
        guard let eventTap = CGEvent.tapCreate(
            tap: .cgSessionEventTap,
            place: .tailAppendEventTap,
            options: .listenOnly,
            eventsOfInterest: mask,
            callback: Self.eventTapCallback,
            userInfo: Unmanaged.passUnretained(self).toOpaque()
        ) else {
            stop()
            throw KeyboardInputMonitoringError.eventTapUnavailable
        }

        let source = CFMachPortCreateRunLoopSource(kCFAllocatorDefault, eventTap, 0)
        self.eventTap = eventTap
        eventTapSource = source
        CFRunLoopAddSource(CFRunLoopGetMain(), source, .commonModes)
        CGEvent.tapEnable(tap: eventTap, enable: true)
    }

    public func stop() {
        deliveryGate.stop()
        if let eventTap {
            CGEvent.tapEnable(tap: eventTap, enable: false)
        }
        if let eventTapSource {
            CFRunLoopRemoveSource(CFRunLoopGetMain(), eventTapSource, .commonModes)
        }
        eventTapSource = nil
        eventTap = nil

        if let hidManager {
            IOHIDManagerUnscheduleFromRunLoop(hidManager, CFRunLoopGetMain(), CFRunLoopMode.commonModes.rawValue)
            IOHIDManagerClose(hidManager, IOOptionBits(kIOHIDOptionsTypeNone))
        }
        hidManager = nil
        recordsByDevice.removeAll()
        inputGate.invalidatePendingInput()
        handler = nil
        runtimeEventHandler = nil
    }

    deinit {
        stop()
    }

    private func configureHIDManager() throws {
        let manager = IOHIDManagerCreate(kCFAllocatorDefault, IOOptionBits(kIOHIDOptionsTypeNone))
        let keyboardMatching: [String: Any] = [
            kIOHIDDeviceUsagePageKey as String: kHIDPage_GenericDesktop,
            kIOHIDDeviceUsageKey as String: kHIDUsage_GD_Keyboard
        ]
        IOHIDManagerSetDeviceMatching(manager, keyboardMatching as CFDictionary)
        IOHIDManagerRegisterDeviceMatchingCallback(
            manager,
            Self.deviceMatchedCallback,
            Unmanaged.passUnretained(self).toOpaque()
        )
        IOHIDManagerRegisterDeviceRemovalCallback(
            manager,
            Self.deviceRemovedCallback,
            Unmanaged.passUnretained(self).toOpaque()
        )
        IOHIDManagerRegisterInputValueCallback(
            manager,
            Self.inputValueCallback,
            Unmanaged.passUnretained(self).toOpaque()
        )
        IOHIDManagerScheduleWithRunLoop(manager, CFRunLoopGetMain(), CFRunLoopMode.commonModes.rawValue)
        let result = IOHIDManagerOpen(manager, IOOptionBits(kIOHIDOptionsTypeNone))
        guard result == kIOReturnSuccess else {
            IOHIDManagerUnscheduleFromRunLoop(manager, CFRunLoopGetMain(), CFRunLoopMode.commonModes.rawValue)
            throw KeyboardInputMonitoringError.hidManagerUnavailable
        }
        hidManager = manager
    }

    private func deviceMatched(_ device: IOHIDDevice) {
        guard let record = KeyboardDeviceRecord(device: device) else { return }
        recordsByDevice[device] = record
    }

    private func deviceRemoved(_ device: IOHIDDevice) {
        recordsByDevice.removeValue(forKey: device)
    }

    private func receiveActivity(from value: IOHIDValue) {
        let element = IOHIDValueGetElement(value)
        guard KeyboardHIDElementFilter.isOrdinaryKeyPress(
            usagePage: IOHIDElementGetUsagePage(element),
            usage: IOHIDElementGetUsage(element),
            integerValue: IOHIDValueGetIntegerValue(value)
        ) else {
            return
        }
        let device = IOHIDElementGetDevice(element)
        guard let record = recordsByDevice[device] ?? KeyboardDeviceRecord(device: device) else {
            return
        }
        let origin: KeyboardInputOrigin = record.isBuiltIn
            ? .builtIn
            : .external(record.deviceID)
        inputGate.recordDeviceTransition(
            origin: origin,
            isPressed: true,
            nowNanoseconds: monotonicNanoseconds()
        )
    }

    private func deliverOrigin(_ origin: KeyboardInputOrigin) {
        let deliveryGeneration = deliveryGate.generation
        Task { @MainActor [weak self] in
            guard let self,
                  self.deliveryGate.accepts(deliveryGeneration) else {
                return
            }
            self.handler?(origin)
        }
    }

    private func receiveTapEvent(_ type: CGEventType) {
        switch type {
        case .keyDown:
            guard permissionStatus() == .granted else {
                inputGate.invalidatePendingInput()
                notifyRuntimeEvent(.permissionRevoked)
                return
            }
            guard let origin = inputGate.consumeKeyDown(
                nowNanoseconds: monotonicNanoseconds()
            ) else { return }
            deliverOrigin(origin)
        case .tapDisabledByTimeout:
            inputGate.invalidatePendingInput()
            notifyRuntimeEvent(.tapDisabledByTimeout)
        case .tapDisabledByUserInput:
            inputGate.invalidatePendingInput()
            notifyRuntimeEvent(
                permissionStatus() == .granted
                    ? .tapDisabledByUserInput
                    : .permissionRevoked
            )
        default:
            break
        }
    }

    private func notifyRuntimeEvent(_ event: KeyboardInputMonitorRuntimeEvent) {
        let deliveryGeneration = deliveryGate.generation
        Task { @MainActor [weak self] in
            guard let self,
                  self.deliveryGate.accepts(deliveryGeneration) else {
                return
            }
            self.runtimeEventHandler?(event)
        }
    }

    private static let eventTapCallback: CGEventTapCallBack = { _, type, event, userInfo in
        guard let userInfo else { return Unmanaged.passUnretained(event) }
        Unmanaged<SystemKeyboardInputMonitor>
            .fromOpaque(userInfo)
            .takeUnretainedValue()
            .receiveTapEvent(type)
        return Unmanaged.passUnretained(event)
    }

    private static let deviceMatchedCallback: IOHIDDeviceCallback = { context, _, _, device in
        guard let context else { return }
        Unmanaged<SystemKeyboardInputMonitor>
            .fromOpaque(context)
            .takeUnretainedValue()
            .deviceMatched(device)
    }

    private static let deviceRemovedCallback: IOHIDDeviceCallback = { context, _, _, device in
        guard let context else { return }
        Unmanaged<SystemKeyboardInputMonitor>
            .fromOpaque(context)
            .takeUnretainedValue()
            .deviceRemoved(device)
    }

    private static let inputValueCallback: IOHIDValueCallback = { context, _, _, value in
        guard let context else { return }
        Unmanaged<SystemKeyboardInputMonitor>
            .fromOpaque(context)
            .takeUnretainedValue()
            .receiveActivity(from: value)
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
