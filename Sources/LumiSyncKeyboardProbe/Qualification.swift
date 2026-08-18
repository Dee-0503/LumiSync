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
        return identity.selectorSignatures == Self.requiredSelectorSignatures
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
