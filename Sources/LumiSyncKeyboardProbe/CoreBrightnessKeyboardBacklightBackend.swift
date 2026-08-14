import Foundation
import ObjectiveC.runtime

public enum CoreBrightnessBackendError: Error, CustomStringConvertible {
    case frameworkUnavailable(String)
    case classUnavailable(String)
    case selectorUnavailable(String)
    case clientInitializationFailed
    case malformedKeyboardIDs
    case writeRejected(keyboardID: UInt64, brightness: Float)

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
        }
    }
}

public final class CoreBrightnessKeyboardBacklightBackend: KeyboardBacklightBackend {
    private static let frameworkPath = "/System/Library/PrivateFrameworks/CoreBrightness.framework"
    private static let clientClassName = "KeyboardBrightnessClient"

    private let clientClass: AnyClass
    private let client: AnyObject

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

    public func setBrightness(_ brightness: Float, keyboardID: UInt64) throws {
        try writeBrightness(brightness, keyboardID: keyboardID)
    }

    public func restoreBrightness(_ brightness: Float, keyboardID: UInt64) throws {
        try writeBrightness(brightness, keyboardID: keyboardID)
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
        guard brightness.isFinite, (0.0...1.0).contains(brightness) else {
            throw CoreBrightnessBackendError.writeRejected(
                keyboardID: keyboardID,
                brightness: brightness
            )
        }

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
