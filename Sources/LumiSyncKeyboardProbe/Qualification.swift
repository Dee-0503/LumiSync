public struct ObjectiveCSelectorSignature: Codable, Equatable, Sendable {
    public let name: String
    public let typeEncoding: String

    public init(name: String, typeEncoding: String) {
        self.name = name
        self.typeEncoding = typeEncoding
    }
}

public struct BacklightQualificationIdentity: Codable, Equatable, Sendable {
    public let modelIdentifier: String
    public let architecture: String
    public let macOSVersion: String
    public let macOSBuild: String
    public let frameworkPresent: Bool
    public let classPresent: Bool
    public let selectorSignatures: [ObjectiveCSelectorSignature]

    public init(
        modelIdentifier: String,
        architecture: String,
        macOSVersion: String,
        macOSBuild: String,
        frameworkPresent: Bool,
        classPresent: Bool,
        selectorSignatures: [ObjectiveCSelectorSignature]
    ) {
        self.modelIdentifier = modelIdentifier
        self.architecture = architecture
        self.macOSVersion = macOSVersion
        self.macOSBuild = macOSBuild
        self.frameworkPresent = frameworkPresent
        self.classPresent = classPresent
        self.selectorSignatures = selectorSignatures
    }
}

public enum BacklightQualificationState: Codable, Equatable, Sendable {
    case unqualified(reason: String)
    case qualified(BacklightQualificationIdentity)
}

public struct BacklightQualificationPolicy: Sendable {
    private static let requiredSelectorSignatures = [
        ObjectiveCSelectorSignature(name: "copyKeyboardBacklightIDs", typeEncoding: "@@:"),
        ObjectiveCSelectorSignature(name: "isKeyboardBuiltIn:", typeEncoding: "B@:Q"),
        ObjectiveCSelectorSignature(name: "brightnessForKeyboard:", typeEncoding: "f@:Q"),
        ObjectiveCSelectorSignature(name: "setBrightness:forKeyboard:", typeEncoding: "B@:fQ")
    ]

    public init() {}

    public func evaluate(
        saved: BacklightQualificationIdentity,
        current: BacklightQualificationIdentity
    ) -> BacklightQualificationState {
        guard isComplete(saved) else {
            return .unqualified(reason: "Saved CoreBrightness identity is incomplete.")
        }
        guard let invalidReason = invalidReason(for: current) else {
            guard saved == current else {
                return .unqualified(reason: "Current CoreBrightness identity does not exactly match the saved qualification.")
            }
            return .qualified(current)
        }
        return .unqualified(reason: invalidReason)
    }

    private func invalidReason(for identity: BacklightQualificationIdentity) -> String? {
        guard isComplete(identity) else {
            return "Current CoreBrightness selector set or ABI is unsupported."
        }
        return nil
    }

    private func isComplete(_ identity: BacklightQualificationIdentity) -> Bool {
        guard !identity.modelIdentifier.isEmpty,
              identity.architecture == "arm64",
              !identity.macOSVersion.isEmpty,
              !identity.macOSBuild.isEmpty,
              identity.frameworkPresent,
              identity.classPresent
        else {
            return false
        }
        return signaturesMatchRequired(identity.selectorSignatures)
    }

    private func signaturesMatchRequired(
        _ actual: [ObjectiveCSelectorSignature]
    ) -> Bool {
        guard actual.count == Self.requiredSelectorSignatures.count else {
            return false
        }
        return zip(actual, Self.requiredSelectorSignatures).allSatisfy { actual, required in
            actual.name == required.name
                && typeEncoding(actual.typeEncoding, matches: required.typeEncoding)
        }
    }

    private func typeEncoding(_ actual: String, matches required: String) -> Bool {
        if actual == required {
            return true
        }

        let actualBytes = Array(actual.utf8)
        let requiredBytes = Array(required.utf8)
        guard actualBytes.allSatisfy({ $0 < 0x80 }) else {
            return false
        }

        var actualIndex = 0
        for requiredToken in requiredBytes {
            guard actualIndex < actualBytes.count,
                  actualBytes[actualIndex] == requiredToken
            else {
                return false
            }
            actualIndex += 1

            let offsetStart = actualIndex
            while actualIndex < actualBytes.count,
                  isASCIIDigit(actualBytes[actualIndex]) {
                actualIndex += 1
            }
            guard actualIndex > offsetStart else {
                return false
            }
        }
        return actualIndex == actualBytes.count
    }

    private func isASCIIDigit(_ byte: UInt8) -> Bool {
        (0x30...0x39).contains(byte)
    }
}

public struct CoreBrightnessSignatureInspection: Equatable, Sendable {
    public let frameworkPresent: Bool
    public let classPresent: Bool
    public let selectorSignatures: [ObjectiveCSelectorSignature]

    public init(
        frameworkPresent: Bool,
        classPresent: Bool,
        selectorSignatures: [ObjectiveCSelectorSignature]
    ) {
        self.frameworkPresent = frameworkPresent
        self.classPresent = classPresent
        self.selectorSignatures = selectorSignatures
    }
}
