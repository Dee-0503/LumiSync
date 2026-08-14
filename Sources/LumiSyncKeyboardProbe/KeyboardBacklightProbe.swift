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
    public let originalBrightness: Float
    public let verifiedLevels: [Float]

    public init(originalBrightness: Float, verifiedLevels: [Float]) {
        self.originalBrightness = originalBrightness
        self.verifiedLevels = verifiedLevels
    }
}

public protocol KeyboardBacklightBackend: AnyObject {
    func keyboardIDs() throws -> [UInt64]
    func isBuiltIn(keyboardID: UInt64) throws -> Bool
    func brightness(keyboardID: UInt64) throws -> Float
    func installRecovery(keyboardID: UInt64, originalBrightness: Float) throws
    func setBrightness(_ brightness: Float, keyboardID: UInt64) throws
    func restoreBrightness(_ brightness: Float, keyboardID: UInt64) throws
    func disarmRecovery()
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

public struct KeyboardBacklightWriteTest {
    private static let requiredLevels: [Float] = [0.0, 0.5, 1.0]
    private static let readbackTolerance: Float = 0.01

    private let backend: KeyboardBacklightBackend

    public init(backend: KeyboardBacklightBackend) {
        self.backend = backend
    }

    public func run(keyboardID: UInt64) throws -> KeyboardBacklightWriteTestResult {
        let originalBrightness = try backend.brightness(keyboardID: keyboardID)
        guard originalBrightness.isFinite, (0.0...1.0).contains(originalBrightness) else {
            throw KeyboardBacklightProbeError.invalidBrightness(originalBrightness)
        }
        try backend.installRecovery(
            keyboardID: keyboardID,
            originalBrightness: originalBrightness
        )

        var primaryError: Error?
        var verifiedLevels: [Float] = []

        do {
            for level in Self.requiredLevels {
                try backend.setBrightness(level, keyboardID: keyboardID)
                let actual = try backend.brightness(keyboardID: keyboardID)
                guard abs(actual - level) <= Self.readbackTolerance else {
                    throw KeyboardBacklightProbeError.readbackMismatch(
                        expected: level,
                        actual: actual
                    )
                }
                verifiedLevels.append(level)
            }
        } catch {
            primaryError = error
        }

        do {
            try backend.restoreBrightness(originalBrightness, keyboardID: keyboardID)
        } catch {
            throw error
        }
        backend.disarmRecovery()

        if let primaryError {
            throw primaryError
        }

        return KeyboardBacklightWriteTestResult(
            originalBrightness: originalBrightness,
            verifiedLevels: verifiedLevels
        )
    }
}
