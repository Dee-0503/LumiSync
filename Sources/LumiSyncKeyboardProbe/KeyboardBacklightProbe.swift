import Foundation

public struct KeyboardBacklightSnapshot: Equatable, Sendable {
    public let id: UInt64
    public let isBuiltIn: Bool
    public let brightness: Float

    public init(id: UInt64, isBuiltIn: Bool, brightness: Float) {
        self.id = id
        self.isBuiltIn = isBuiltIn
        self.brightness = brightness
    }
}

public struct KeyboardBacklightInspection: Equatable, Sendable {
    public let keyboards: [KeyboardBacklightSnapshot]

    public init(keyboards: [KeyboardBacklightSnapshot]) {
        self.keyboards = keyboards
    }
}

public struct KeyboardBacklightWriteTestResult: Equatable, Sendable {
    public let verifiedLevels: [Float]

    public init(verifiedLevels: [Float]) {
        self.verifiedLevels = verifiedLevels
    }
}

public struct KeyboardBacklightWatchdogResult: Equatable, Sendable {
    public let originalBrightness: Float
    public let childTermination: KeyboardBacklightChildTermination

    public init(
        originalBrightness: Float,
        childTermination: KeyboardBacklightChildTermination
    ) {
        self.originalBrightness = originalBrightness
        self.childTermination = childTermination
    }
}

public protocol KeyboardBacklightBackend: AnyObject {
    func keyboardIDs() throws -> [UInt64]
    func isBuiltIn(keyboardID: UInt64) throws -> Bool
    func brightness(keyboardID: UInt64) throws -> Float
    func setBrightness(_ brightness: Float, keyboardID: UInt64) throws
    func restoreBrightness(_ brightness: Float, keyboardID: UInt64) throws
}

public enum KeyboardBacklightProbeError: Error, Equatable, CustomStringConvertible {
    case noBuiltInKeyboard
    case invalidBrightness(Float)
    case readbackMismatch(expected: Float, actual: Float)

    public var description: String {
        switch self {
        case .noBuiltInKeyboard:
            return "No built-in keyboard backlight was found."
        case let .invalidBrightness(value):
            return "Keyboard backlight returned invalid normalized brightness \(value)."
        case let .readbackMismatch(expected, actual):
            return "Keyboard backlight readback mismatch: expected \(expected), got \(actual)."
        }
    }
}

public struct KeyboardBacklightProbe {
    private let backend: KeyboardBacklightBackend

    public init(backend: KeyboardBacklightBackend) {
        self.backend = backend
    }

    public func inspect() throws -> KeyboardBacklightInspection {
        let snapshots = try backend.keyboardIDs().map { keyboardID in
            KeyboardBacklightSnapshot(
                id: keyboardID,
                isBuiltIn: try backend.isBuiltIn(keyboardID: keyboardID),
                brightness: try backend.brightness(keyboardID: keyboardID)
            )
        }
        return KeyboardBacklightInspection(keyboards: snapshots)
    }
}

public struct KeyboardBacklightWriter {
    private static let requiredLevels: [Float] = [0.0, 0.5, 1.0]
    private static let readbackTolerance: Float = 0.01

    private let backend: KeyboardBacklightBackend

    public init(backend: KeyboardBacklightBackend) {
        self.backend = backend
    }

    public func run(keyboardID: UInt64) throws -> KeyboardBacklightWriteTestResult {
        var verifiedLevels: [Float] = []
        for level in Self.requiredLevels {
            try backend.setBrightness(level, keyboardID: keyboardID)
            let actual = try backend.brightness(keyboardID: keyboardID)
            guard actual.isFinite, abs(actual - level) <= Self.readbackTolerance else {
                throw KeyboardBacklightProbeError.readbackMismatch(
                    expected: level,
                    actual: actual
                )
            }
            verifiedLevels.append(level)
        }
        return KeyboardBacklightWriteTestResult(verifiedLevels: verifiedLevels)
    }
}

public enum KeyboardBacklightChildTermination: Equatable, Sendable, CustomStringConvertible {
    case exited(Int32)
    case signaled(Int32)

    public var description: String {
        switch self {
        case let .exited(status):
            return "exit status \(status)"
        case let .signaled(signal):
            return "signal \(signal)"
        }
    }
}

public protocol KeyboardBacklightChildRunning {
    func runWriter(keyboardID: UInt64) throws -> KeyboardBacklightChildTermination
}

public enum KeyboardBacklightWatchdogError: Error, CustomStringConvertible {
    case childLaunchFailed(Error)
    case childFailed(KeyboardBacklightChildTermination)
    case restoreFailed(Error)
    case restoreVerificationFailed(expected: Float, actual: Float)

    public var description: String {
        switch self {
        case let .childLaunchFailed(error):
            return "Writer could not be launched: \(error)."
        case let .childFailed(termination):
            return "Writer ended with \(termination)."
        case let .restoreFailed(error):
            return "Watchdog could not restore the original brightness: \(error)."
        case let .restoreVerificationFailed(expected, actual):
            return "Watchdog restore verification failed: expected \(expected), got \(actual)."
        }
    }
}

public struct KeyboardBacklightRecoveryWatchdog {
    private static let readbackTolerance: Float = 0.01

    private let backend: KeyboardBacklightBackend
    private let childRunner: KeyboardBacklightChildRunning

    public init(
        backend: KeyboardBacklightBackend,
        childRunner: KeyboardBacklightChildRunning
    ) {
        self.backend = backend
        self.childRunner = childRunner
    }

    public func run(keyboardID: UInt64) throws -> KeyboardBacklightWatchdogResult {
        let originalBrightness = try backend.brightness(keyboardID: keyboardID)
        guard originalBrightness.isFinite, (0.0...1.0).contains(originalBrightness) else {
            throw KeyboardBacklightProbeError.invalidBrightness(originalBrightness)
        }

        let termination: KeyboardBacklightChildTermination
        let childError: Error?
        do {
            termination = try childRunner.runWriter(keyboardID: keyboardID)
            childError = nil
        } catch {
            termination = .exited(-1)
            childError = error
        }

        do {
            try backend.restoreBrightness(originalBrightness, keyboardID: keyboardID)
        } catch {
            throw KeyboardBacklightWatchdogError.restoreFailed(error)
        }

        let restored = try backend.brightness(keyboardID: keyboardID)
        guard restored.isFinite,
              abs(restored - originalBrightness) <= Self.readbackTolerance
        else {
            throw KeyboardBacklightWatchdogError.restoreVerificationFailed(
                expected: originalBrightness,
                actual: restored
            )
        }

        if let childError {
            throw KeyboardBacklightWatchdogError.childLaunchFailed(childError)
        }
        guard termination == .exited(0) else {
            throw KeyboardBacklightWatchdogError.childFailed(termination)
        }

        return KeyboardBacklightWatchdogResult(
            originalBrightness: originalBrightness,
            childTermination: termination
        )
    }
}
