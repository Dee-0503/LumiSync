import Foundation
import ObjectiveC.runtime

public enum CoreBrightnessBackendError: Error, CustomStringConvertible {
    case frameworkUnavailable(String)
    case classUnavailable(String)
    case selectorUnavailable(String)
    case clientInitializationFailed
    case malformedKeyboardIDs
    case writeRejected(keyboardID: UInt64, brightness: Float)
    case recoveryAlreadyInstalled
    case recoveryNotInstalled
    case signalHandlerInstallationFailed(Int32)

    public var description: String {
        switch self {
        case let .frameworkUnavailable(path):
            return "CoreBrightness private framework could not be loaded at \(path)."
        case let .classUnavailable(name):
            return "Private Objective-C class \(name) is unavailable."
        case let .selectorUnavailable(name):
            return "Private Objective-C selector \(name) is unavailable."
        case .clientInitializationFailed:
            return "KeyboardBrightnessClient initialization failed."
        case .malformedKeyboardIDs:
            return "KeyboardBrightnessClient returned malformed keyboard IDs."
        case let .writeRejected(keyboardID, brightness):
            return "CoreBrightness rejected brightness \(brightness) for keyboard \(keyboardID)."
        case .recoveryAlreadyInstalled:
            return "A keyboard-backlight recovery handler is already installed."
        case .recoveryNotInstalled:
            return "No recovery handler is installed; refusing to write."
        case let .signalHandlerInstallationFailed(signal):
            return "Could not install recovery handler for signal \(signal)."
        }
    }
}

public final class CoreBrightnessKeyboardBacklightBackend: KeyboardBacklightBackend {
    private static let frameworkPath = "/System/Library/PrivateFrameworks/CoreBrightness.framework"
    private static let clientClassName = "KeyboardBrightnessClient"

    private let clientClass: AnyClass
    private let client: AnyObject
    private var recovery: RecoveryGuard?

    public init() throws {
        guard let bundle = Bundle(path: Self.frameworkPath), bundle.load() else {
            throw CoreBrightnessBackendError.frameworkUnavailable(Self.frameworkPath)
        }
        guard let clientClass = NSClassFromString(Self.clientClassName) else {
            throw CoreBrightnessBackendError.classUnavailable(Self.clientClassName)
        }

        self.clientClass = clientClass
        client = try Self.makeClient(clientClass: clientClass)
        try requireSelector("copyKeyboardBacklightIDs")
        try requireSelector("isKeyboardBuiltIn:")
        try requireSelector("brightnessForKeyboard:")
        try requireSelector("setBrightness:forKeyboard:")
    }

    public func keyboardIDs() throws -> [UInt64] {
        let value = try invokeObject(selectorName: "copyKeyboardBacklightIDs")
        guard let ids = value as? [NSNumber] else {
            throw CoreBrightnessBackendError.malformedKeyboardIDs
        }
        return ids.map(\.uint64Value)
    }

    public func isBuiltIn(keyboardID: UInt64) throws -> Bool {
        try invokeBool(selectorName: "isKeyboardBuiltIn:", keyboardID: keyboardID)
    }

    public func brightness(keyboardID: UInt64) throws -> Float {
        try invokeFloat(selectorName: "brightnessForKeyboard:", keyboardID: keyboardID)
    }

    public func installRecovery(keyboardID: UInt64, originalBrightness: Float) throws {
        guard originalBrightness.isFinite, (0.0...1.0).contains(originalBrightness) else {
            throw CoreBrightnessBackendError.writeRejected(
                keyboardID: keyboardID,
                brightness: originalBrightness
            )
        }
        guard recovery == nil else {
            throw CoreBrightnessBackendError.recoveryAlreadyInstalled
        }
        recovery = try RecoveryGuard(
            backend: self,
            keyboardID: keyboardID,
            originalBrightness: originalBrightness
        )
    }

    public func setBrightness(_ brightness: Float, keyboardID: UInt64) throws {
        guard brightness.isFinite, (0.0...1.0).contains(brightness) else {
            throw CoreBrightnessBackendError.writeRejected(
                keyboardID: keyboardID,
                brightness: brightness
            )
        }
        guard recovery != nil else {
            throw CoreBrightnessBackendError.recoveryNotInstalled
        }
        try writeBrightness(brightness, keyboardID: keyboardID)
    }

    public func restoreBrightness(_ brightness: Float, keyboardID: UInt64) throws {
        try writeBrightness(brightness, keyboardID: keyboardID)
    }

    public func disarmRecovery() {
        recovery?.disarm()
        recovery = nil
    }

    fileprivate func emergencyRestore(_ brightness: Float, keyboardID: UInt64) {
        try? writeBrightness(brightness, keyboardID: keyboardID)
    }

    private static func makeClient(clientClass: AnyClass) throws -> AnyObject {
        let allocate = NSSelectorFromString("alloc")
        let initialize = NSSelectorFromString("init")
        guard
            let metaClass = object_getClass(clientClass),
            let allocateImplementation = class_getMethodImplementation(metaClass, allocate),
            let initializeImplementation = class_getMethodImplementation(clientClass, initialize)
        else {
            throw CoreBrightnessBackendError.clientInitializationFailed
        }

        typealias ObjectFunction = @convention(c) (AnyObject, Selector) -> AnyObject?
        let allocateFunction = unsafeBitCast(allocateImplementation, to: ObjectFunction.self)
        guard let allocated = allocateFunction(clientClass, allocate) else {
            throw CoreBrightnessBackendError.clientInitializationFailed
        }
        let initializeFunction = unsafeBitCast(initializeImplementation, to: ObjectFunction.self)
        guard let initialized = initializeFunction(allocated, initialize) else {
            throw CoreBrightnessBackendError.clientInitializationFailed
        }
        return initialized
    }

    private func requireSelector(_ name: String) throws {
        let selector = NSSelectorFromString(name)
        guard class_getInstanceMethod(clientClass, selector) != nil else {
            throw CoreBrightnessBackendError.selectorUnavailable(name)
        }
    }

    private func implementation(selectorName: String) throws -> (Selector, IMP) {
        let selector = NSSelectorFromString(selectorName)
        guard let implementation = class_getMethodImplementation(clientClass, selector) else {
            throw CoreBrightnessBackendError.selectorUnavailable(selectorName)
        }
        return (selector, implementation)
    }

    private func invokeObject(selectorName: String) throws -> AnyObject {
        let (selector, implementation) = try implementation(selectorName: selectorName)
        typealias Function = @convention(c) (AnyObject, Selector) -> AnyObject?
        let function = unsafeBitCast(implementation, to: Function.self)
        guard let result = function(client, selector) else {
            throw CoreBrightnessBackendError.malformedKeyboardIDs
        }
        return result
    }

    private func invokeBool(selectorName: String, keyboardID: UInt64) throws -> Bool {
        let (selector, implementation) = try implementation(selectorName: selectorName)
        typealias Function = @convention(c) (AnyObject, Selector, UInt64) -> Bool
        return unsafeBitCast(implementation, to: Function.self)(client, selector, keyboardID)
    }

    private func invokeFloat(selectorName: String, keyboardID: UInt64) throws -> Float {
        let (selector, implementation) = try implementation(selectorName: selectorName)
        typealias Function = @convention(c) (AnyObject, Selector, UInt64) -> Float
        return unsafeBitCast(implementation, to: Function.self)(client, selector, keyboardID)
    }

    private func writeBrightness(_ brightness: Float, keyboardID: UInt64) throws {
        let selectorName = "setBrightness:forKeyboard:"
        let (selector, implementation) = try implementation(selectorName: selectorName)
        typealias Function = @convention(c) (AnyObject, Selector, Float, UInt64) -> Bool
        let accepted = unsafeBitCast(implementation, to: Function.self)(
            client,
            selector,
            brightness,
            keyboardID
        )
        guard accepted else {
            throw CoreBrightnessBackendError.writeRejected(
                keyboardID: keyboardID,
                brightness: brightness
            )
        }
    }
}

private final class RecoveryGuard {
    private static let signals: [Int32] = [SIGINT, SIGTERM, SIGHUP]
    private nonisolated(unsafe) static var active: RecoveryGuard?
    private nonisolated(unsafe) static var didRegisterAtExit = false
    private static let lock = NSLock()

    private weak var backend: CoreBrightnessKeyboardBacklightBackend?
    private let keyboardID: UInt64
    private let originalBrightness: Float
    private var armed = true
    private var previousHandlers: [Int32: sig_t] = [:]

    init(
        backend: CoreBrightnessKeyboardBacklightBackend,
        keyboardID: UInt64,
        originalBrightness: Float
    ) throws {
        self.backend = backend
        self.keyboardID = keyboardID
        self.originalBrightness = originalBrightness

        Self.lock.lock()
        defer { Self.lock.unlock() }
        guard Self.active == nil else {
            throw CoreBrightnessBackendError.recoveryAlreadyInstalled
        }

        for signalNumber in Self.signals {
            guard let previous = signal(signalNumber, recoverySignalHandler) else {
                restorePreviousHandlers()
                throw CoreBrightnessBackendError.signalHandlerInstallationFailed(signalNumber)
            }
            previousHandlers[signalNumber] = previous
        }

        if !Self.didRegisterAtExit {
            atexit(recoveryAtExitHandler)
            Self.didRegisterAtExit = true
        }
        Self.active = self
    }

    func disarm() {
        Self.lock.lock()
        defer { Self.lock.unlock() }
        guard armed else { return }
        armed = false
        restorePreviousHandlers()
        if Self.active === self {
            Self.active = nil
        }
    }

    fileprivate static func restoreForTermination(signalNumber: Int32?) {
        lock.lock()
        let guardToRestore = active
        lock.unlock()
        guardToRestore?.restoreNow()

        if let signalNumber {
            signal(signalNumber, SIG_DFL)
            raise(signalNumber)
        }
    }

    private func restoreNow() {
        guard armed else { return }
        backend?.emergencyRestore(originalBrightness, keyboardID: keyboardID)
        disarm()
    }

    private func restorePreviousHandlers() {
        for (signalNumber, previous) in previousHandlers {
            signal(signalNumber, previous)
        }
        previousHandlers.removeAll()
    }
}

private func recoverySignalHandler(_ signalNumber: Int32) {
    RecoveryGuard.restoreForTermination(signalNumber: signalNumber)
}

private func recoveryAtExitHandler() {
    RecoveryGuard.restoreForTermination(signalNumber: nil)
}
