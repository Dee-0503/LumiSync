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

public protocol ObjectiveCMetadataProviding: AnyObject {
    func loadFramework(at path: String) -> Bool
    func classIsPresent(named name: String) -> Bool
    func typeEncoding(classNamed name: String, selectorNamed selectorName: String) -> String?
}

private final class RuntimeObjectiveCMetadataProvider: ObjectiveCMetadataProviding {
    func loadFramework(at path: String) -> Bool {
        guard let bundle = Bundle(path: path) else { return false }
        return bundle.isLoaded || bundle.load()
    }

    func classIsPresent(named name: String) -> Bool {
        NSClassFromString(name) != nil
    }

    func typeEncoding(classNamed name: String, selectorNamed selectorName: String) -> String? {
        guard let clientClass = NSClassFromString(name),
              let method = class_getInstanceMethod(
                  clientClass,
                  NSSelectorFromString(selectorName)
              ),
              let encoding = method_getTypeEncoding(method)
        else {
            return nil
        }
        return String(cString: encoding)
    }
}

protocol CoreBrightnessRuntimeProviding: AnyObject {
    func keyboardIDs() throws -> [UInt64]
    func isBuiltIn(keyboardID: UInt64) throws -> Bool
    func brightness(keyboardID: UInt64) throws -> Float
    func setBrightness(_ brightness: Float, keyboardID: UInt64) throws -> Bool
}

public final class CoreBrightnessKeyboardBacklightBackend: KeyboardBacklightBackend {
    fileprivate static let frameworkPath = "/System/Library/PrivateFrameworks/CoreBrightness.framework"
    fileprivate static let clientClassName = "KeyboardBrightnessClient"
    private static let inspectedSelectorNames = [
        "copyKeyboardBacklightIDs",
        "isKeyboardBuiltIn:",
        "brightnessForKeyboard:",
        "setBrightness:forKeyboard:"
    ]

    private let runtimeProvider: CoreBrightnessRuntimeProviding

    public init() throws {
        runtimeProvider = try RuntimeCoreBrightnessProvider()
    }

    init(runtimeProvider: CoreBrightnessRuntimeProviding) throws {
        self.runtimeProvider = runtimeProvider
    }

    public static func inspectSignatures() throws -> CoreBrightnessSignatureInspection {
        try inspectSignatures(metadataProvider: RuntimeObjectiveCMetadataProvider())
    }

    public static func inspectSignatures(
        metadataProvider: ObjectiveCMetadataProviding
    ) throws -> CoreBrightnessSignatureInspection {
        let frameworkPresent = metadataProvider.loadFramework(at: frameworkPath)
        let classPresent = frameworkPresent
            && metadataProvider.classIsPresent(named: clientClassName)
        let signatures = classPresent ? inspectedSelectorNames.compactMap { selectorName in
            metadataProvider.typeEncoding(
                classNamed: clientClassName,
                selectorNamed: selectorName
            ).map {
                ObjectiveCSelectorSignature(name: selectorName, typeEncoding: $0)
            }
        } : []
        return CoreBrightnessSignatureInspection(
            frameworkPresent: frameworkPresent,
            classPresent: classPresent,
            selectorSignatures: signatures
        )
    }

    public func keyboardIDs() throws -> [UInt64] {
        try runtimeProvider.keyboardIDs()
    }

    public func isBuiltIn(keyboardID: UInt64) throws -> Bool {
        try runtimeProvider.isBuiltIn(keyboardID: keyboardID)
    }

    public func brightness(keyboardID: UInt64) throws -> Float {
        try runtimeProvider.brightness(keyboardID: keyboardID)
    }

    public func setBrightness(_ brightness: Float, keyboardID: UInt64) throws {
        throw CoreBrightnessBackendError.writeRejected(
            keyboardID: keyboardID,
            brightness: brightness
        )
    }

    public func restoreBrightness(_ brightness: Float, keyboardID: UInt64) throws {
        throw CoreBrightnessBackendError.writeRejected(
            keyboardID: keyboardID,
            brightness: brightness
        )
    }
}

private final class RuntimeCoreBrightnessProvider: CoreBrightnessRuntimeProviding {
    private let clientClass: AnyClass
    private let client: AnyObject

    init() throws {
        guard let bundle = Bundle(path: CoreBrightnessKeyboardBacklightBackend.frameworkPath),
              bundle.load()
        else {
            throw CoreBrightnessBackendError.frameworkUnavailable(
                CoreBrightnessKeyboardBacklightBackend.frameworkPath
            )
        }
        guard let clientClass = NSClassFromString(
            CoreBrightnessKeyboardBacklightBackend.clientClassName
        ) else {
            throw CoreBrightnessBackendError.classUnavailable(
                CoreBrightnessKeyboardBacklightBackend.clientClassName
            )
        }

        self.clientClass = clientClass
        client = try Self.makeClient(clientClass: clientClass)
        try requireSelector("copyKeyboardBacklightIDs")
        try requireSelector("isKeyboardBuiltIn:")
        try requireSelector("brightnessForKeyboard:")
        try requireSelector("setBrightness:forKeyboard:")
    }

    func keyboardIDs() throws -> [UInt64] {
        let value = try invokeObject(selectorName: "copyKeyboardBacklightIDs")
        guard let ids = value as? [NSNumber] else {
            throw CoreBrightnessBackendError.malformedKeyboardIDs
        }
        return ids.map(\.uint64Value)
    }

    func isBuiltIn(keyboardID: UInt64) throws -> Bool {
        try invokeBool(selectorName: "isKeyboardBuiltIn:", keyboardID: keyboardID)
    }

    func brightness(keyboardID: UInt64) throws -> Float {
        try invokeFloat(selectorName: "brightnessForKeyboard:", keyboardID: keyboardID)
    }

    func setBrightness(_ brightness: Float, keyboardID: UInt64) throws -> Bool {
        guard brightness.isFinite, (0.0...1.0).contains(brightness) else {
            throw CoreBrightnessBackendError.writeRejected(
                keyboardID: keyboardID,
                brightness: brightness
            )
        }

        let selectorName = "setBrightness:forKeyboard:"
        let (selector, implementation) = try implementation(selectorName: selectorName)
        typealias Function = @convention(c) (AnyObject, Selector, Float, UInt64) -> Bool
        return unsafeBitCast(implementation, to: Function.self)(
            client,
            selector,
            brightness,
            keyboardID
        )
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
}
